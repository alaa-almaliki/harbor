#!/usr/bin/env bash
# common.sh — shared paths, logging, templating, helpers. Sourced by bin/harbor.
#
# Portability: target macOS /bin/bash 3.2 — NO associative arrays, NO `flock`.
# Locking is mkdir-based (atomic). State is KEY=VALUE files (no jq/yq).

# --- Paths -------------------------------------------------------------------
: "${HARBOR_ROOT:?HARBOR_ROOT must be set by bin/harbor}"

HARBOR_LIB="$HARBOR_ROOT/lib"
HARBOR_TEMPLATES="$HARBOR_ROOT/templates"
HARBOR_ETC="$HARBOR_ROOT/etc"                 # rendered, Harbor-owned config
HARBOR_CERTS="$HARBOR_ROOT/certs"
HARBOR_PROJECTS="$HARBOR_ROOT/projects"
HARBOR_DOCKER="$HARBOR_ROOT/docker"
HARBOR_BACKUPS="$HARBOR_ROOT/backups/db"
HARBOR_VAR="$HARBOR_ROOT/var"
HARBOR_RUN="$HARBOR_VAR/run"                  # sockets + pids
HARBOR_LOG_DIR="$HARBOR_VAR/log"
HARBOR_PORTS_DIR="$HARBOR_VAR/ports"
HARBOR_LOCK_DIR="$HARBOR_VAR/lock"

# Runtime state
HARBOR_DEFAULT_PHP_FILE="$HARBOR_VAR/default-php"
HARBOR_XDEBUG_STATE="$HARBOR_VAR/xdebug"
HARBOR_CERT_SANS="$HARBOR_VAR/cert-sans"
HARBOR_STOPPED="$HARBOR_VAR/stopped"    # present when paused via `harbor stop`

# nginx (Harbor-owned)
HARBOR_NGINX_CONF="$HARBOR_ETC/nginx/nginx.conf"
HARBOR_NGINX_SITES="$HARBOR_ETC/nginx/sites"

# dnsmasq (Harbor-owned, own instance)
HARBOR_DNSMASQ_CONF="$HARBOR_ETC/dnsmasq/harbor.conf"
# NOT 5353 — that's the reserved mDNS/Bonjour port. Overridable via config DNS_PORT
# (applied at use-time in Phase 2, since config_get is defined below).
HARBOR_DNS_PORT=5354

# TLS
HARBOR_TLD="test"
HARBOR_CERT="$HARBOR_CERTS/_wildcard.${HARBOR_TLD}.pem"
HARBOR_CERT_KEY="$HARBOR_CERTS/_wildcard.${HARBOR_TLD}-key.pem"
HARBOR_CA_BUNDLE="$HARBOR_CERTS/harbor-ca-bundle.pem"

# Global user config
HARBOR_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/harbor/config"

# Homebrew (binaries only — never its config dirs)
BREW_PREFIX="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"

# Supported PHP versions (need a matching php@<ver> formula; EOL ones via
# the shivammathur/php tap). A version only gets a pool once its php-fpm exists.
HARBOR_PHP_VERSIONS="7.2 7.3 7.4 8.0 8.1 8.2 8.3 8.4 8.5"
HARBOR_DEFAULT_PHP="8.4"

# Port allocation: base = HARBOR_PORT_BASE + index*HARBOR_PORT_BLOCK
HARBOR_PORT_BASE=20000
HARBOR_PORT_BLOCK=20

HARBOR_USER="$(id -un)"
HARBOR_GROUP="staff"

# launchd labels / paths
HARBOR_LD_PREFIX="com.harbor"
HARBOR_LAUNCHAGENTS="$HOME/Library/LaunchAgents"
HARBOR_LAUNCHDAEMONS="/Library/LaunchDaemons"

# --- Logging -----------------------------------------------------------------
if [ -t 1 ]; then
  _c_reset=$'\033[0m'; _c_red=$'\033[31m'; _c_grn=$'\033[32m'
  _c_ylw=$'\033[33m'; _c_blu=$'\033[34m'; _c_dim=$'\033[2m'
else
  _c_reset=''; _c_red=''; _c_grn=''; _c_ylw=''; _c_blu=''; _c_dim=''
fi

log()  { printf '%s==>%s %s\n' "$_c_blu" "$_c_reset" "$*"; }
ok()   { printf '%s ok %s %s\n' "$_c_grn" "$_c_reset" "$*"; }
warn() { printf '%swarn%s %s\n' "$_c_ylw" "$_c_reset" "$*" >&2; }
err()  { printf '%serr %s %s\n' "$_c_red" "$_c_reset" "$*" >&2; }
die()  { err "$*"; exit 1; }
step() { printf '%s  - %s%s\n' "$_c_dim" "$*" "$_c_reset"; }

confirm() {
  local prompt="${1:-Proceed?}" reply
  if [ "${HARBOR_YES:-0}" = "1" ]; then return 0; fi
  read -r -p "$prompt [y/N] " reply
  case "$reply" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

# --- Validation --------------------------------------------------------------
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

valid_php_version() {
  local v="$1" x
  for x in $HARBOR_PHP_VERSIONS; do [ "$x" = "$v" ] && return 0; done
  return 1
}

valid_name() { printf '%s' "$1" | grep -Eq '^[a-z0-9][a-z0-9-]*$'; }

require_name() {
  local name="${1:-}"
  [ -n "$name" ] || die "project name required"
  valid_name "$name" || die "invalid project name '$name' (lowercase letters, digits, hyphens)"
}

project_dir()        { printf '%s' "$HARBOR_PROJECTS/$1"; }
project_harbor_dir() { printf '%s' "$HARBOR_PROJECTS/$1/.harbor"; }

# PATH prefix for running a project's code: <phpdir> <dir> -> project PHP, then
# committable .harbor/scripts, then generated tool shims, then the host PATH.
# One source of truth for the "scripts beat shims beat host" precedence.
project_run_path() { printf '%s:%s/.harbor/scripts:%s/.harbor/bin:%s' "$1" "$2" "$2" "$PATH"; }

# Sanitize + validate a MySQL identifier (db/user name): hyphens -> underscores,
# then reject anything outside [A-Za-z0-9_] so it can't break/inject backtick SQL.
db_ident() {
  local s; s="$(printf '%s' "$1" | tr '-' '_')"
  case "$s" in
    ""|*[!A-Za-z0-9_]*) die "invalid identifier '$1' (allowed: letters, digits, '_', '-')" ;;
  esac
  printf '%s' "$s"
}

# --- Locking (mkdir-based; bash 3.2 / macOS safe) ----------------------------
# harbor_with_lock <name> <cmd...>  — serialize against concurrent invocations.
harbor_with_lock() {
  local name="$1"; shift
  local lock="$HARBOR_LOCK_DIR/$name.lock" tries=0
  mkdir -p "$HARBOR_LOCK_DIR"
  until mkdir "$lock" 2>/dev/null; do
    tries=$((tries + 1))
    [ "$tries" -gt 300 ] && die "could not acquire lock '$name' (held by another harbor process?)"
    sleep 0.1
  done
  local rc=0
  "$@" || rc=$?
  rmdir "$lock" 2>/dev/null || true
  return "$rc"
}

# --- Templating --------------------------------------------------------------
# render <template> <out> ; substitutes {{KEY}} with the value of env var KEY.
render() {
  local tpl="$1" out="$2" content key val
  [ -f "$tpl" ] || die "template not found: $tpl"
  mkdir -p "$(dirname "$out")"
  content="$(cat "$tpl")"
  while [[ "$content" =~ \{\{([A-Z_][A-Z0-9_]*)\}\} ]]; do
    key="${BASH_REMATCH[1]}"
    eval "val=\${$key-}"
    content="${content//\{\{$key\}\}/$val}"
  done
  printf '%s\n' "$content" > "$out"
}

# --- PHP version helpers -----------------------------------------------------
php_opt_dir()  { printf '%s' "$BREW_PREFIX/opt/php@$1"; }
php_fpm_bin()  { printf '%s' "$BREW_PREFIX/opt/php@$1/sbin/php-fpm"; }
php_cli_bin()  { printf '%s' "$BREW_PREFIX/opt/php@$1/bin/php"; }
php_sock()     { printf '%s' "$HARBOR_RUN/php-$1.sock"; }
php_pid()      { printf '%s' "$HARBOR_RUN/php-$1.pid"; }
php_fpm_conf() { printf '%s' "$HARBOR_ETC/php/$1/fpm.conf"; }
php_ld_label() { printf '%s' "$HARBOR_LD_PREFIX.php-$1"; }

installed_php_versions() {
  local v
  for v in $HARBOR_PHP_VERSIONS; do
    [ -x "$(php_fpm_bin "$v")" ] && echo "$v"
  done
}

default_php() {
  if [ -s "$HARBOR_DEFAULT_PHP_FILE" ]; then cat "$HARBOR_DEFAULT_PHP_FILE"; else echo "$HARBOR_DEFAULT_PHP"; fi
}

xdebug_state() {
  if [ -s "$HARBOR_XDEBUG_STATE" ]; then cat "$HARBOR_XDEBUG_STATE"; else echo "off"; fi
}

# Resolve xdebug.so for a PHP version via its extension_dir.
xdebug_so_for() {
  local ver="$1" bin extdir
  bin="$(php_cli_bin "$ver")"
  [ -x "$bin" ] || return 1
  extdir="$("$bin" -d display_errors=0 -r 'echo ini_get("extension_dir");' 2>/dev/null)"
  [ -n "$extdir" ] && [ -f "$extdir/xdebug.so" ] && { printf '%s' "$extdir/xdebug.so"; return 0; }
  return 1
}

# --- Global config (KEY=VALUE) ----------------------------------------------
# config_get <KEY> [default]
config_get() {
  local key="$1" def="${2-}" val=""
  if [ -f "$HARBOR_CONFIG" ]; then
    val="$(grep -E "^${key}=" "$HARBOR_CONFIG" 2>/dev/null | tail -1 | cut -d= -f2-)"
  fi
  if [ -n "$val" ]; then printf '%s' "$val"; else printf '%s' "$def"; fi
}

ensure_dirs() {
  mkdir -p "$HARBOR_RUN" "$HARBOR_LOG_DIR" "$HARBOR_PORTS_DIR" "$HARBOR_LOCK_DIR" \
           "$HARBOR_CERTS" "$HARBOR_NGINX_SITES" "$HARBOR_ETC/php" "$HARBOR_ETC/dnsmasq"
}
