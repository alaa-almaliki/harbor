#!/usr/bin/env bash
# test_tools.sh — CLI php ini-flag assembly (lib/tools.sh). Pure logic: builds
# `-d key=value` flags from a manifest's php_ini flow map. No host, no PHP.
set -uo pipefail
. "$HARBOR_TEST_DIR/lib.sh"
harbor_load common manifest tools

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mf="$tmp/harbor.yml"

# --- multiple php_ini keys → one -d flag each, in manifest order --------------
cat > "$mf" <<'YML'
framework: magento
php: "8.3"
php_ini: { memory_limit: 2G, max_execution_time: 0 }
YML
assert_eq "ini flags: memory_limit + max_execution_time" \
  " -d memory_limit=2G -d max_execution_time=0" \
  "$(_cli_php_ini_flags "$mf")"

# --- single key --------------------------------------------------------------
cat > "$mf" <<'YML'
php_ini: { memory_limit: 512M }
YML
assert_eq "ini flags: single key" \
  " -d memory_limit=512M" \
  "$(_cli_php_ini_flags "$mf")"

# --- no php_ini block → empty (Magento OOM's on host default until pinned) ----
cat > "$mf" <<'YML'
framework: laravel
php: "8.3"
YML
assert_eq "ini flags: absent block yields nothing" \
  "" \
  "$(_cli_php_ini_flags "$mf")"

# --- missing manifest file → empty, no error ---------------------------------
assert_eq "ini flags: missing manifest yields nothing" \
  "" \
  "$(_cli_php_ini_flags "$tmp/nope.yml")"

report
