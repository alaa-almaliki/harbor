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

# Never renders — callers that need the stack up go through sandbox_up (which
# renders explicitly). Read-only callers stay side-effect free, so querying a
# never-started sandbox doesn't write docker/sandbox.yml to disk.
_sandbox_compose() { docker compose -f "$HARBOR_SANDBOX_COMPOSE" "$@"; }

# A missing compose file means "never started" -> stopped, without rendering it.
_sandbox_running() {
  [ -f "$HARBOR_SANDBOX_COMPOSE" ] || return 1
  _sandbox_compose ps -q mysql 2>/dev/null | grep -q .
}

# root mysql / mysqldump inside the container
_sandbox_mysql()     { _sandbox_compose exec -T -e MYSQL_PWD="$(_sandbox_root)" mysql mysql -uroot "$@"; }
_sandbox_mysqldump() { _sandbox_compose exec -T -e MYSQL_PWD="$(_sandbox_root)" mysql mysqldump -uroot "$@"; }

sandbox_up() {
  require_docker
  sandbox_render
  local port; port="$(_sandbox_port)"
  step "starting sandbox MySQL ($(_sandbox_image)) on 127.0.0.1:$port"
  if ! _sandbox_compose up -d 2>/dev/null; then
    die "sandbox failed to start — is 127.0.0.1:$port already in use? (set SANDBOX_MYSQL_PORT in $HARBOR_CONFIG)"
  fi
  # wait for the healthcheck to report ready before returning (shared with projects)
  printf '   waiting for mysql'
  if _wait_healthy_ids "$(_sandbox_compose ps -q mysql 2>/dev/null)" 45; then
    printf ' ready\n'
  else
    printf '\n'; warn "timeout waiting for sandbox health (continuing)"
  fi
}

# bring the stack up on demand for a command that needs it
_sandbox_ensure() { _sandbox_running || sandbox_up; }

# harbor db sandbox create <db> [user] [pass]
sandbox_create() {
  local db="${1-}"; [ -n "$db" ] || usage_die db-sandbox "harbor db sandbox create <db> [user] [pass]"
  _sandbox_ensure
  local user pass port; db="$(db_ident "$db")"
  user="$(db_ident "${2:-$db}")"; pass="${3:-$db}"; port="$(_sandbox_port)"
  log "creating database '$db' + user '$user' on sandbox"
  # shared emitter (idempotent; ALTER USER keeps the password in sync with what
  # we print below, even when the user already existed)
  sql_create_db_user "$db" "$user" "$pass" | _sandbox_mysql
  ok "sandbox db ready:"
  printf '  host/port : 127.0.0.1:%s\n  database  : %s\n  user/pass : %s / %s\n' "$port" "$db" "$user" "$pass"
}

# harbor db sandbox drop <db> [user]   (drops the database and the user; user
# defaults to the db name — pass it explicitly to clean up a custom-named user)
sandbox_drop() {
  local db="${1-}"; [ -n "$db" ] || usage_die db-sandbox "harbor db sandbox drop <db> [user]"
  _sandbox_ensure; db="$(db_ident "$db")"
  local user; user="$(db_ident "${2:-$db}")"
  confirm "DROP DATABASE \`$db\` (and user '$user') on the sandbox? This is destructive." || { warn "aborted"; return 1; }
  _sandbox_mysql <<SQL
DROP DATABASE IF EXISTS \`$db\`;
DROP USER IF EXISTS '$user'@'%';
FLUSH PRIVILEGES;
SQL
  ok "dropped sandbox database '$db' (user '$user')"
}

# print the user databases (no system schemas); assumes the stack is already up
_sandbox_list_dbs() {
  _sandbox_mysql -N -e "SHOW DATABASES;" \
    | grep -Ev '^(information_schema|performance_schema|mysql|sys)$' \
    | sed 's/^/  /' || true
}

# harbor db sandbox list
sandbox_list() {
  _sandbox_ensure
  log "sandbox databases:"
  _sandbox_list_dbs
}

# harbor db sandbox backup <db> [file]
sandbox_backup() {
  local db="${1-}"; [ -n "$db" ] || usage_die db-sandbox "harbor db sandbox backup <db> [file]"
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
  [ -n "$db" ] && [ -n "$file" ] && [ -f "$file" ] || usage_die db-sandbox "harbor db sandbox restore <db> <file>"
  _sandbox_ensure; db="$(db_ident "$db")"
  local tmpd; tmpd="$(mktemp -d "${TMPDIR:-/tmp}/harbor-sandbox.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmpd'" EXIT
  local work="$tmpd/dump.sql"
  log "decompressing $file"
  _db_decompress "$file" "$work"
  # strip DEFINER for portability (shared with db_import)
  step "stripping DEFINER clauses"
  strip_definers "$work"
  _sandbox_mysql -e "CREATE DATABASE IF NOT EXISTS \`$db\` CHARACTER SET utf8mb4;"
  log "loading into sandbox '$db' (FK checks off)"
  _fk_wrapped "$work" | _sandbox_mysql "$db"
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
    log "sandbox databases:"; _sandbox_list_dbs   # already confirmed up — no re-ensure
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
    *) usage_die db-sandbox "harbor db sandbox create|drop|list|backup|restore|console|up|down|destroy|status" ;;
  esac
}
