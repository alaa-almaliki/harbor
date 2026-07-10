#!/usr/bin/env bash
# test_search_replace.sh — serialized-safe replace logic (lib/search-replace.php).
# Exercises rr() directly (no DB) via the HARBOR_SR_LIB_ONLY include seam.
set -uo pipefail
. "$HARBOR_TEST_DIR/lib.sh"

SR="$HARBOR_ROOT/lib/search-replace.php"

if ! command -v php >/dev/null 2>&1; then
  printf '  skip php not on PATH — skipping search-replace tests\n'
  report
  exit 0
fi

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

report
