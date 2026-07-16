<?php
// Harbor serialized-safe search/replace across a MySQL database.
// usage: php search-replace.php --host H --port P --user U --pass PW --db DB --rules FILE
// rules file: one rule per line, "FROM<TAB>TO"; FROM may start with "re:" for regex.

// rr() recurses into (nested) arrays and PHP-serialized strings, applying each
// rule; serialized values are unserialized -> replaced -> reserialized so string
// lengths are recomputed and stay valid. Rules are [from, to, isRegex].
function rr($data, $rules) {
    if (is_array($data)) {
        $out = [];
        foreach ($data as $k => $v) {
            $out[is_string($k) ? rr($k, $rules) : $k] = rr($v, $rules);
        }
        return $out;
    }
    if (is_string($data)) {
        $un = @unserialize($data);
        if ($un !== false || $data === 'b:0;') {
            return serialize(rr($un, $rules));   // reserialize -> lengths auto-correct
        }
        foreach ($rules as $r) {
            if ($r[2]) {
                // never let a failing regex null the value (preg_replace returns
                // null on error) — keep the original instead
                $new = preg_replace($r[0], $r[1], $data);
                if ($new !== null) $data = $new;
            } else {
                $data = str_replace($r[0], $r[1], $data);
            }
        }
        return $data;
    }
    return $data;
}

// Testability seam: when included as a library (HARBOR_SR_LIB_ONLY=1) stop here
// so rr() can be unit-tested without a DB. Real invocations leave it unset and
// run the full CLI below — behavior is unchanged.
if (getenv('HARBOR_SR_LIB_ONLY') === '1') { return; }

// --check: parse + validate the rules file and exit — no DB needed. Lets the
// import pipeline reject a bad rule BEFORE the backup/decompress/load work.
$o = getopt('', ['host:', 'port:', 'user:', 'pass:', 'db:', 'rules:', 'check']);
$required = isset($o['check']) ? ['rules'] : ['host','port','user','pass','db','rules'];
foreach ($required as $k) {
    if (!isset($o[$k])) { fwrite(STDERR, "missing --$k\n"); exit(2); }
}

$rules = []; $n = 0; $bad = 0;
foreach (file($o['rules'], FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $line) {
    $n++;
    $p = explode("\t", $line, 2);
    if (count($p) < 2) { fwrite(STDERR, "rule $n: no FROM/TO separator: $line\n"); $bad++; continue; }
    [$from, $to] = $p;
    $regex = false;
    if (strncmp($from, 're:', 3) === 0) {
        // documented format is a BARE pattern (re:UA-\d+-\d+) — wrap it in
        // delimiters here, escaping any literal delimiter char in the pattern
        $regex = true;
        $from = '~' . str_replace('~', '\~', substr($from, 3)) . '~';
        if (@preg_match($from, '') === false) {
            fwrite(STDERR, "rule $n: invalid regex '" . substr($p[0], 3) . "'\n");
            $bad++; continue;
        }
    }
    if ($from === '' || $from === '~~') { fwrite(STDERR, "rule $n: empty FROM\n"); $bad++; continue; }
    $rules[] = [$from, $to, $regex];
}
if ($bad) { fwrite(STDERR, "search-replace: $bad invalid rule(s)\n"); exit(2); }
if (isset($o['check'])) { fwrite(STDERR, 'rules ok: ' . count($rules) . " rule(s)\n"); exit(0); }
if (!$rules) { fwrite(STDERR, "no rules\n"); exit(0); }

// Two connections: $pdo streams table scans UNBUFFERED (a buffered SELECT *
// pulls the whole table into PHP memory — OOMs on any real Magento DB), while
// $wr runs the UPDATEs, which MySQL forbids on a connection with an open
// unbuffered result set.
$dsn = "mysql:host={$o['host']};port={$o['port']};dbname={$o['db']}";
$pdo = new PDO($dsn, $o['user'], $o['pass'],
    [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION, PDO::MYSQL_ATTR_USE_BUFFERED_QUERY => false]);
$wr = new PDO($dsn, $o['user'], $o['pass'],
    [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
// The import loads with FK checks off (out-of-order dumps); this pass runs on
// that same data and only rewrites text in place, so match the loader — an FK
// the dump never satisfied must not abort the replace halfway through.
$wr->exec('SET FOREIGN_KEY_CHECKS=0');

// Deliberately NO server-side LIKE pre-filter: measured on a real 670-table
// Magento DB, `col LIKE '%needle%'` per column×rule (240 collation-aware
// predicates/row) took 4m07s vs 1m37s for streaming every row into PHP's
// str_replace. The full scan into PHP IS the fast path.
$changed = 0; $skipped = 0;
foreach ($wr->query('SHOW TABLES')->fetchAll(PDO::FETCH_COLUMN) as $t) {
    $pk = []; $textcols = [];
    try {
        foreach ($wr->query("SHOW COLUMNS FROM `$t`")->fetchAll(PDO::FETCH_ASSOC) as $c) {
            if ($c['Key'] === 'PRI') $pk[] = $c['Field'];   // all columns of a (possibly composite) PK
            if (preg_match('/char|text|blob|json|enum/i', $c['Type'])) $textcols[] = $c['Field'];
        }
        if (!$textcols) continue;
        $rows = $pdo->query("SELECT * FROM `$t`");
    } catch (PDOException $e) {
        if (($e->errorInfo[0] ?? '') !== '42S02') throw $e;
        $skipped++;                                 // table vanished mid-scan (e.g.
        fwrite(STDERR, "skip `$t`: " . ($e->errorInfo[2] ?? 'gone') . "\n");  // a concurrent import)
        continue;
    }
    while ($row = $rows->fetch(PDO::FETCH_ASSOC)) {
        $set = []; $vals = [];
        foreach ($textcols as $col) {
            if ($row[$col] === null) continue;
            $new = rr($row[$col], $rules);
            if ($new !== $row[$col]) { $set[] = "`$col`=?"; $vals[] = $new; }
        }
        if (!$set) continue;
        if ($pk) {
            $w = [];
            foreach ($pk as $col) { $w[] = "`$col`=?"; $vals[] = $row[$col]; }
            $sql = "UPDATE `$t` SET " . implode(',', $set) . " WHERE " . implode(' AND ', $w);
        } else {
            $w = [];
            foreach ($row as $k => $v) {
                if ($v === null) { $w[] = "`$k` IS NULL"; }
                else { $w[] = "`$k`=?"; $vals[] = $v; }
            }
            $sql = "UPDATE `$t` SET " . implode(',', $set) . " WHERE " . implode(' AND ', $w) . " LIMIT 1";
        }
        // A rewrite can violate a unique key (two source values collapsing onto
        // one target — e.g. staging + prod emails both mapped to .test). Skip
        // that row and keep going: a fixup pass must not die mid-scan.
        try {
            $st = $wr->prepare($sql); $st->execute($vals); $changed += $st->rowCount();
        } catch (PDOException $e) {
            $state = $e->errorInfo[0] ?? '';
            $msg = $e->errorInfo[2] ?? 'error';
            if ($state === '23000') {           // unique-key collision: skip the row
                $skipped++;
                $id = $pk ? implode(',', array_map(fn($c) => $row[$c], $pk)) : '?';
                fwrite(STDERR, "skip `$t` row ($id): $msg\n");
            } elseif ($state === '42S02') {     // table vanished mid-scan (e.g. a
                $skipped++;                     // concurrent import reloading it)
                fwrite(STDERR, "skip rest of `$t`: $msg\n");
                break;
            } else {
                throw $e;
            }
        }
    }
    $rows->closeCursor();   // required after a break — the scan is unbuffered
}
fwrite(STDERR, "search-replace: {$changed} row(s) updated"
    . ($skipped ? ", {$skipped} skipped (see warnings above)" : '') . "\n");
