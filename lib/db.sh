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

_db_up_check() {
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

# harbor db create <name> [db] [user] [pass]
db_create() {
  require_name "${1-}"; local name="$1"; _db_load "$name"; _db_up_check "$name"
  local db user pass ident; ident="$(db_ident "$name")"
  db="${2:-$ident}"; user="${3:-$db}"; pass="${4:-$db}"
  db="$(db_ident "$db")"; user="$(db_ident "$user")"   # db_ident validates -> injection-safe
  log "creating database '$db' + user '$user'"
  sql_create_db_user "$db" "$user" "$pass" | _db_mysql "$name"
  ok "db '$db' ready (user '$user')"
}

# harbor db drop <name> [db]
db_drop() {
  require_name "${1-}"; local name="$1"; _db_load "$name"; _db_up_check "$name"
  local db; db="$(db_ident "${2:-$(db_ident "$name")}")"
  confirm "DROP DATABASE \`$db\` on '$name'? This is destructive." || { warn "aborted"; return 1; }
  _db_mysql "$name" -e "DROP DATABASE IF EXISTS \`$db\`;"
  ok "dropped database '$db'"
}

# harbor db backup <name> [db] [file]
db_backup() {
  require_name "${1-}"; local name="$1"; _db_load "$name"; _db_up_check "$name"
  local db file dir ts; db="$(db_ident "${2:-$(db_ident "$name")}")"
  dir="$HARBOR_BACKUPS/$name"; mkdir -p "$dir"
  ts="$(date +%Y%m%d-%H%M%S)"
  file="${3:-$dir/$db-$ts.sql.gz}"
  log "dumping '$db' -> $file"
  _db_mysqldump "$name" --single-transaction --routines --triggers --no-tablespaces "$db" | gzip > "$file"
  ok "backup: $file"
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

# harbor db import <name> <file> [db] [--no-backup --keep-definers --no-hooks --no-rules --stream-replace --reconfigure --force --replace OLD=NEW]
db_import() {
  require_name "${1-}"; local name="$1"; shift
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
  [ -n "$file" ] && [ -f "$file" ] || usage_die db "harbor db import <name> <file> [db]"
  _db_load "$name"; _db_up_check "$name"
  db="$(db_ident "${db:-$(db_ident "$name")}")"
  export HARBOR_IMPORT_DB="$db"

  local phpcli; phpcli="$(php_cli_bin "$(_project_php_ver "$name")")"

  # temp workspace up front (all temps under one dir, cleaned on any exit) —
  # rules are assembled and validated here, BEFORE the backup/decompress/load
  # work, so a typo'd rule or broken hook can't waste an import.
  local tmpd; tmpd="$(mktemp -d "${TMPDIR:-/tmp}/harbor-import.XXXXXX")"
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

  # 0. auto-backup
  if [ "$nobackup" = 0 ]; then
    local bdir="$HARBOR_BACKUPS/$name"; mkdir -p "$bdir"
    local pre tb=$SECONDS; pre="$bdir/pre-import-$(date +%Y%m%d-%H%M%S).sql.gz"
    log "auto-backup before import -> $pre"
    _db_mysqldump "$name" --single-transaction --no-tablespaces "$db" 2>/dev/null | gzip > "$pre" || warn "pre-backup skipped (empty db?)"
    step "backed up in $(human_duration $((SECONDS - tb)))  (--no-backup to skip on re-imports)"
  fi

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
  if ! _dump_looks_complete "$work"; then
    if [ "$force" = 1 ]; then
      truncated=1
      warn "dump looks TRUNCATED (ends mid-statement) — loading what's there (--force)"
    else
      die "dump looks truncated — it ends mid-statement, so every table after the cut is missing (interrupted download/export?) → re-export or re-download it; --force loads the partial dump anyway"
    fi
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

cmd_db() {
  local sub="${1-}"; shift || true
  case "$sub" in
    sandbox) cmd_db_sandbox "$@" ;;
    create) db_create "$@" ;;
    drop)   db_drop "$@" ;;
    backup) db_backup "$@" ;;
    import) db_import "$@" ;;
    pull)   db_pull "$@" ;;
    *) usage_die db "harbor db create|drop|backup|import|pull <name> ...  |  harbor db sandbox <sub>" ;;
  esac
}
