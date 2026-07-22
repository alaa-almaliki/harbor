#!/usr/bin/env bash
# test_search_replace.sh — serialized-safe replace logic (lib/search-replace.php).
# Exercises rr() directly (no DB) via the HARBOR_SR_LIB_ONLY include seam.
set -uo pipefail
. "$HARBOR_TEST_DIR/lib.sh"

SR="$HARBOR_ROOT/lib/search-replace.php"

command -v php >/dev/null 2>&1 || skip_all "php not on PATH"

# rr(<input>) with a single literal rule live.com -> local.test, printed raw.
rr() {
  HARBOR_SR_LIB_ONLY=1 php -r '
    require $argv[1];
    echo rr($argv[2], [["live.com", "local.test", false]]);
  ' "$SR" "$1"
}

# --- plain strings -----------------------------------------------------------
assert_eq "rr: plain literal replace" "go to local.test now" "$(rr 'go to live.com now')"
assert_eq "rr: no match untouched"    "nothing here"         "$(rr 'nothing here')"

# --- serialized string, length changes (8 -> 10 chars) -----------------------
# Build a serialized array, run it through rr, then unserialize the result: it
# only succeeds if rr recomputed the string lengths correctly.
ser="$(php -r 'echo serialize(["url" => "http://live.com/x", "n" => 5]);')"
out="$(rr "$ser")"
got="$(HARBOR_SR_LIB_ONLY=1 php -r '
  require $argv[1];
  $u = unserialize($argv[2]);
  echo ($u === false) ? "UNSERIALIZE_FAILED" : $u["url"] . "|" . $u["n"];
' "$SR" "$out")"
assert_eq "rr: serialized length recomputed + value replaced" \
  "http://local.test/x|5" "$got"

# --- nested serialized structure ---------------------------------------------
nested="$(php -r 'echo serialize(["a" => ["b" => "see live.com here"]]);')"
nout="$(rr "$nested")"
ngot="$(HARBOR_SR_LIB_ONLY=1 php -r '
  require $argv[1];
  $u = unserialize($argv[2]);
  echo ($u === false) ? "FAIL" : $u["a"]["b"];
' "$SR" "$nout")"
assert_eq "rr: recurses into nested serialized" "see local.test here" "$ngot"

# --- regex rules -------------------------------------------------------------
# CLI wraps bare `re:` patterns in ~ delimiters; rr() receives them wrapped.
rrx() {
  HARBOR_SR_LIB_ONLY=1 php -r '
    require $argv[1];
    echo rr($argv[2], [["~UA-\\d+-\\d+~", "", true]]);
  ' "$SR" "$1"
}
assert_eq "rr: regex rule strips tracking id" "ga('create','','auto')" \
  "$(rrx "ga('create','UA-1234567-1','auto')")"

# a failing regex must never null the value — original survives
rbad="$(HARBOR_SR_LIB_ONLY=1 php -d display_errors=0 -r '
  require $argv[1];
  echo rr("keep me", [["~(*FAIL_BOGUS_VERB)~", "x", true]]);
' "$SR" 2>/dev/null)"
assert_eq "rr: failing regex keeps original value" "keep me" "$rbad"

# --- CLI --check: validate rules with no DB ----------------------------------
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
printf 'live.com\tlocal.test\nre:UA-\\d+-\\d+\t\n' > "$tmp/good.tsv"
assert_ok "check: literal + bare regex rules pass" php "$SR" --rules "$tmp/good.tsv" --check

printf 'no-separator-here\n' > "$tmp/nosep.tsv"
assert_fail "check: line without FROM/TO separator fails" php "$SR" --rules "$tmp/nosep.tsv" --check

printf 're:foo(\tx\n' > "$tmp/badre.tsv"
assert_fail "check: invalid regex fails" php "$SR" --rules "$tmp/badre.tsv" --check
assert_contains "check: invalid regex names the rule" "invalid regex 'foo('" \
  "$(php "$SR" --rules "$tmp/badre.tsv" --check 2>&1 || true)"

printf '\tonly-to\n' > "$tmp/emptyfrom.tsv"
assert_fail "check: empty FROM fails" php "$SR" --rules "$tmp/emptyfrom.tsv" --check

: > "$tmp/none.tsv"
assert_ok "check: empty rules file is fine" php "$SR" --rules "$tmp/none.tsv" --check

report
