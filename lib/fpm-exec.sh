#!/usr/bin/env bash
# fpm-exec.sh <ver> — launched by the com.harbor.php-<ver> LaunchAgent.
# Execs php-fpm in foreground (-F) with the Harbor pool config, controlling
# Xdebug via xdebug.mode (NOT by loading the extension), so it works whether or
# not the host's brew php config already loads xdebug — and never edits brew config.
set -euo pipefail

if [ -z "${HARBOR_ROOT:-}" ]; then
  _src="${BASH_SOURCE[0]}"
  while [ -h "$_src" ]; do
    _d="$(cd -P "$(dirname "$_src")" >/dev/null 2>&1 && pwd)"; _src="$(readlink "$_src")"
    case "$_src" in /*) ;; *) _src="$_d/$_src" ;; esac
  done
  HARBOR_ROOT="$(cd -P "$(dirname "$_src")/.." >/dev/null 2>&1 && pwd)"
fi
export HARBOR_ROOT
# shellcheck source=common.sh
. "$HARBOR_ROOT/lib/common.sh"

ver="${1:?usage: fpm-exec.sh <php-version>}"
bin="$(php_fpm_bin "$ver")"
cli="$(php_cli_bin "$ver")"
conf="$(php_fpm_conf "$ver")"
[ -x "$bin" ] || { echo "php-fpm $ver not found at $bin" >&2; exit 1; }
[ -f "$conf" ] || { echo "pool config missing: $conf" >&2; exit 1; }

# Is xdebug already loaded by this version's default (brew) config?
default_loaded=0
"$cli" -m 2>/dev/null | grep -qi '^xdebug$' && default_loaded=1

dflags=""
if [ "$(xdebug_state)" = "on" ]; then
  if [ "$default_loaded" -eq 0 ]; then
    if so="$(xdebug_so_for "$ver")"; then dflags="-d zend_extension=$so"; fi
  fi
  dflags="$dflags -d xdebug.mode=debug,develop -d xdebug.start_with_request=trigger -d xdebug.client_host=127.0.0.1 -d xdebug.client_port=9003 -d xdebug.discover_client_host=false"
else
  # off: if the extension is loaded by default config, neutralize it
  [ "$default_loaded" -eq 1 ] && dflags="-d xdebug.mode=off"
fi

# shellcheck disable=SC2086
exec "$bin" -F --fpm-config "$conf" $dflags
