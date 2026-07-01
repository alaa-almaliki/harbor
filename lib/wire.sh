#!/usr/bin/env bash
# wire.sh — inject connection info into the app's real config, surgically.
# Allowlist keys only, idempotent, .harbor-bak backup, never blanket-rewrite.
# Source of truth: .harbor/connection.env (loaded by cmd_wire before dispatch).

# replace-or-append KEY=VALUE in a dotenv-style file (idempotent)
_env_set() {
  local file="$1" key="$2" val="$3" tmp="$1.htmp"
  { grep -vE "^[[:space:]]*${key}=" "$file" 2>/dev/null || true; printf '%s=%s\n' "$key" "$val"; } > "$tmp"
  mv "$tmp" "$file"
}
_backup_once() { [ -f "$1" ] && [ ! -f "$1.harbor-bak" ] && cp "$1" "$1.harbor-bak" || true; }

wire_laravel() {
  local dir="$1" f="$1/.env"
  [ -f "$f" ] || { [ -f "$dir/.env.example" ] && cp "$dir/.env.example" "$f" || : > "$f"; }
  _backup_once "$f"
  _env_set "$f" DB_CONNECTION mysql
  _env_set "$f" DB_HOST "$DB_HOST"
  _env_set "$f" DB_PORT "$DB_PORT"
  _env_set "$f" DB_DATABASE "$DB_DATABASE"
  _env_set "$f" DB_USERNAME "$DB_USERNAME"
  _env_set "$f" DB_PASSWORD "$DB_PASSWORD"
  _env_set "$f" REDIS_HOST "$REDIS_HOST"
  _env_set "$f" REDIS_PORT "$REDIS_PORT"
  _env_set "$f" REDIS_DB "$REDIS_CACHE_DB"
  _env_set "$f" MAIL_MAILER smtp
  _env_set "$f" MAIL_HOST "$MAIL_HOST"
  _env_set "$f" MAIL_PORT "$MAIL_PORT"
  ok "wired $f  (backup: .env.harbor-bak)"
}

wire_ci4() {
  local dir="$1" f="$1/.env"
  [ -f "$f" ] || { [ -f "$dir/env" ] && cp "$dir/env" "$f" || : > "$f"; }
  _backup_once "$f"
  _env_set "$f" database.default.hostname "$DB_HOST"
  _env_set "$f" database.default.port "$DB_PORT"
  _env_set "$f" database.default.database "$DB_DATABASE"
  _env_set "$f" database.default.username "$DB_USERNAME"
  _env_set "$f" database.default.password "$DB_PASSWORD"
  ok "wired $f  (backup: .env.harbor-bak)"
}

wire_symfony() {
  local f="$1/.env.local"
  [ -f "$f" ] || : > "$f"
  _backup_once "$f"
  _env_set "$f" DATABASE_URL "\"mysql://$DB_USERNAME:$DB_PASSWORD@$DB_HOST:$DB_PORT/$DB_DATABASE?serverVersion=8.0\""
  _env_set "$f" REDIS_URL "\"redis://$REDIS_HOST:$REDIS_PORT/$REDIS_CACHE_DB\""
  _env_set "$f" MAILER_DSN "\"smtp://$MAIL_HOST:$MAIL_PORT\""
  ok "wired $f (committed .env untouched)"
}

wire_plain() {
  local out="$1/.harbor/connection.php"
  cat > "$out" <<PHP
<?php
// Harbor connection info (generated). require() this or copy the values.
return [
  'db'    => ['host'=>'$DB_HOST','port'=>$DB_PORT,'database'=>'$DB_DATABASE','username'=>'$DB_USERNAME','password'=>'$DB_PASSWORD'],
  'redis' => ['host'=>'$REDIS_HOST','port'=>$REDIS_PORT,'db'=>$REDIS_CACHE_DB,'prefix'=>'$REDIS_PREFIX'],
  'mail'  => ['host'=>'$MAIL_HOST','port'=>$MAIL_PORT],
];
PHP
  ok "wrote $out (require it, or copy values from .harbor/connection.txt)"
}

cmd_wire() {
  require_name "${1-}"; local name="$1"; shift || true
  local print=0; [ "${1-}" = "--print" ] && print=1
  local dir hdir conn mf framework
  dir="$(project_dir "$name")"; hdir="$(project_harbor_dir "$name")"; conn="$hdir/connection.env"
  [ -f "$conn" ] || die "no connection info — run: harbor init $name"
  if [ "$print" = 1 ]; then cat "$hdir/connection.txt"; return 0; fi
  set -a; # shellcheck disable=SC1090
  . "$conn"; set +a
  mf="$(manifest_path "$name")"
  framework="$(manifest_get "$mf" framework "")"; [ -n "$framework" ] || framework="$(link_detect_framework "$dir")"
  case "$framework" in
    laravel) wire_laravel "$dir" ;;
    codeigniter) if [ -f "$dir/spark" ]; then wire_ci4 "$dir"; else wire_plain "$dir"; fi ;;
    symfony) wire_symfony "$dir" ;;
    magento) warn "Magento config is applied by 'harbor install' (setup:install) — not by wire."; cat "$hdir/connection.txt" ;;
    *) wire_plain "$dir" ;;
  esac
}
