#!/usr/bin/env bash
# test_link.sh — PHP_VALUE block generation (lib/link.sh link_php_value_block).
# Regression suite for the empty-php_ini bug: a project with no `php_ini:` keys
# (the default for a fresh `harbor init` — see currencyapp/deliverymanager) must
# not make the function return nonzero. Today's call site is a prefix assignment
# that swallows the rc; the guard exists so the next plain caller doesn't die
# silently under set -e. See CLAUDE.md §3.
set -uo pipefail
. "$HARBOR_TEST_DIR/lib.sh"
harbor_load common manifest link

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mf_with="$tmp/with.yml"
mf_multi="$tmp/multi.yml"
mf_none="$tmp/none.yml"
printf 'name: demo\nphp_ini: { memory_limit: 2G }\n' > "$mf_with"
printf 'name: demo\nphp_ini: { memory_limit: 4G, max_execution_time: 600 }\n' > "$mf_multi"
printf 'name: demo\n# php_ini: { memory_limit: 2G }\n' > "$mf_none"

value_block_errexit() { ( set -e; link_php_value_block "$1" >/dev/null; echo SURVIVED ) 2>/dev/null; }

# --- a manifest WITH php_ini emits the fastcgi_param line --------------------
assert_ok "with php_ini: returns 0" link_php_value_block "$mf_with"
assert_contains "with php_ini: emits fastcgi_param" \
  'fastcgi_param PHP_VALUE' "$(link_php_value_block "$mf_with")"
assert_contains "with php_ini: carries the key=value" \
  'memory_limit=2G' "$(link_php_value_block "$mf_with")"

# multiple keys are newline-joined inside one PHP_VALUE
assert_contains "multi php_ini: first key present"  'memory_limit=4G' \
  "$(link_php_value_block "$mf_multi")"
assert_contains "multi php_ini: second key present" 'max_execution_time=600' \
  "$(link_php_value_block "$mf_multi")"

# --- no php_ini is inert, not fatal ------------------------------------------
# This is the regression: `[ -n "$out" ] && printf …` as the function's last
# statement made the empty case the return value.
assert_ok "no php_ini: returns 0" link_php_value_block "$mf_none"
assert_eq "no php_ini: emits nothing" "" "$(link_php_value_block "$mf_none")"
assert_contains "no php_ini: under set -e does not kill the caller" \
  SURVIVED "$(value_block_errexit "$mf_none")"

# --- a missing manifest is also non-fatal (pre-existing guard) ---------------
assert_ok "missing manifest: returns 0" link_php_value_block "$tmp/nope.yml"
assert_eq "missing manifest: emits nothing" "" "$(link_php_value_block "$tmp/nope.yml")"

report
