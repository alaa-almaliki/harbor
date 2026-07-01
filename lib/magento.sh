#!/usr/bin/env bash
# magento.sh — Magento setup:install wiring + local-DX helpers.
# All bin/magento calls run under the project's pinned PHP via cmd_magento.

# generate a transparent, re-runnable setup:install script wired to allocations
magento_write_install() {
  local name="$1" dir ident ver cli script
  dir="$(project_dir "$name")"; ident="$(db_ident "$name")"
  ver="$(_project_php_ver "$name")"; cli="$(php_cli_bin "$ver")"
  _db_load "$name"
  script="$dir/.harbor/install.sh"
  cat > "$script" <<EOF
#!/usr/bin/env bash
# Harbor-generated Magento setup:install (re-runnable). Runs under php $ver.
set -e
cd "$dir"
"$cli" bin/magento setup:install \\
  --base-url=https://$name.$HARBOR_TLD/ --base-url-secure=https://$name.$HARBOR_TLD/ \\
  --use-secure=1 --use-secure-admin=1 \\
  --db-host=127.0.0.1:$DB_PORT --db-name=$ident --db-user=$ident --db-password=$ident \\
  --search-engine=opensearch --opensearch-host=127.0.0.1 --opensearch-port=$OPENSEARCH_PORT \\
  --opensearch-index-prefix=$ident \\
  --amqp-host=127.0.0.1 --amqp-port=$RABBITMQ_PORT --amqp-user=guest --amqp-password=guest --amqp-virtualhost=/ \\
  --cache-backend=redis --cache-backend-redis-server=127.0.0.1 --cache-backend-redis-port=6379 --cache-backend-redis-db=$REDIS_CACHE_DB \\
  --page-cache=redis --page-cache-redis-server=127.0.0.1 --page-cache-redis-port=6379 --page-cache-redis-db=$REDIS_PAGE_DB \\
  --session-save=redis --session-save-redis-host=127.0.0.1 --session-save-redis-port=6379 --session-save-redis-db=$REDIS_SESSION_DB \\
  --admin-firstname=Admin --admin-lastname=User --admin-email=admin@$name.$HARBOR_TLD \\
  --admin-user=$(config_get ADMIN_USER admin) --admin-password=$(config_get ADMIN_PASSWORD Admin123!) \\
  --language=$(config_get LOCALE en_US) --currency=$(config_get CURRENCY USD) --timezone=$(config_get TIMEZONE UTC) \\
  --backend-frontname=admin --cleanup-database
EOF
  chmod +x "$script"
  printf '%s' "$script"
}

# rewrite base URLs + search host after a DB import (--reconfigure)
magento_reconfigure() {
  local name="$1"; _db_load "$name"
  local base="https://$name.$HARBOR_TLD/"
  log "magento reconfigure: base URLs + search host"
  cmd_magento "$name" config:set web/unsecure/base_url "$base" >/dev/null 2>&1 || \
    cmd_magento "$name" setup:store-config:set --base-url="$base" >/dev/null 2>&1 || true
  cmd_magento "$name" config:set web/secure/base_url "$base" >/dev/null 2>&1 || true
  cmd_magento "$name" config:set catalog/search/engine opensearch >/dev/null 2>&1 || true
  cmd_magento "$name" config:set catalog/search/opensearch_server_hostname 127.0.0.1 >/dev/null 2>&1 || true
  cmd_magento "$name" config:set catalog/search/opensearch_server_port "$OPENSEARCH_PORT" >/dev/null 2>&1 || true
  cmd_magento "$name" cache:flush >/dev/null 2>&1 || true
}

# local-DX pack: disable 2FA, developer mode, reindex, cache flush
magento_localize() {
  local name="$1"
  log "magento local-DX: developer mode, disable 2FA, reindex"
  cmd_magento "$name" deploy:mode:set developer >/dev/null 2>&1 || true
  cmd_magento "$name" module:disable Magento_TwoFactorAuth Magento_AdminAdobeImsTwoFactorAuth >/dev/null 2>&1 || true
  cmd_magento "$name" indexer:reindex >/dev/null 2>&1 || true
  cmd_magento "$name" cache:flush >/dev/null 2>&1 || true
}
