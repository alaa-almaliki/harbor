#!/usr/bin/env bash
# test_xdebug.sh — xdebug_dflags (lib/common.sh). Pure logic: turns the global
# xdebug toggle into `-d` flags for BOTH php-fpm and the project CLI shim.
#
# The host's real PHP is never used: php_cli_bin is overridden to a fake `php`
# that answers `-m` (is xdebug loaded by default config?) and the extension_dir
# probe, so these assertions hold on any machine.
set -uo pipefail
. "$HARBOR_TEST_DIR/lib.sh"
harbor_load common

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# fake php: `-m` lists xdebug only when FAKE_XDEBUG_LOADED=1; the `-r` probe
# (xdebug_so_for) echoes FAKE_EXTDIR.
fake="$tmp/php"
cat > "$fake" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  -m) [ "${FAKE_XDEBUG_LOADED:-0}" = 1 ] && echo xdebug; echo json ;;
  *)  printf '%s' "${FAKE_EXTDIR:-}" ;;
esac
SH
chmod +x "$fake"
php_cli_bin() { printf '%s' "$fake"; }

HARBOR_XDEBUG_STATE="$tmp/xdebug-state"
extdir="$tmp/ext"; mkdir -p "$extdir"

# --- off + no xdebug in default config → no flags at all ----------------------
echo off > "$HARBOR_XDEBUG_STATE"
assert_eq "off, not loaded: no flags" \
  "" \
  "$(FAKE_XDEBUG_LOADED=0 xdebug_dflags 8.3)"

# --- off + brew's php.ini loads xdebug → neutralize it, don't edit brew config -
assert_eq "off, loaded by default config: mode=off" \
  "-d xdebug.mode=off" \
  "$(FAKE_XDEBUG_LOADED=1 xdebug_dflags 8.3)"

# --- on + already loaded → configure it, but never double-load ----------------
echo on > "$HARBOR_XDEBUG_STATE"
out="$(FAKE_XDEBUG_LOADED=1 xdebug_dflags 8.3)"
assert_contains "on, loaded: mode=debug,develop" "-d xdebug.mode=debug,develop" "$out"
assert_contains "on, loaded: trigger-based"      "-d xdebug.start_with_request=trigger" "$out"
assert_eq "on, loaded: no second zend_extension" "" \
  "$(printf '%s' "$out" | grep -o 'zend_extension' || true)"

# --- on + not loaded → add zend_extension from the version's extension_dir ----
: > "$extdir/xdebug.so"
out="$(FAKE_XDEBUG_LOADED=0 FAKE_EXTDIR="$extdir" xdebug_dflags 8.3)"
assert_contains "on, not loaded: loads xdebug.so" "-d zend_extension=$extdir/xdebug.so" "$out"

# --- on: connection settings reach the CLI too, not just FPM ------------------
# client_host is pinned to 127.0.0.1 rather than xdebug's `localhost` default —
# on macOS `localhost` hits ::1 first and an IDE on IPv4 never sees the session.
assert_contains "on: client_host pinned to IPv4" "-d xdebug.client_host=127.0.0.1" "$out"
assert_contains "on: client_port 9003"           "-d xdebug.client_port=9003" "$out"
assert_contains "on: no host discovery"          "-d xdebug.discover_client_host=false" "$out"

# --- on + not loaded + no xdebug.so anywhere → configure, but nothing to load --
rm -f "$extdir/xdebug.so"
out="$(FAKE_XDEBUG_LOADED=0 FAKE_EXTDIR="$extdir" xdebug_dflags 8.3)"
assert_eq "on, no .so: nothing to zend_extension" "" \
  "$(printf '%s' "$out" | grep -o 'zend_extension' || true)"
assert_contains "on, no .so: still sets mode" "-d xdebug.mode=debug,develop" "$out"

# --- unset state file defaults to off ----------------------------------------
rm -f "$HARBOR_XDEBUG_STATE"
assert_eq "no state file: treated as off" \
  "" \
  "$(FAKE_XDEBUG_LOADED=0 xdebug_dflags 8.3)"

report
