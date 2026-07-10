#!/usr/bin/env bash
# test/lib.sh — tiny pure-bash assertion harness for Harbor's unit tests.
#
# Zero dependencies, runs on macOS system bash 3.2 (like Harbor itself). Each
# test_*.sh sources this, loads the lib(s) under test with `harbor_load`, calls
# assert_* helpers, and ends with `report`. The runner (run.sh) executes each
# file in its own process and sums the `__TALLY__` line each report emits.
#
# Assertions never abort the file: value checks run in command-substitution
# subshells, and assert_ok/assert_fail wrap the command in a subshell so a
# `die`/`exit` inside a Harbor function can't kill the whole test process.

: "${HARBOR_ROOT:?HARBOR_ROOT must be set by run.sh}"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() {
  FAIL=$((FAIL + 1))
  printf '  FAIL %s\n' "$1"
  printf '         expected: %s\n' "$2"
  printf '         actual:   %s\n' "$3"
}

# assert_eq <desc> <expected> <actual>
assert_eq() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "$2" "$3"; fi
}

# assert_ok <desc> <cmd...>   — command must exit 0 (run in a subshell)
assert_ok() {
  local desc="$1"; shift
  if ( "$@" ) >/dev/null 2>&1; then pass "$desc"; else fail "$desc" "exit 0" "exit nonzero"; fi
}

# assert_fail <desc> <cmd...> — command must exit nonzero (run in a subshell)
assert_fail() {
  local desc="$1"; shift
  if ( "$@" ) >/dev/null 2>&1; then fail "$desc" "exit nonzero" "exit 0"; else pass "$desc"; fi
}

# assert_contains <desc> <needle> <haystack>
assert_contains() {
  case "$3" in
    *"$2"*) pass "$1" ;;
    *) fail "$1" "contains: $2" "$3" ;;
  esac
}

# Source one or more lib/*.sh units under test (order matters: load common first).
harbor_load() {
  local m
  for m in "$@"; do
    # shellcheck disable=SC1090
    . "$HARBOR_ROOT/lib/$m.sh"
  done
}

# Emit the machine-readable tally the runner sums. Call once at end of file.
report() { printf '__TALLY__ %d %d\n' "$PASS" "$FAIL"; }
