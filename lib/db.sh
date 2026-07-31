#!/usr/bin/env bash
# db.sh — database lifecycle + hookable import pipeline (Phase 7).
# All SQL runs inside the project's MySQL container as root (no host mysql client).

# load DB_* / REDIS_* from the project's connection.env
_db_load() {
  local conn; conn="$(project_harbor_dir "$1")/connection.env"
  [ -f "$conn" ] || die "no connection info — run: harbor init $1"
  set -a; # shellcheck disable=SC1090
  . "$conn"; set +a
}

_db_mysql()    { local n="$1"; shift; project_compose "$n" exec -T -e MYSQL_PWD="$DB_ROOT_PASSWORD" mysql mysql -uroot "$@"; }
_db_mysqldump(){ local n="$1"; shift; project_compose "$n" exec -T -e MYSQL_PWD="$DB_ROOT_PASSWORD" mysql mysqldump -uroot "$@"; }

# A project with no mysql service isn't "not running" — it has no database at
# all. Say which, and how to get one. (Lifecycle commands no-op for a
# service-less project; a direct request for a missing thing refuses.)
_db_require() {
  local name="$1"
  if ! project_has_service "$name" mysql; then
    err "no database service for '$name'"
    services_fix_hint "$name" one
    exit 1
  fi
}

# _db_require must run before any DB_* variable is read — connection.env has no
# DB_* keys at all for a service-less project, so callers like cmd_mysql that
# read $DB_ROOT_PASSWORD after _db_load rely on _db_up_check (which calls
# _db_require first) having already exited. Keep this ordering if you touch it.
_db_up_check() {
  _db_require "$1"
  project_compose "$1" ps -q mysql 2>/dev/null | grep -q . || die "stack not running — run: harbor up $1"
}

# Shared SQL/dump helpers (used by db.sh + sandbox.sh). Identifier validation is
# db_ident (common.sh); these are the DB-domain emitters.

# Escape a password for a single-quoted SQL literal (\ then '), MySQL default mode.
sql_quote_pass() { local p="$1"; p="${p//\\/\\\\}"; printf '%s' "${p//\'/\'\'}"; }

# Emit a dump ($1) decompressed to stdout, by extension: .sql.gz/.gz, .zip, or
# plain cat — so callers can chain transforms in ONE pass over the bytes.
_db_stream() {
  case "$1" in
    *.sql.gz|*.gz) gunzip -c "$1" ;;
    *.zip)         unzip -p "$1" ;;
    *)             cat "$1" ;;
  esac
}

# Decompress a dump ($1) to a working file ($2).
_db_decompress() { _db_stream "$1" > "$2"; }

# A truncated dump (interrupted download/export) ends mid-statement and loads
# only the tables before the cut — silently, with --force. A complete dump's
# last non-empty line ends a statement (';') or is a comment (mysqldump ends
# with '-- Dump completed on …'). Only the tail is read; cheap on any size.
_dump_looks_complete() {
  local last
  last="$(tail -c 4096 "$1" | awk 'NF { last = $0 } END { print last }')"
  last="${last%"${last##*[![:space:]]}"}"   # trim trailing whitespace/CR
  case "$last" in
    *\;|--*) return 0 ;;
    *)       return 1 ;;
  esac
}

# Emit a dump file ($1) wrapped so foreign-key + unique checks are off during
# load (out-of-order rows load cleanly, secondary indexes build faster — the
# same session flags mysqldump itself puts in its header). Pipe into a mysql runner.
_fk_wrapped() {
  echo "SET FOREIGN_KEY_CHECKS=0; SET UNIQUE_CHECKS=0;"
  cat "$1"
  echo "SET UNIQUE_CHECKS=1; SET FOREIGN_KEY_CHECKS=1;"
}

# Emit idempotent SQL to (re)provision a database + user with a password. The
# ALTER USER line ensures the password matches the requested one even when the
# user already existed (CREATE USER IF NOT EXISTS alone would keep the old one).
# db/user must be pre-validated with db_ident; pass is free-form (escaped here).
sql_create_db_user() {
  local db="$1" user="$2" pass="$3" pesc; pesc="$(sql_quote_pass "$pass")"
  cat <<SQL
CREATE DATABASE IF NOT EXISTS \`$db\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$user'@'%' IDENTIFIED BY '$pesc';
ALTER USER '$user'@'%' IDENTIFIED BY '$pesc';
GRANT ALL PRIVILEGES ON \`$db\`.* TO '$user'@'%';
FLUSH PRIVILEGES;
SQL
}

# Strip DEFINER=/SQL SECURITY DEFINER from a dump so a missing prod user can't
# break the import. LC_ALL=C: process byte-wise so BSD sed doesn't choke
# ("illegal byte sequence") on non-UTF-8 bytes in latin1/binary columns.
# _DEFINER_SED is the single source for the expressions: strip_definers rewrites
# a file in place; db_import applies the same sed as a stream filter instead.
_DEFINER_SED='s/DEFINER=`[^`]*`@`[^`]*`//g; s/DEFINER=[^ ]*@[^ ]* //g; s/SQL SECURITY DEFINER//g'
strip_definers() {
  LC_ALL=C sed -i '' -E "$_DEFINER_SED" "$1"
}

# harbor db create [<name>] [db] [user] [pass]
db_create() {
  resolve_project "${1-}" "harbor db create [<name>] [db] [user] [pass]"
  [ "$_RP_SHIFT" = 1 ] && shift; local name="$_RP_NAME"
  _db_load "$name"; _db_up_check "$name"
  local db user pass ident; ident="$(db_ident "$name")"
  db="${1:-$ident}"; user="${2:-$db}"; pass="${3:-$db}"
  db="$(db_ident "$db")"; user="$(db_ident "$user")"   # db_ident validates -> injection-safe
  log "creating database '$db' + user '$user'"
  sql_create_db_user "$db" "$user" "$pass" | _db_mysql "$name"
  ok "db '$db' ready (user '$user')"
}

# harbor db drop [<name>] [db]
db_drop() {
  resolve_project "${1-}" "harbor db drop [<name>] [db]"
  [ "$_RP_SHIFT" = 1 ] && shift; local name="$_RP_NAME"
  _db_load "$name"; _db_up_check "$name"
  local db; db="$(db_ident "${1:-$(db_ident "$name")}")"
  confirm "DROP DATABASE \`$db\` on '$name'? This is destructive." || { warn "aborted"; return 1; }
  _db_mysql "$name" -e "DROP DATABASE IF EXISTS \`$db\`;"
  ok "dropped database '$db'"
}

# harbor db backup [<name>] [db] [file]
db_backup() {
  resolve_project "${1-}" "harbor db backup [<name>] [db] [file]"
  [ "$_RP_SHIFT" = 1 ] && shift; local name="$_RP_NAME"
  _db_load "$name"; _db_up_check "$name"
  local db file dir ts; db="$(db_ident "${1:-$(db_ident "$name")}")"
  dir="$HARBOR_BACKUPS/$name"; mkdir -p "$dir"
  ts="$(date +%Y%m%d-%H%M%S)"
  file="${2:-$dir/$db-$ts.sql.gz}"
  log "dumping '$db' -> $file"
  _db_mysqldump "$name" --single-transaction --routines --triggers --no-tablespaces "$db" | gzip > "$file"
  ok "backup: $file"
}

# How many pre-import backups to retain. Precedence: per-project manifest
# `backups.keep` (override) -> global config `DB_BACKUP_KEEP` in Harbor's own
# etc/config (in-tree, gitignored) -> default 3.
# A non-numeric value falls back to the default (never risk pruning on garbage);
# 0 (or negative) means "keep all" — retention disabled.
_db_backup_keep() {
  local name="$1" v
  v="$(manifest_get "$(manifest_path "$name")" backups.keep "")"
  [ -z "$v" ] && v="$(config_get DB_BACKUP_KEEP "")"
  [ -z "$v" ] && v=3
  case "$v" in
    -[0-9]*) : ;;                # negative: keep-all sentinel, allowed
    ''|*[!0-9]*) v=3 ;;          # non-numeric: fall back to the safe default
  esac
  printf '%s' "$v"
}

# Prune old pre-import backups in $bdir, keeping only the newest N (per
# _db_backup_keep), and always report the retention state so the user can see
# the policy is active. Only touches `pre-import-*.sql.gz` — manual `db backup`
# dumps (`<db>-<ts>.sql.gz`) are user-owned and never auto-pruned. The
# timestamped names sort chronologically, so shell glob order is oldest-first.
_db_prune_backups() {
  local name="$1" bdir="$2" keep total del i=0 f
  keep="$(_db_backup_keep "$name")"
  [ -d "$bdir" ] || return 0
  local -a files=()
  for f in "$bdir"/pre-import-*.sql.gz; do
    [ -e "$f" ] || continue                # no matches -> literal glob, skip
    files+=("$f")
  done
  total=${#files[@]}
  [ "$total" -eq 0 ] && return 0
  if [ "$keep" -le 0 ]; then               # 0/negative -> keep all
    step "backup retention off (backups.keep=$keep) — keeping all $total pre-import backup(s)"
    return 0
  fi
  if [ "$total" -le "$keep" ]; then
    step "keeping $total pre-import backup(s) (retention: newest $keep)"
    return 0
  fi
  del=$((total - keep))
  for f in "${files[@]}"; do
    [ "$i" -ge "$del" ] && break
    rm -f "$f"
    i=$((i + 1))
  done
  step "pruned $del old pre-import backup(s), keeping newest $keep"
  return 0
}

# Take a pre-import backup of $db into $bdir, then prune to the retention window
# — but prune ONLY after a good backup. pipefail makes the `if` see mysqldump's
# failure through gzip; gzip still leaves a partial/empty file on failure, and
# keeping that (then pruning to stay within the window) could evict a valid
# older backup. So on failure we drop the partial and leave existing backups
# untouched — no pruning. Always non-fatal: the import proceeds even with no
# backup (a fresh/empty db has nothing worth snapshotting).
_db_autobackup() {
  local name="$1" db="$2" bdir="$3"
  mkdir -p "$bdir"
  local pre tb=$SECONDS; pre="$bdir/pre-import-$(date +%Y%m%d-%H%M%S).sql.gz"
  log "auto-backup before import -> $pre"
  if _db_mysqldump "$name" --single-transaction --no-tablespaces "$db" 2>/dev/null | gzip > "$pre" && [ -s "$pre" ]; then
    step "backed up in $(human_duration $((SECONDS - tb)))  (--no-backup to skip on re-imports)"
    _db_prune_backups "$name" "$bdir"
    return 0
  fi
  rm -f "$pre"
  warn "pre-backup skipped (empty db?) — existing backups left untouched, no pruning"
  return 0
}

# List a project's pre-import backups, NEWEST FIRST, one path per line (empty if
# none). Pure: globs `pre-import-*.sql.gz` — whose embedded YYYYMMDD-HHMMSS names
# sort chronologically — and reverses. Manual `db backup` dumps (`<db>-<ts>`) are
# not matched, so they never appear as restore checkpoints.
_db_checkpoints() {
  local name="$1" bdir f i
  bdir="$HARBOR_BACKUPS/$name"
  [ -d "$bdir" ] || return 0
  local -a files=()
  for f in "$bdir"/pre-import-*.sql.gz; do
    [ -e "$f" ] || continue
    files+=("$f")
  done
  [ "${#files[@]}" -eq 0 ] && return 0
  for (( i=${#files[@]}-1; i>=0; i-- )); do
    printf '%s\n' "${files[$i]}"
  done
}

# Resolve checkpoint index N (1-based, 1 = newest) to a file path. Sets global
# _DB_CKPT_FILE and returns 0 on success; returns 1 (leaving it empty) when N is
# non-numeric, < 1, or beyond the number of checkpoints available.
_db_checkpoint_file() {
  local name="$1" n="$2" line
  _DB_CKPT_FILE=""
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  [ "$n" -ge 1 ] || return 1
  local -a ck=()
  while IFS= read -r line; do
    [ -n "$line" ] && ck+=("$line")
  done < <(_db_checkpoints "$name")
  [ "${#ck[@]}" -ge "$n" ] || return 1
  _DB_CKPT_FILE="${ck[$((n - 1))]}"
  return 0
}

# pre-import-YYYYMMDD-HHMMSS.sql.gz -> "YYYY-MM-DD HH:MM:SS" (pure string slice).
_db_ckpt_stamp() {
  local b d t; b="$(basename "$1")"; b="${b#pre-import-}"; b="${b%.sql.gz}"
  d="${b%%-*}"; t="${b##*-}"
  printf '%s-%s-%s %s:%s:%s' "${d:0:4}" "${d:4:2}" "${d:6:2}" "${t:0:2}" "${t:2:2}" "${t:4:2}"
}

# Print the numbered checkpoint table (newest first). $2=1 (default) appends the
# usage hint — suppressed (0) when the table backs the interactive picker.
_db_restore_list() {
  local name="$1" hint="${2:-1}" i=0 f n
  n="$(_db_checkpoints "$name" | grep -c .)"
  if [ "$n" -eq 0 ]; then
    warn "no pre-import backups for '$name' yet (one is taken automatically before each import/pull)"
    return 0
  fi
  log "pre-import checkpoints for '$name' (newest first):"
  printf '  %3s  %-19s  %8s\n' "#" "taken" "size"
  while IFS= read -r f; do
    i=$((i + 1))
    printf '  %3s  %-19s  %8s\n' "$i" "$(_db_ckpt_stamp "$f")" "$(du -h "$f" 2>/dev/null | cut -f1)"
  done < <(_db_checkpoints "$name")
  [ "$hint" = 1 ] && step "restore the latest: harbor db restore $name   ·   an older one: --checkpoint <#>"
  return 0
}

# Interactive picker: show the table, read a checkpoint number from stdin, and
# set _DB_MENU_CHOICE (1 = newest, the default on Enter). Returns 1 on cancel
# (q/0) or EOF. The deliberate numeric choice over this overwrite-warned prompt
# IS the destructive gate for bare `db restore` — the caller gates entry on an
# interactive stdin (`[ -t 0 ]`) and a non-`HARBOR_YES` run.
_db_restore_menu() {
  local name="$1" db="$2" total="$3" reply
  _DB_MENU_CHOICE=""
  _db_restore_list "$name" 0 >&2
  while :; do
    if ! read -r -p "Restore which # over '$db' (overwrites current data)? [1=latest, q=cancel] " reply; then
      printf '\n' >&2; return 1
    fi
    reply="${reply:-1}"
    case "$reply" in
      q|Q|0) return 1 ;;
      *[!0-9]*) warn "enter a number 1-$total (or q to cancel)"; continue ;;
    esac
    if [ "$reply" -ge 1 ] && [ "$reply" -le "$total" ]; then
      _DB_MENU_CHOICE="$reply"; return 0
    fi
    warn "out of range — pick 1-$total"
  done
}

# Validate hooks before an import so problems surface up front, not after the
# load (or never): a hook you wrote but forgot to chmod +x would be silently
# skipped; a shell hook with a syntax error would die mid-pipeline. `.sample`
# files and post-import *.sql are exempt (inert / piped, not executed).
_validate_hooks() {
  local name="$1" phase d f
  for phase in pre-import post-import; do
    for d in "$HARBOR_ETC/hooks/$phase.d" "$(project_harbor_dir "$name")/hooks/$phase.d"; do
      [ -d "$d" ] || continue
      for f in "$d"/*; do
        [ -e "$f" ] || continue
        case "$phase:$f" in
          *:*.sample) continue ;;
          post-import:*.sql) continue ;;
          pre-import:*.sql)
            warn "hook $(basename "$f"): *.sql only runs post-import — this file will be SKIPPED (make it a script, or move it to post-import.d/)" ;;
          *)
            if [ ! -x "$f" ]; then
              warn "hook $(basename "$f") is not executable — it will be SKIPPED (chmod +x '$f' to enable)"
            elif [ "${f##*.}" = "sh" ] && ! bash -n "$f" 2>/dev/null; then
              die "hook $(basename "$f") has a shell syntax error → bash -n '$f'"
            fi ;;
        esac
      done
    done
  done
}

# run hook scripts in a dir (global first, then project). $@ after dir = env exports handled by caller.
_run_hooks() {
  local phase="$1" name="$2" dir d f
  for d in "$HARBOR_ETC/hooks/$phase.d" "$(project_harbor_dir "$name")/hooks/$phase.d"; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
      [ -e "$f" ] || continue
      case "$phase:$f" in
        post-import:*.sql)
          step "hook (sql): $(basename "$f")"
          _db_mysql "$name" "$HARBOR_IMPORT_DB" < "$f" || die "hook failed: $(basename "$f") ($phase)" ;;
        *)
          # if/fi, NOT `[ -x ] && {…}`: a non-executable file (e.g. a seeded
          # *.sample) as the last entry would make the function return 1 and
          # set -e would kill the import silently.
          if [ -x "$f" ]; then
            step "hook: $(basename "$f")"
            "$f" || die "hook failed: $(basename "$f") ($phase)"
          fi ;;
      esac
    done
  done
}

# harbor db import [<name>] <file> [db] [--no-backup --keep-definers --no-hooks --no-rules --stream-replace --reconfigure --force --replace OLD=NEW]
db_import() {
  resolve_project "${1-}" "harbor db import [<name>] <file> [db]"
  [ "$_RP_SHIFT" = 1 ] && shift; local name="$_RP_NAME"
  local t0=$SECONDS truncated=0
  local file="" db="" nobackup=0 keepdef=0 nohooks=0 norules=0 streamrep=0 reconf=0 force=0
  local -a replaces=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-backup) nobackup=1; shift ;;
      --keep-definers) keepdef=1; shift ;;
      --no-hooks) nohooks=1; shift ;;
      --no-rules) norules=1; shift ;;
      --stream-replace) streamrep=1; shift ;;
      --reconfigure) reconf=1; shift ;;
      --force) force=1; shift ;;
      --replace)
        case "${2-}" in
          *?=*) ;;
          *) usage_die db "harbor db import: --replace needs OLD=NEW (got '${2-}')" ;;
        esac
        replaces+=("$2"); shift 2 ;;
      --*) die "unknown option: $1" ;;
      *) if [ -z "$file" ]; then file="$1"; else db="$1"; fi; shift ;;
    esac
  done
  [ -n "$file" ] && [ -f "$file" ] || usage_die db "harbor db import [<name>] <file> [db]"
  _db_load "$name"; _db_up_check "$name"
  db="$(db_ident "${db:-$(db_ident "$name")}")"
  export HARBOR_IMPORT_DB="$db"

  local phpcli; phpcli="$(php_cli_bin "$(_project_php_ver "$name")")"

  # temp workspace up front (all temps under one dir, cleaned on any exit) —
  # rules are assembled and validated here, BEFORE the backup/decompress/load
  # work, so a typo'd rule or broken hook can't waste an import. Scratch lives
  # under Harbor's own var/tmp (not the OS $TMPDIR), so a multi-GB decompress
  # stays inside Harbor and teardown can reclaim it.
  mkdir -p "$HARBOR_TMP"
  local tmpd; tmpd="$(mktemp -d "$HARBOR_TMP/harbor-import.XXXXXX")"
  # bake $tmpd into the trap NOW: it's a function-local, gone by the time EXIT fires.
  # shellcheck disable=SC2064
  trap "rm -rf '$tmpd'" EXIT

  # build rules file (import-rules + --replace)
  local rulesf="$tmpd/rules"; : > "$rulesf"
  if [ "$norules" = 0 ] && [ -f "$(project_harbor_dir "$name")/import-rules" ]; then
    # convert "old => new" / "re:pat => new" to FROM<TAB>TO. Drop comments AND
    # blank lines — a rules file that strips to nothing must leave $rulesf empty,
    # or the [ -s ] gate below would run a full serialized-replace table scan
    # with zero rules on every import (init seeds a fully-commented sample).
    sed -E 's/[[:space:]]*=>[[:space:]]*/\t/' "$(project_harbor_dir "$name")/import-rules" \
      | grep -vE '^[[:space:]]*(#|$)' >> "$rulesf" || true
  fi
  local rp
  for rp in "${replaces[@]:-}"; do
    [ -n "$rp" ] || continue
    printf '%s\t%s\n' "${rp%%=*}" "${rp#*=}" >> "$rulesf"
  done

  # validate rules + hooks before any heavy lifting
  if [ -s "$rulesf" ]; then
    "$phpcli" "$HARBOR_LIB/search-replace.php" --rules "$rulesf" --check >/dev/null \
      || die "invalid import rules (see above) → fix $(project_harbor_dir "$name")/import-rules"
  fi
  if [ "$nohooks" = 0 ]; then _validate_hooks "$name"; fi

  # ensure target db exists
  _db_mysql "$name" -e "CREATE DATABASE IF NOT EXISTS \`$db\` CHARACTER SET utf8mb4;"

  # 1+2. decompress AND strip DEFINER in one streaming pass — the old
  # copy-then-sed-in-place rewrote the whole (multi-GB) file twice.
  local work="$tmpd/dump.sql" t1=$SECONDS
  if [ "$keepdef" = 0 ]; then
    log "decompressing $file (stripping DEFINER clauses)"
    _db_stream "$file" | LC_ALL=C sed -E "$_DEFINER_SED" > "$work"
  else
    log "decompressing $file"
    _db_decompress "$file" "$work"
  fi
  step "prepared in $(human_duration $((SECONDS - t1)))"

  # refuse a truncated dump up front — loading one "succeeds" per-statement but
  # silently drops every table after the cut (a Magento dump cut in the s's has
  # no store/url_rewrite). --force keeps its best-effort meaning and loads anyway.
  # This runs BEFORE the auto-backup on purpose: a truncated dump aborts with
  # nothing loaded (so a pre-import backup would be pure waste), and taking one
  # anyway would churn the retention window — pruning a valid older checkpoint
  # out of the keep=N window for an import that never happened. Same fail-fast
  # rationale as the rules/hooks validation above; the check only tails $work,
  # which we had to decompress for the load regardless.
  if ! _dump_looks_complete "$work"; then
    if [ "$force" = 1 ]; then
      truncated=1
      warn "dump looks TRUNCATED (ends mid-statement) — loading what's there (--force)"
    else
      die "dump looks truncated — it ends mid-statement, so every table after the cut is missing (interrupted download/export?) → re-export or re-download it; --force loads the partial dump anyway"
    fi
  fi

  # 0. auto-backup (+ retention prune, only on a successful backup). After the
  # truncation guard: we back up only once the dump we're about to load looks
  # complete, so a rejected dump never touches the pre-import retention window.
  if [ "$nobackup" = 0 ]; then
    _db_autobackup "$name" "$db" "$HARBOR_BACKUPS/$name"
  fi

  # optional in-stream literal replace (fast; not serialized-safe).
  # Uses a SOH (\001) sed delimiter so rule text containing | / & etc. is safe;
  # rules are literal strings, so escape sed regex metacharacters in the pattern.
  if [ "$streamrep" = 1 ] && [ -s "$rulesf" ]; then
    step "stream-replace (literal, pre-load)"
    local d; d="$(printf '\001')"
    while IFS="$(printf '\t')" read -r from to; do
      [ -n "$from" ] || continue
      local fe te
      fe="$(printf '%s' "$from" | sed 's/[.[\*^$]/\\&/g')"   # escape BRE metachars
      te="$(printf '%s' "$to"   | sed 's/[\&]/\\&/g')"       # escape & and backslash in replacement
      LC_ALL=C sed -i '' "s${d}${fe}${d}${te}${d}g" "$work" || warn "stream-replace rule failed: $from"
    done < "$rulesf"
  fi

  # 3. pre-import hooks (operate on $HARBOR_DUMP)
  if [ "$nohooks" = 0 ]; then
    HARBOR_DUMP="$work" HARBOR_PROJECT="$name" HARBOR_PROJECT_DIR="$(project_dir "$name")" \
    HARBOR_FRAMEWORK="$(manifest_get "$(manifest_path "$name")" framework plain)" \
    HARBOR_DB="$db" HARBOR_PHP="$phpcli" \
    _run_hooks pre-import "$name"
  fi

  # 4. load
  # --force: skip statements the server rejects (e.g. explicit values for a
  # generated column, like Laravel Pulse's key_hash) instead of aborting.
  local forceflag=""
  [ "$force" = 1 ] && { forceflag="--force"; step "loading with --force (rejected statements skipped, not aborted)"; }
  # Relax durability for the bulk load: with the default
  # innodb_flush_log_at_trx_commit=1 the server fsyncs on EVERY commit — the
  # classic dump-replay killer (a 4.5G Magento dump: ~40min -> ~10min). =2
  # flushes once a second instead; worst case on a crash is losing <1s of a
  # load we'd redo anyway. GLOBAL-only knob, so restore the old value after.
  # (If the load dies mid-way the value stays at 2 until the next import or a
  # container restart — a durability/perf knob on a local dev server, harmless.)
  local flush_prev; flush_prev="$(_db_mysql "$name" -N -e 'SELECT @@innodb_flush_log_at_trx_commit;' 2>/dev/null | tr -d '[:space:]')"
  case "$flush_prev" in 0|1|2|3) ;; *) flush_prev="" ;; esac
  if [ -n "$flush_prev" ]; then
    _db_mysql "$name" -e 'SET GLOBAL innodb_flush_log_at_trx_commit=2;' 2>/dev/null || flush_prev=""
  fi
  log "loading into '$db' (FK + unique checks off)"
  local t2=$SECONDS
  # shellcheck disable=SC2086
  _fk_wrapped "$work" | _db_mysql "$name" $forceflag "$db"
  step "loaded in $(human_duration $((SECONDS - t2)))"
  if [ -n "$flush_prev" ]; then
    _db_mysql "$name" -e "SET GLOBAL innodb_flush_log_at_trx_commit=$flush_prev;" 2>/dev/null || true
  fi

  # 5. serialized-safe search/replace (post-load), unless stream-replace already did it
  if [ "$streamrep" = 0 ] && [ -s "$rulesf" ]; then
    step "serialized-safe search/replace"
    # 512M: reads stream row-by-row (unbuffered), but one row can hold a large
    # serialized blob and rr() recursion tops the 128M CLI default.
    local t3=$SECONDS
    "$phpcli" -d memory_limit=512M "$HARBOR_LIB/search-replace.php" \
      --host 127.0.0.1 --port "$DB_PORT" --user root --pass "$DB_ROOT_PASSWORD" --db "$db" --rules "$rulesf"
    step "replaced in $(human_duration $((SECONDS - t3)))"
  fi

  # 6. post-import hooks (operate on the live DB via $HARBOR_MYSQL)
  if [ "$nohooks" = 0 ]; then
    local mysqlwrap="$tmpd/mysql.sh"
    cat > "$mysqlwrap" <<EOF
#!/usr/bin/env bash
exec docker compose -f "$(project_compose_file "$name")" exec -T -e MYSQL_PWD="$DB_ROOT_PASSWORD" mysql mysql -uroot "$db" "\$@"
EOF
    chmod +x "$mysqlwrap"
    HARBOR_MYSQL="$mysqlwrap" HARBOR_PROJECT="$name" HARBOR_PROJECT_DIR="$(project_dir "$name")" \
    HARBOR_DB="$db" HARBOR_DB_HOST=127.0.0.1 HARBOR_DB_PORT="$DB_PORT" \
    HARBOR_DB_USER=root HARBOR_DB_PASS="$DB_ROOT_PASSWORD" \
    _run_hooks post-import "$name"
  fi

  # 7. Magento reconfigure
  if [ "$reconf" = 1 ]; then magento_reconfigure "$name" || warn "magento reconfigure skipped"; fi

  rm -rf "$tmpd"; trap - EXIT
  local bytes; bytes="$(stat -f%z "$file" 2>/dev/null || echo 0)"
  if [ "$truncated" = 1 ]; then
    warn "loaded from a TRUNCATED dump — every table after the cut is missing"
  fi
  ok "import complete -> $db ($(human_size "$bytes") dump in $(human_duration $((SECONDS - t0))))"
}

# harbor db restore [<name>] [--list] [--checkpoint N] [--no-backup]
# Roll the project DB back to a pre-import backup. Checkpoints are numbered
# newest-first (#1 = the backup from your last import). A verbatim reload — no
# import-rules, no hooks, DEFINERs kept — because a pre-import backup is already
# your own local, wired data. Snapshots the current DB first (so the restore is
# itself undoable) by delegating the load to db_import, which owns the
# auto-backup + retention machinery.
db_restore() {
  resolve_project "${1-}" "harbor db restore [<name>] [--list] [--checkpoint N] [--no-backup]"
  [ "$_RP_SHIFT" = 1 ] && shift; local name="$_RP_NAME"
  local list=0 ckpt=1 ckpt_explicit=0 nobackup=0 menu_used=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --list|-l) list=1; shift ;;
      --checkpoint|-c)
        case "${2-}" in
          ''|*[!0-9]*) usage_die db-restore "harbor db restore: --checkpoint needs a positive number (got '${2-}')" ;;
        esac
        ckpt="$2"; ckpt_explicit=1; shift 2 ;;
      --no-backup) nobackup=1; shift ;;
      *) usage_die db-restore "harbor db restore [<name>] [--list] [--checkpoint N] [--no-backup]  (unexpected: $1)" ;;
    esac
  done
  _db_load "$name"; _db_up_check "$name"
  local db; db="$(db_ident "$name")"

  if [ "$list" = 1 ]; then _db_restore_list "$name"; return 0; fi

  local have; have="$(_db_checkpoints "$name" | grep -c .)"
  [ "$have" -eq 0 ] && die "no pre-import backups for '$name' to restore (one is taken automatically before each import/pull)"

  # Bare `db restore` on an interactive terminal: let the user pick from the
  # numbered list (latest = #1, the default on Enter). That deliberate choice is
  # the destructive gate, so no extra confirm below. `--checkpoint`, HARBOR_YES,
  # and a non-tty stdin all skip the menu and fall through to confirm()/#1.
  if [ "$ckpt_explicit" = 0 ] && [ "${HARBOR_YES:-0}" != 1 ] && [ -t 0 ]; then
    if _db_restore_menu "$name" "$db" "$have"; then ckpt="$_DB_MENU_CHOICE"; menu_used=1
    else warn "aborted"; return 1; fi
  fi

  # resolve the requested checkpoint (fail fast with the real count + a hint)
  if ! _db_checkpoint_file "$name" "$ckpt"; then
    die "no checkpoint #$ckpt for '$name' — only $have available → harbor db restore $name --list"
  fi
  local src="$_DB_CKPT_FILE" ts; ts="$(_db_ckpt_stamp "$src")"

  # Stage the checkpoint into var/tmp BEFORE the pre-restore snapshot: that
  # snapshot's retention prune could otherwise delete this very file (restoring
  # the oldest at the keep limit). Prune only ever touches backups/db/<name>, so
  # a copy under Harbor's own var/tmp is safe.
  mkdir -p "$HARBOR_TMP"
  local safe; safe="$(mktemp "$HARBOR_TMP/harbor-restore.XXXXXX")" || die "mktemp failed"
  mv "$safe" "$safe.sql.gz" || { rm -f "$safe"; die "could not prepare temp file"; }
  safe="$safe.sql.gz"
  cp "$src" "$safe" || { rm -f "$safe"; die "could not stage checkpoint for restore"; }

  # The menu already served as the interactive gate; otherwise confirm the overwrite.
  if [ "$menu_used" = 0 ]; then
    confirm "Restore checkpoint #$ckpt ($ts) over database '$db' on '$name'? This overwrites the current data." \
      || { warn "aborted"; rm -f "$safe"; return 1; }
  fi

  # Verbatim reload via the existing loader. --no-rules/--no-hooks/--keep-definers
  # make it faithful; db_import takes the pre-restore snapshot (+ prune/report)
  # unless --no-backup. Plain call (not `if …`) so set -e stays live inside it.
  local -a impflags=(--no-rules --no-hooks --keep-definers)
  [ "$nobackup" = 1 ] && impflags+=(--no-backup)
  db_import "$name" "$safe" "$db" "${impflags[@]}"
  rm -f "$safe"
  ok "restored '$name' from checkpoint #$ckpt ($ts)"
}

cmd_db() {
  local sub="${1-}"; shift || true
  case "$sub" in
    sandbox) cmd_db_sandbox "$@" ;;
    create) db_create "$@" ;;
    drop)   db_drop "$@" ;;
    backup) db_backup "$@" ;;
    import) db_import "$@" ;;
    pull)   db_pull "$@" ;;
    restore) db_restore "$@" ;;
    *) usage_die db "harbor db create|drop|backup|import|pull|restore [<name>] ...  |  harbor db sandbox <sub>" ;;
  esac
}
