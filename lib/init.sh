#!/usr/bin/env bash
# init.sh — provision a project's Harbor state: manifest, port/redis allocation,
# rendered compose, connection files. Does NOT scaffold app code (that's `new`).

# services line for the manifest, by framework
_init_services() {
  case "$1" in
    magento) echo "mysql, opensearch, rabbitmq" ;;
    *)       echo "mysql" ;;
  esac
}

# render the per-project compose file from the manifest + allocation
init_render_compose() {
  local name="$1" framework="$2" tmpl
  ports_load "$name" || die "ports not allocated for $name"
  case "$framework" in
    magento) tmpl="$HARBOR_TEMPLATES/compose/magento.yml.tmpl" ;;
    *)       tmpl="$HARBOR_TEMPLATES/compose/default.yml.tmpl" ;;
  esac
  local ident; ident="$(db_ident "$name")"
  NAME="$name" \
  DB_IMAGE="$(setting_get "$name" db.image MYSQL_IMAGE mysql:8.0)" \
  DB_NAME="$ident" DB_USER="$ident" DB_PASS="$ident" \
  DB_ROOT_PASS="$(config_get MYSQL_ROOT_PASSWORD root)" \
  DB_PORT="$DB_PORT" \
  MYSQL_POOL="$(config_get MYSQL_BUFFER_POOL 256M)" \
  OS_HEAP="$(config_get OPENSEARCH_HEAP 512m)" \
  OPENSEARCH_PORT="$OPENSEARCH_PORT" \
  RABBITMQ_PORT="$RABBITMQ_PORT" RABBITMQ_UI_PORT="$RABBITMQ_UI_PORT" \
  render "$tmpl" "$(project_harbor_dir "$name")/docker-compose.yml"
}

# Harbor-owned connection files (source of truth for `wire`, Phase 6)
init_write_connection() {
  local name="$1" hdir; hdir="$(project_harbor_dir "$name")"
  ports_load "$name"
  local ident; ident="$(db_ident "$name")"
  local root; root="$(config_get MYSQL_ROOT_PASSWORD root)"
  cat > "$hdir/connection.env" <<EOF
DB_HOST=127.0.0.1
DB_PORT=$DB_PORT
DB_DATABASE=$ident
DB_USERNAME=$ident
DB_PASSWORD=$ident
DB_ROOT_PASSWORD=$root
REDIS_HOST=127.0.0.1
REDIS_PORT=6379
REDIS_DB=$REDIS_DB_CACHE
REDIS_CACHE_DB=$REDIS_DB_CACHE
REDIS_PAGE_DB=$REDIS_DB_PAGE
REDIS_SESSION_DB=$REDIS_DB_SESSION
REDIS_PREFIX=${ident}_
MAIL_HOST=127.0.0.1
MAIL_PORT=1025
OPENSEARCH_HOST=127.0.0.1
OPENSEARCH_PORT=$OPENSEARCH_PORT
RABBITMQ_HOST=127.0.0.1
RABBITMQ_PORT=$RABBITMQ_PORT
EOF
  cat > "$hdir/connection.txt" <<EOF
Harbor connection info for "$name"
  URL        https://$name.$HARBOR_TLD
  MySQL      127.0.0.1:$DB_PORT  db/user/pass: $ident / $ident / $ident  (root: $root)
  Redis      127.0.0.1:6379  db: $REDIS_DB_CACHE (cache) $REDIS_DB_PAGE (page) $REDIS_DB_SESSION (session)  prefix: ${ident}_
  Mailpit    smtp 127.0.0.1:1025   ui http://localhost:8025
  OpenSearch 127.0.0.1:$OPENSEARCH_PORT
  RabbitMQ   amqp 127.0.0.1:$RABBITMQ_PORT   ui http://localhost:$RABBITMQ_UI_PORT
EOF
}

init_write_gitignore() {
  cat > "$(project_harbor_dir "$1")/.gitignore" <<'EOF'
# Harbor runtime (generated) — do not commit
connection.env
compose.env
docker-compose.yml
install.sh
bin/
# committable: harbor.yml, import-rules, hooks/
EOF
}

cmd_init() {
  require_name "${1-}"; local name="$1"; shift || true
  local framework="" phpopt="" msopt="" existing=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --php) phpopt="${2-}"; shift 2 ;;
      --multistore) msopt="${2-}"; shift 2 ;;
      --existing) existing=1; shift ;;
      --*) die "unknown option: $1" ;;
      *) framework="$1"; shift ;;
    esac
  done

  local dir; dir="$(project_dir "$name")"
  mkdir -p "$dir" "$(project_harbor_dir "$name")"
  if [ "$existing" = 1 ]; then
    local f empty=1
    for f in "$dir"/* "$dir"/.[!.]*; do
      [ -e "$f" ] || continue
      case "$f" in */.harbor) ;; *) empty=0; break ;; esac
    done
    [ "$empty" = 1 ] && warn "--existing but $dir has no app code yet"
  fi

  [ -n "$framework" ] || framework="$(link_detect_framework "$dir")"
  local phpver="$phpopt"
  [ -z "$phpver" ] && [ -f "$dir/.php-version" ] && phpver="$(tr -d ' \n\r' < "$dir/.php-version")"
  [ -z "$phpver" ] && phpver="$(default_php)"
  valid_php_version "$phpver" || die "unsupported php '$phpver'"

  ports_allocate "$name" >/dev/null

  # manifest
  local ident; ident="$(db_ident "$name")"
  FRAMEWORK="$framework" PHP_VER="$phpver" \
  SERVICES="$(_init_services "$framework")" \
  DB_NAME="$ident" DB_USER="$ident" DB_PASS="$ident" \
  DB_IMAGE="$(config_get MYSQL_IMAGE mysql:8.0)" \
  render "$HARBOR_TEMPLATES/manifest/harbor.yml.tmpl" "$(manifest_path "$name")"
  [ -n "$msopt" ] && warn "multistore '$msopt' requested — add 'multistore: { mode: $msopt, stores: {} }' to the manifest"

  init_render_compose "$name" "$framework"
  init_write_connection "$name"
  init_write_gitignore "$name"

  ok "init $name ($framework, php $phpver) — db port $(ports_load "$name"; echo "$DB_PORT")"
  step "next: harbor up $name  &&  harbor link $name"
}
