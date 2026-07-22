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

# --- link_php_source: which version, and WHY ---------------------------------
# One precedence chain feeds two consumers — the vhost that gets rendered
# (link_php) and the answer `harbor describe php` prints. Assert both here so a
# change to one can't silently disagree with the other.
# Globals are overridden AFTER the load, never as an env prefix: common.sh
# assigns them unconditionally at source time (CLAUDE.md §6.5).
HARBOR_PROJECTS="$tmp/projects"
HARBOR_DEFAULT_PHP_FILE="$tmp/default-php"
echo 8.1 > "$HARBOR_DEFAULT_PHP_FILE"

_mkproj() {  # <name> — project dir + empty manifest, echoes the dir
  mkdir -p "$HARBOR_PROJECTS/$1/.harbor"
  printf 'name: %s\n' "$1" > "$HARBOR_PROJECTS/$1/.harbor/harbor.yml"
  printf '%s' "$HARBOR_PROJECTS/$1"
}

# 1. manifest `php:` wins outright.
d="$(_mkproj pinned)"
printf 'name: pinned\nphp: "8.3"\n' > "$d/.harbor/harbor.yml"
echo 7.4 > "$d/.php-version"     # present, and must lose
assert_eq "link_php: manifest php wins" "8.3" "$(link_php pinned "$d")"
assert_contains "link_php_source: names the manifest" "manifest php:" \
  "$(link_php_source pinned "$d")"

# 2. no manifest php -> .php-version.
d="$(_mkproj pvfile)"
echo 7.4 > "$d/.php-version"
assert_eq "link_php: .php-version used" "7.4" "$(link_php pvfile "$d")"
assert_contains "link_php_source: names .php-version" ".php-version" \
  "$(link_php_source pvfile "$d")"

# 3. neither -> the global default.
d="$(_mkproj bare)"
assert_eq "link_php: falls back to default" "8.1" "$(link_php bare "$d")"
assert_contains "link_php_source: names the global default" "global default" \
  "$(link_php_source bare "$d")"

# 4. An EMPTY .php-version is not a pin. It reads as a value ("") where the file's
#    presence reads as a pin — exactly the empty-vs-absent trap of CLAUDE.md §3 —
#    so it must fall through to the default rather than yield an empty version.
d="$(_mkproj emptypv)"
: > "$d/.php-version"
assert_eq "link_php: empty .php-version -> default" "8.1" "$(link_php emptypv "$d")"

# 5. link_php stays a bare version — no `|source` leaking into rendered configs.
assert_eq "link_php: emits no source suffix" "8.3" "$(link_php pinned "$(project_dir pinned)")"

# --- current_php_source: "which php am I on?" --------------------------------
# `harbor php -v` and `harbor describe php` both answer this question and must
# never disagree, so both go through this one helper. (HARBOR_PROJECT is cleared
# per call: cwd_project reads it first, and a stray one from a `harbor shell`
# would silently decide the answer.)
assert_eq "current_php_source: named project -> its pin" "8.3" \
  "$(x="$(HARBOR_PROJECT='' current_php_source pinned)"; printf '%s' "${x%%|*}")"
assert_contains "current_php_source: named project -> its source" "manifest php:" \
  "$(HARBOR_PROJECT='' current_php_source pinned)"

# No name and a cwd outside any project: the global default, NOT an error. This
# is what lets `harbor php -v` work from anywhere.
assert_eq "current_php_source: no project -> global default" "8.1" \
  "$(x="$(HARBOR_PROJECT='' current_php_source "")"; printf '%s' "${x%%|*}")"
assert_contains "current_php_source: no project -> says so" "global default" \
  "$(HARBOR_PROJECT='' current_php_source "")"

# $HARBOR_PROJECT (exported by `harbor shell`) resolves it with no arg at all.
assert_eq "current_php_source: HARBOR_PROJECT wins with no arg" "7.4" \
  "$(x="$(HARBOR_PROJECT=pvfile current_php_source "")"; printf '%s' "${x%%|*}")"

report
