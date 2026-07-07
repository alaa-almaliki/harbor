#!/usr/bin/env bash
# sandbox.sh — a project-independent scratch MySQL server for testing and
# checking things out. A Harbor-owned singleton stack (like the shared
# mailpit+redis one) bound to 127.0.0.1:3306, with its own lifecycle so you can
# create and destroy throwaway databases without attaching them to a project.
#
#   harbor db sandbox create|drop|list|backup|restore|console|up|down|destroy|status
#
# Loopback-only, RAM-capped, reversible: `harbor teardown` stops it, `--purge`
# drops its data volume. All SQL runs inside the container as root (no host
# mysql client); identifiers go through db_ident so they're injection-safe.

HARBOR_SANDBOX_COMPOSE="$HARBOR_DOCKER/sandbox.yml"

# config knobs (overridable in ~/.config/harbor/config), sensible defaults:
_sandbox_port()  { config_get SANDBOX_MYSQL_PORT 3306; }
_sandbox_image() { config_get SANDBOX_MYSQL_IMAGE "$(config_get MYSQL_IMAGE mysql:8.0)"; }
_sandbox_root()  { config_get MYSQL_ROOT_PASSWORD root; }

sandbox_render() {
  mkdir -p "$HARBOR_DOCKER"
  local image; image="$(_sandbox_image)"
  MYSQL_IMAGE="$image" \
  DB_COMMAND="$(_db_command "$image" "$(config_get MYSQL_BUFFER_POOL 256M)")" \
  MYSQL_ROOT_PASS="$(_sandbox_root)" \
  MYSQL_PORT="$(_sandbox_port)" \
  render "$HARBOR_TEMPLATES/compose/sandbox.yml.tmpl" "$HARBOR_SANDBOX_COMPOSE"
}

_sandbox_compose() {
  [ -f "$HARBOR_SANDBOX_COMPOSE" ] || sandbox_render
  docker compose -f "$HARBOR_SANDBOX_COMPOSE" "$@"
}

_sandbox_running() { _sandbox_compose ps -q mysql 2>/dev/null | grep -q .; }

# root mysql / mysqldump inside the container
_sandbox_mysql()     { _sandbox_compose exec -T -e MYSQL_PWD="$(_sandbox_root)" mysql mysql -uroot "$@"; }
_sandbox_mysqldump() { _sandbox_compose exec -T -e MYSQL_PWD="$(_sandbox_root)" mysql mysqldump -uroot "$@"; }

sandbox_up() {
  docker info >/dev/null 2>&1 || die "docker daemon not running — start Docker/OrbStack"
  sandbox_render
  local port; port="$(_sandbox_port)"
  step "starting sandbox MySQL ($(_sandbox_image)) on 127.0.0.1:$port"
  if ! _sandbox_compose up -d 2>/dev/null; then
    die "sandbox failed to start — is 127.0.0.1:$port already in use? (set SANDBOX_MYSQL_PORT in $HARBOR_CONFIG)"
  fi
  # wait for the healthcheck to report ready before returning
  local i=0
  printf '   waiting for mysql'
  while [ "$i" -lt 45 ]; do
    case "$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
              "$(_sandbox_compose ps -q mysql 2>/dev/null)" 2>/dev/null)" in
      healthy|none) printf ' ready\n'; return 0 ;;
    esac
    printf '.'; i=$((i + 1)); sleep 2
  done
  printf '\n'; warn "timeout waiting for sandbox health (continuing)"
}

# bring the stack up on demand for a command that needs it
_sandbox_ensure() { _sandbox_running || sandbox_up; }

# escape a password for a single-quoted SQL literal (\ then '); MySQL default mode
_sql_quote_pass() { local p="$1"; p="${p//\\/\\\\}"; printf '%s' "${p//\'/\'\'}"; }

# harbor db sandbox create <db> [user] [pass]
sandbox_create() {
  local db="${1-}"; [ -n "$db" ] || die "usage: harbor db sandbox create <db> [user] [pass]"
  _sandbox_ensure
  local user pass pesc port; db="$(db_ident "$db")"
  user="$(db_ident "${2:-$db}")"; pass="${3:-$db}"; pesc="$(_sql_quote_pass "$pass")"
  port="$(_sandbox_port)"
  log "creating database '$db' + user '$user' on sandbox"
  _sandbox_mysql <<SQL
CREATE DATABASE IF NOT EXISTS \`$db\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$user'@'%' IDENTIFIED BY '$pesc';
GRANT ALL PRIVILEGES ON \`$db\`.* TO '$user'@'%';
FLUSH PRIVILEGES;
SQL
  ok "sandbox db ready:"
  printf '  host/port : 127.0.0.1:%s\n  database  : %s\n  user/pass : %s / %s\n' "$port" "$db" "$user" "$pass"
}

# harbor db sandbox drop <db>   (drops the database and its same-named user, if any)
sandbox_drop() {
  local db="${1-}"; [ -n "$db" ] || die "usage: harbor db sandbox drop <db>"
  _sandbox_ensure; db="$(db_ident "$db")"
  confirm "DROP DATABASE \`$db\` on the sandbox? This is destructive." || { warn "aborted"; return 1; }
  _sandbox_mysql <<SQL
DROP DATABASE IF EXISTS \`$db\`;
DROP USER IF EXISTS '$db'@'%';
FLUSH PRIVILEGES;
SQL
  ok "dropped sandbox database '$db'"
}

# harbor db sandbox list
sandbox_list() {
  _sandbox_ensure
  log "sandbox databases:"
  _sandbox_mysql -N -e "SHOW DATABASES;" \
    | grep -Ev '^(information_schema|performance_schema|mysql|sys)$' \
    | sed 's/^/  /' || true
}

# harbor db sandbox backup <db> [file]
sandbox_backup() {
  local db="${1-}"; [ -n "$db" ] || die "usage: harbor db sandbox backup <db> [file]"
  _sandbox_ensure; db="$(db_ident "$db")"
  local dir file ts; dir="$HARBOR_BACKUPS/sandbox"; mkdir -p "$dir"
  ts="$(date +%Y%m%d-%H%M%S)"; file="${2:-$dir/$db-$ts.sql.gz}"
  log "dumping sandbox '$db' -> $file"
  _sandbox_mysqldump --single-transaction --routines --triggers --no-tablespaces "$db" | gzip > "$file"
  ok "backup: $file"
}

# harbor db sandbox restore <db> <file>   (load a dump; auto-creates the db)
sandbox_restore() {
  local db="${1-}" file="${2-}"
  [ -n "$db" ] && [ -n "$file" ] && [ -f "$file" ] || die "usage: harbor db sandbox restore <db> <file>"
  _sandbox_ensure; db="$(db_ident "$db")"
  local tmpd; tmpd="$(mktemp -d "${TMPDIR:-/tmp}/harbor-sandbox.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmpd'" EXIT
  local work="$tmpd/dump.sql"
  log "decompressing $file"
  case "$file" in
    *.sql.gz|*.gz) gunzip -c "$file" > "$work" ;;
    *.zip)         unzip -p "$file" > "$work" ;;
    *)             cp "$file" "$work" ;;
  esac
  # strip DEFINER for portability (LC_ALL=C so BSD sed tolerates non-UTF-8 bytes)
  step "stripping DEFINER clauses"
  LC_ALL=C sed -i '' -E 's/DEFINER=`[^`]*`@`[^`]*`//g; s/DEFINER=[^ ]*@[^ ]* //g; s/SQL SECURITY DEFINER//g' "$work"
  _sandbox_mysql -e "CREATE DATABASE IF NOT EXISTS \`$db\` CHARACTER SET utf8mb4;"
  log "loading into sandbox '$db' (FK checks off)"
  { echo "SET FOREIGN_KEY_CHECKS=0;"; cat "$work"; echo "SET FOREIGN_KEY_CHECKS=1;"; } | _sandbox_mysql "$db"
  rm -rf "$tmpd"; trap - EXIT
  ok "restore complete -> $db"
}

# harbor db sandbox console [db]   (interactive mysql shell as root)
sandbox_console() {
  _sandbox_ensure
  local db="${1-}"; [ -n "$db" ] && db="$(db_ident "$db")"
  _sandbox_compose exec -e MYSQL_PWD="$(_sandbox_root)" mysql mysql -uroot ${db:+"$db"}
}

sandbox_down() {
  [ -f "$HARBOR_SANDBOX_COMPOSE" ] || { warn "sandbox not started"; return 0; }
  step "stopping sandbox MySQL (data kept — 'harbor db sandbox destroy' drops it)"
  _sandbox_compose down >/dev/null 2>&1 || true
  ok "sandbox down"
}

sandbox_destroy() {
  confirm "Destroy the sandbox MySQL (drop container + ALL its databases)?" || { warn "aborted"; return 1; }
  [ -f "$HARBOR_SANDBOX_COMPOSE" ] && _sandbox_compose down -v >/dev/null 2>&1 || true
  ok "sandbox destroyed (data volume dropped)"
}

sandbox_status() {
  local port; port="$(_sandbox_port)"
  if _sandbox_running; then
    printf 'sandbox : running  127.0.0.1:%s  (%s)\n' "$port" "$(_sandbox_image)"
    sandbox_list
  else
    printf 'sandbox : stopped  (would bind 127.0.0.1:%s)\n' "$port"
    step "start it with any command, e.g.: harbor db sandbox create test"
  fi
}

# harbor db sandbox <sub> ...
cmd_db_sandbox() {
  local sub="${1-}"; shift || true
  case "$sub" in
    create)  sandbox_create "$@" ;;
    drop)    sandbox_drop "$@" ;;
    list|ls) sandbox_list ;;
    backup)  sandbox_backup "$@" ;;
    restore|import) sandbox_restore "$@" ;;
    console|mysql)  sandbox_console "$@" ;;
    up)      sandbox_up ;;
    down|stop) sandbox_down ;;
    destroy) sandbox_destroy ;;
    status|""|ps) sandbox_status ;;
    *) die "usage: harbor db sandbox create|drop|list|backup|restore|console|up|down|destroy|status" ;;
  esac
}
