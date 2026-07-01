<?php
// Harbor serialized-safe search/replace across a MySQL database.
// usage: php search-replace.php --host H --port P --user U --pass PW --db DB --rules FILE
// rules file: one rule per line, "FROM<TAB>TO"; FROM may start with "re:" for regex.
$o = getopt('', ['host:', 'port:', 'user:', 'pass:', 'db:', 'rules:']);
foreach (['host','port','user','pass','db','rules'] as $k) {
    if (!isset($o[$k])) { fwrite(STDERR, "missing --$k\n"); exit(2); }
}

$rules = [];
foreach (file($o['rules'], FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $line) {
    $p = explode("\t", $line, 2);
    if (count($p) < 2) continue;
    [$from, $to] = $p;
    $regex = false;
    if (strncmp($from, 're:', 3) === 0) { $regex = true; $from = substr($from, 3); }
    $rules[] = [$from, $to, $regex];
}
if (!$rules) { fwrite(STDERR, "no rules\n"); exit(0); }

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
            $data = $r[2] ? preg_replace($r[0], $r[1], $data) : str_replace($r[0], $r[1], $data);
        }
        return $data;
    }
    return $data;
}

$pdo = new PDO(
    "mysql:host={$o['host']};port={$o['port']};dbname={$o['db']}",
    $o['user'], $o['pass'],
    [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION, PDO::MYSQL_ATTR_USE_BUFFERED_QUERY => true]
);

$changed = 0;
foreach ($pdo->query('SHOW TABLES')->fetchAll(PDO::FETCH_COLUMN) as $t) {
    $pk = []; $textcols = [];
    foreach ($pdo->query("SHOW COLUMNS FROM `$t`")->fetchAll(PDO::FETCH_ASSOC) as $c) {
        if ($c['Key'] === 'PRI') $pk[] = $c['Field'];   // all columns of a (possibly composite) PK
        if (preg_match('/char|text|blob|json|enum/i', $c['Type'])) $textcols[] = $c['Field'];
    }
    if (!$textcols) continue;
    $rows = $pdo->query("SELECT * FROM `$t`");
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
        $st = $pdo->prepare($sql); $st->execute($vals); $changed += $st->rowCount();
    }
}
fwrite(STDERR, "search-replace: {$changed} row(s) updated\n");
