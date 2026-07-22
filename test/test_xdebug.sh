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

# --- php_ext_loaded: no early-exit race ---------------------------------------
# This detection used to be `php -m | grep -q '^xdebug$'`, which is a scheduling
# race under `set -o pipefail`: grep exits at the first match, php writes into a
# closed pipe, dies of SIGPIPE (141), and pipefail returns that 141 as the
# pipeline's status — so a match intermittently read as "not loaded" and
# xdebug_dflags added a SECOND zend_extension on top of brew's. Measured ~3 in
# 400 in the wild, which is exactly the frequency that gets dismissed as a fluke.
#
# So this fake writes the match FIRST and keeps writing after a pause: with the
# pipeline form the late write ALWAYS lands on a closed pipe, making the old bug
# deterministic rather than lucky. A regression here fails every time, not 1%.
slow="$tmp/php-slow"
cat > "$slow" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  -m) echo xdebug; sleep 0.2; echo json ;;
  *)  printf '' ;;
esac
SH
chmod +x "$slow"
assert_ok   "php_ext_loaded: writer that keeps writing after the match" \
  php_ext_loaded "$slow" xdebug
assert_fail "php_ext_loaded: absent extension" php_ext_loaded "$slow" imagick
assert_ok   "php_ext_loaded: case-insensitive"  php_ext_loaded "$slow" XDebug
assert_fail "php_ext_loaded: no such binary"    php_ext_loaded "$tmp/nope" xdebug
# A substring must not count as a match — `xdebug` is not `xdebug_extra`.
assert_fail "php_ext_loaded: substring is not a match" php_ext_loaded "$slow" deb

# --- xdebug_cli_trigger -------------------------------------------------------
# The ONE thing the two surfaces deliberately don't share: the CLI shim exports
# XDEBUG_TRIGGER itself, because out here there's no browser extension to flip
# and "xdebug on" can only mean "debug my commands". Everything else must still
# reach both surfaces (that's what the assertions above pin).
# HARBOR_CONFIG is assigned at top level, never as an env prefix on the load —
# common.sh assigns it unconditionally at source time (CLAUDE.md §6.5).
HARBOR_CONFIG="$tmp/config"
: > "$HARBOR_CONFIG"

echo off > "$HARBOR_XDEBUG_STATE"
assert_fail "cli trigger: xdebug off -> no trigger" xdebug_cli_trigger

echo on > "$HARBOR_XDEBUG_STATE"
assert_ok "cli trigger: xdebug on -> trigger, no config needed" xdebug_cli_trigger

# The escape hatch for anyone who wants the old prefix-it-yourself behavior.
printf 'XDEBUG_CLI_TRIGGER=0\n' > "$HARBOR_CONFIG"
assert_fail "cli trigger: XDEBUG_CLI_TRIGGER=0 opts out" xdebug_cli_trigger

printf 'XDEBUG_CLI_TRIGGER=1\n' > "$HARBOR_CONFIG"
assert_ok "cli trigger: XDEBUG_CLI_TRIGGER=1 opts back in" xdebug_cli_trigger

# `harbor xdebug off` must mean off entirely — the knob can't resurrect it, or
# "off" would stop being a reliable way to make CLI runs fast again.
echo off > "$HARBOR_XDEBUG_STATE"
assert_fail "cli trigger: off beats XDEBUG_CLI_TRIGGER=1" xdebug_cli_trigger

report
