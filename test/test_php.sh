#!/usr/bin/env bash
# test_php.sh — pure logic behind `harbor php switch` (lib/php.sh). No host: no
# brew, no launchd, no nginx, no pools. Only the two functions that decide
# things — version ordering and the write/undo pair — are exercised here.
set -uo pipefail
. "$HARBOR_TEST_DIR/lib.sh"
harbor_load common manifest php

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- _php_ver_lt: numeric per component --------------------------------------
# A string compare gets this wrong the moment a minor reaches two digits, and
# the answer is what labels a move "upgrade" vs "downgrade" for the user.
assert_ok   "7.4 < 8.3" _php_ver_lt 7.4 8.3
assert_fail "8.3 < 7.4 is false" _php_ver_lt 8.3 7.4
assert_fail "equal is not less-than" _php_ver_lt 8.3 8.3
assert_ok   "8.1 < 8.3 (same major)" _php_ver_lt 8.1 8.3
assert_fail "8.3 < 8.1 is false (same major)" _php_ver_lt 8.3 8.1
assert_ok   "7.9 < 8.0 (major wins over minor)" _php_ver_lt 7.9 8.0
# The one a string compare fails: "8.10" < "8.9" lexically, but 8.10 is NEWER.
assert_fail "8.10 < 8.9 is false (not a string compare)" _php_ver_lt 8.10 8.9
assert_ok   "8.9 < 8.10" _php_ver_lt 8.9 8.10

# --- which moves are gated ----------------------------------------------------
# The gate keys off _php_ver_lt, so lock the mapping here: only a downgrade
# prompts. An upgrade that started asking would be a regression nobody notices
# until it blocks a script.
_gated() {  # <from> <to> — would `switch` confirm for this move?
  if [ "$1" = "$2" ]; then return 1; fi        # converged: never reached
  _php_ver_lt "$2" "$1"
}
assert_ok   "gated: 8.3 -> 7.4 (downgrade)" _gated 8.3 7.4
assert_ok   "gated: 8.3 -> 8.1 (downgrade, same major)" _gated 8.3 8.1
assert_fail "not gated: 7.4 -> 8.3 (upgrade)" _gated 7.4 8.3
assert_fail "not gated: 8.1 -> 8.3 (upgrade, same major)" _gated 8.1 8.3
assert_fail "not gated: 8.3 -> 8.3 (no move)" _gated 8.3 8.3
assert_fail "not gated: 8.9 -> 8.10 (upgrade, two-digit minor)" _gated 8.9 8.10

# --- confirm(): HARBOR_YES=1 is the ONLY bypass -------------------------------
# There is no --yes flag on this command; automation goes through the env var.
assert_ok "HARBOR_YES=1 bypasses the downgrade prompt" \
  env HARBOR_YES=1 bash -c ". '$HARBOR_ROOT/lib/common.sh'; confirm 'x'"

# --- _php_switch_restore: put the manifest back exactly as it was -------------
mf="$tmp/harbor.yml"

# A key that EXISTED is restored verbatim — trailing comment included. Restoring
# a reconstructed "php: 8.1" would silently eat the comment.
printf 'name: shop\nphp: "8.1"  # pinned by ops\nframework: magento\n' > "$mf"
raw="$(manifest_raw_line "$mf" php)"
manifest_set_line "$mf" php '"8.3"'
assert_eq "write took" "8.3" "$(manifest_get "$mf" php "")"
_php_switch_restore "$mf" "$raw" 1 "$tmp/nonexistent-pv" ""
assert_eq "restored value" "8.1" "$(manifest_get "$mf" php "")"
assert_contains "restored the trailing comment too" "# pinned by ops" "$(cat "$mf")"
assert_contains "other keys untouched" "framework: magento" "$(cat "$mf")"

# A key that was ABSENT is restored by DELETION, not by a bare `php:` line —
# present-but-empty is a different manifest than absent (CLAUDE.md §3).
printf 'name: shop\nframework: magento\n' > "$mf"
raw="$(manifest_raw_line "$mf" php)"
manifest_set_line "$mf" php '"8.3"'
assert_eq "write took (key was absent)" "8.3" "$(manifest_get "$mf" php "")"
_php_switch_restore "$mf" "$raw" 0 "$tmp/nonexistent-pv" ""
assert_fail "restored to ABSENT, not a bare 'php:'" manifest_key_present "$mf" php
assert_eq "and nothing else changed" "name: shop
framework: magento" "$(cat "$mf")"

# --- _php_switch_restore: .php-version ---------------------------------------
# Restored only when the project HAD one. pvold empty means there was no file,
# and the restore must not conjure one — Harbor doesn't invent files.
pv="$tmp/.php-version"
printf '8.1\n' > "$pv"
printf '8.3\n' > "$pv"                       # stand in for the switch's write
_php_switch_restore "$mf" "" 0 "$pv" "8.1"
assert_eq ".php-version restored" "8.1" "$(cat "$pv")"

rm -f "$pv"
printf '8.3\n' > "$pv"                       # a switch would NOT have written this
_php_switch_restore "$mf" "" 0 "$pv" ""
assert_eq "no .php-version snapshot -> file left alone" "8.3" "$(cat "$pv")"

rm -f "$pv"
_php_switch_restore "$mf" "" 0 "$pv" ""
assert_fail "absent .php-version is never created by a restore" test -f "$pv"

report
