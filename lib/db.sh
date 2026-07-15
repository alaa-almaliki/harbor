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

# Decompress a dump ($1) to a working file ($2), by extension: .sql.gz/.gz, .zip,
# or plain copy.
_db_decompress() {
  case "$1" in
    *.sql.gz|*.gz) gunzip -c "$1" > "$2" ;;
    *.zip)         unzip -p "$1" > "$2" ;;
    *)             cp "$1" "$2" ;;
  esac
}

# Emit a dump file ($1) wrapped so foreign-key checks are off during load (lets
# out-of-order rows/constraints load cleanly). Pipe into a mysql runner.
_fk_wrapped() { echo "SET FOREIGN_KEY_CHECKS=0;"; cat "$1"; echo "SET FOREIGN_KEY_CHECKS=1;"; }

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

# Strip DEFINER=/SQL SECURITY DEFINER from a dump file in place so a missing prod
# user can't break the import. LC_ALL=C: process byte-wise so BSD sed doesn't
# choke ("illegal byte sequence") on non-UTF-8 bytes in latin1/binary columns.
strip_definers() {
  LC_ALL=C sed -i '' -E 's/DEFINER=`[^`]*`@`[^`]*`//g; s/DEFINER=[^ ]*@[^ ]* //g; s/SQL SECURITY DEFINER//g' "$1"
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

# run hook scripts in a dir (global first, then project). $@ after dir = env exports handled by caller.
_run_hooks() {
  local phase="$1" name="$2" dir d f
  for d in "$HARBOR_ETC/hooks/$phase.d" "$(project_harbor_dir "$name")/hooks/$phase.d"; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
      [ -e "$f" ] || continue
      case "$phase:$f" in
        post-import:*.sql) step "hook (sql): $(basename "$f")"; _db_mysql "$name" "$HARBOR_IMPORT_DB" < "$f" ;;
        *) [ -x "$f" ] && { step "hook: $(basename "$f")"; "$f"; } ;;
      esac
    done
  done
}

# harbor db import <name> <file> [db] [--no-backup --keep-definers --no-hooks --no-rules --stream-replace --reconfigure --force --replace OLD=NEW]
db_import() {
  require_name "${1-}"; local name="$1"; shift
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
      --replace) replaces+=("${2-}"); shift 2 ;;
      --*) die "unknown option: $1" ;;
      *) if [ -z "$file" ]; then file="$1"; else db="$1"; fi; shift ;;
    esac
  done
  [ -n "$file" ] && [ -f "$file" ] || usage_die db "harbor db import <name> <file> [db]"
  _db_load "$name"; _db_up_check "$name"
  db="$(db_ident "${db:-$(db_ident "$name")}")"
  export HARBOR_IMPORT_DB="$db"

  local phpcli; phpcli="$(php_cli_bin "$(_project_php_ver "$name")")"

  # ensure target db exists
  _db_mysql "$name" -e "CREATE DATABASE IF NOT EXISTS \`$db\` CHARACTER SET utf8mb4;"

  # 0. auto-backup
  if [ "$nobackup" = 0 ]; then
    local bdir="$HARBOR_BACKUPS/$name"; mkdir -p "$bdir"
    local pre; pre="$bdir/pre-import-$(date +%Y%m%d-%H%M%S).sql.gz"
    log "auto-backup before import -> $pre"
    _db_mysqldump "$name" --single-transaction --no-tablespaces "$db" 2>/dev/null | gzip > "$pre" || warn "pre-backup skipped (empty db?)"
  fi

  # 1. decompress to a working file (all temps under one dir, cleaned on any exit)
  local tmpd; tmpd="$(mktemp -d "${TMPDIR:-/tmp}/harbor-import.XXXXXX")"
  # bake $tmpd into the trap NOW: it's a function-local, gone by the time EXIT fires.
  # shellcheck disable=SC2064
  trap "rm -rf '$tmpd'" EXIT
  local work="$tmpd/dump.sql"
  log "decompressing $file"
  _db_decompress "$file" "$work"

  # 2. strip DEFINER
  if [ "$keepdef" = 0 ]; then
    step "stripping DEFINER clauses"
    strip_definers "$work"
  fi

  # build rules file (import-rules + --replace)
  local rulesf="$tmpd/rules"; : > "$rulesf"
  if [ "$norules" = 0 ] && [ -f "$(project_harbor_dir "$name")/import-rules" ]; then
    # convert "old => new" / "re:pat => new" to FROM<TAB>TO
    sed -E 's/[[:space:]]*=>[[:space:]]*/\t/' "$(project_harbor_dir "$name")/import-rules" | grep -v '^[[:space:]]*#' >> "$rulesf" || true
  fi
  local rp
  for rp in "${replaces[@]:-}"; do
    [ -n "$rp" ] || continue
    printf '%s\t%s\n' "${rp%%=*}" "${rp#*=}" >> "$rulesf"
  done

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
  log "loading into '$db' (FK checks off)"
  # shellcheck disable=SC2086
  _fk_wrapped "$work" | _db_mysql "$name" $forceflag "$db"

  # 5. serialized-safe search/replace (post-load), unless stream-replace already did it
  if [ "$streamrep" = 0 ] && [ -s "$rulesf" ]; then
    step "serialized-safe search/replace"
    "$phpcli" "$HARBOR_LIB/search-replace.php" \
      --host 127.0.0.1 --port "$DB_PORT" --user root --pass "$DB_ROOT_PASSWORD" --db "$db" --rules "$rulesf"
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
  ok "import complete -> $db"
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
