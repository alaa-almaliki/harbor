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
conf="$(php_fpm_conf "$ver")"
[ -x "$bin" ] || { echo "php-fpm $ver not found at $bin" >&2; exit 1; }
[ -f "$conf" ] || { echo "pool config missing: $conf" >&2; exit 1; }

# Same flags the project CLI shim gets (see xdebug_dflags) — one source of truth.
dflags="$(xdebug_dflags "$ver")"

# shellcheck disable=SC2086
exec "$bin" -F --fpm-config "$conf" $dflags
