#!/usr/bin/env bash
# test_common.sh — validation, templating, config, path helpers (lib/common.sh).
set -uo pipefail
. "$HARBOR_TEST_DIR/lib.sh"
harbor_load common

# --- valid_name --------------------------------------------------------------
assert_ok   "valid_name: lowercase"        valid_name abc
assert_ok   "valid_name: digits + hyphen"  valid_name my-app-2
assert_ok   "valid_name: leading digit"    valid_name 9front
assert_fail "valid_name: uppercase"        valid_name Abc
assert_fail "valid_name: leading hyphen"   valid_name -abc
assert_fail "valid_name: underscore"       valid_name a_b
assert_fail "valid_name: empty"            valid_name ""
assert_fail "valid_name: dot"              valid_name a.b

# --- require_name ------------------------------------------------------------
assert_ok   "require_name: accepts valid"  require_name good
assert_fail "require_name: empty dies"     require_name ""
assert_fail "require_name: invalid dies"   require_name "Bad Name"

# --- db_ident ----------------------------------------------------------------
assert_eq   "db_ident: hyphen -> underscore" "my_db"   "$(db_ident my-db)"
assert_eq   "db_ident: passthrough"          "shop"    "$(db_ident shop)"
assert_eq   "db_ident: multiple hyphens"     "a_b_c"   "$(db_ident a-b-c)"
assert_fail "db_ident: rejects space"        db_ident "a b"
assert_fail "db_ident: rejects empty"        db_ident ""
assert_fail "db_ident: rejects injection"    db_ident 'x;DROP'

# --- valid_php_version -------------------------------------------------------
assert_ok   "valid_php_version: 8.3"       valid_php_version 8.3
assert_ok   "valid_php_version: 7.2"       valid_php_version 7.2
assert_fail "valid_php_version: 5.6"       valid_php_version 5.6
assert_fail "valid_php_version: garbage"   valid_php_version nope

# --- path helpers ------------------------------------------------------------
assert_eq "project_dir"        "$HARBOR_PROJECTS/foo"          "$(project_dir foo)"
assert_eq "project_harbor_dir" "$HARBOR_PROJECTS/foo/.harbor"  "$(project_harbor_dir foo)"
assert_eq "project_run_path" \
  "/php:/code/.harbor/scripts:/code/.harbor/bin:$PATH" \
  "$(project_run_path /php /code)"

# --- render_str (templating) -------------------------------------------------
tmpl="$(mktemp)"
trap 'rm -f "$tmpl"' EXIT
printf 'server {{FOO}} and {{BAR}} done\n' > "$tmpl"
assert_eq "render_str: substitutes keys" \
  "server hello and world done" \
  "$(FOO=hello BAR=world render_str "$tmpl")"

printf 'edge [{{MISSING}}]\n' > "$tmpl"
assert_eq "render_str: unset key -> empty" "edge []" "$(render_str "$tmpl")"

printf '{{A}}{{A}}{{B}}\n' > "$tmpl"
assert_eq "render_str: repeated + multiple keys" "xxy" "$(A=x B=y render_str "$tmpl")"

assert_fail "render_str: missing template dies" render_str /no/such/template

# --- config_get --------------------------------------------------------------
cfg="$(mktemp)"
printf 'PORT=3306\nPORT=3307\nNAME=harbor\nEMPTY=\n' > "$cfg"
assert_eq "config_get: last value wins" "3307"   "$(HARBOR_CONFIG="$cfg" config_get PORT)"
assert_eq "config_get: simple key"      "harbor" "$(HARBOR_CONFIG="$cfg" config_get NAME)"
assert_eq "config_get: missing default" "fallbk" "$(HARBOR_CONFIG="$cfg" config_get MISSING fallbk)"
assert_eq "config_get: empty -> default" "def"   "$(HARBOR_CONFIG="$cfg" config_get EMPTY def)"
rm -f "$cfg"

# --- resolve_project ---------------------------------------------------------
# (env vars set inside a subshell — resolve_project is a function, so `env`
# can't run it and command-prefix assignment wouldn't survive to the checks.)
proj="$(mktemp -d)"
mkdir -p "$proj/app"

# Explicit valid name whose dir exists -> selected, shift requested.
if ( HARBOR_PROJECTS="$proj"; unset HARBOR_PROJECT
     resolve_project app >/dev/null 2>&1
     [ "$_RP_NAME" = "app" ] && [ "$_RP_SHIFT" = "1" ] ); then
  pass "resolve_project: explicit name -> selected + shift"
else
  fail "resolve_project: explicit name -> selected + shift" "app/1" "mismatch"
fi

# An arg that is NOT a project must leave _RP_SHIFT=0 so the caller keeps it as
# its own first positional. Every optional-<name> command depends on this: it is
# what makes `harbor db backup <db>` inside a project dump <db> rather than
# swallowing it as the project name (and shifting every later arg out of place).
if ( HARBOR_PROJECTS="$proj"; HARBOR_PROJECT=app
     resolve_project somedb >/dev/null 2>&1
     [ "$_RP_NAME" = "app" ] && [ "$_RP_SHIFT" = "0" ] ); then
  pass "resolve_project: non-project arg -> inferred name, no shift"
else
  fail "resolve_project: non-project arg -> inferred name, no shift" "app/0" "mismatch"
fi

# No arg at all, inside a project -> inferred from the cwd.
if ( HARBOR_PROJECTS="$proj"; unset HARBOR_PROJECT; cd "$proj/app"
     resolve_project "" >/dev/null 2>&1
     [ "$_RP_NAME" = "app" ] && [ "$_RP_SHIFT" = "0" ] ); then
  pass "resolve_project: no arg inside a project -> cwd project"
else
  fail "resolve_project: no arg inside a project -> cwd project" "app/0" "mismatch"
fi

# A cwd deeper than the project root still resolves (docroot, module dir, …).
mkdir -p "$proj/app/pub/media"
if ( HARBOR_PROJECTS="$proj"; unset HARBOR_PROJECT; cd "$proj/app/pub/media"
     resolve_project "" >/dev/null 2>&1
     [ "$_RP_NAME" = "app" ] ); then
  pass "resolve_project: subdirectory of a project -> cwd project"
else
  fail "resolve_project: subdirectory of a project -> cwd project" "app" "mismatch"
fi

# An explicit project beats the one we're standing in.
mkdir -p "$proj/other"
if ( HARBOR_PROJECTS="$proj"; HARBOR_PROJECT=app
     resolve_project other >/dev/null 2>&1
     [ "$_RP_NAME" = "other" ] && [ "$_RP_SHIFT" = "1" ] ); then
  pass "resolve_project: explicit name beats the current project"
else
  fail "resolve_project: explicit name beats the current project" "other/1" "mismatch"
fi

# Unknown name and cwd not under any project -> die (nonzero).
if ( HARBOR_PROJECTS="$proj/none"; unset HARBOR_PROJECT; cd /
     resolve_project ghost >/dev/null 2>&1 ); then
  fail "resolve_project: nothing resolves -> dies" "exit nonzero" "exit 0"
else
  pass "resolve_project: nothing resolves -> dies"
fi
rm -rf "$proj"

# --- human_size / human_duration ---------------------------------------------
assert_eq "human_size: bytes"         "731B"  "$(human_size 731)"
assert_eq "human_size: exact K"       "1K"    "$(human_size 1024)"
assert_eq "human_size: megabytes"     "4.2M"  "$(human_size 4404019)"
assert_eq "human_size: gigabytes"     "4.5G"  "$(human_size 4840094635)"
assert_eq "human_size: zero"          "0B"    "$(human_size 0)"

assert_eq "human_duration: seconds"   "42s"       "$(human_duration 42)"
assert_eq "human_duration: minutes"   "5m 12s"    "$(human_duration 312)"
assert_eq "human_duration: hours"     "1h 2m 3s"  "$(human_duration 3723)"
assert_eq "human_duration: zero"      "0s"        "$(human_duration 0)"

# --- installed_php_versions --------------------------------------------------
# Regression: the loop body used to end with `[ -x … ] && echo "$v"`, so when the
# LAST listed version wasn't installed the loop's false guard became the
# function's return value and plain callers (setup/start/stop all iterate this)
# died silently under set -e. See CLAUDE.md §3.
php_bin_dir="$(mktemp -d)"
trap 'rm -rf "$php_bin_dir"' EXIT
php_fpm_bin() { printf '%s' "$php_bin_dir/php-fpm-$1"; }   # stub: no brew lookup
for _v in 8.1 8.3; do : > "$php_bin_dir/php-fpm-$_v"; chmod +x "$php_bin_dir/php-fpm-$_v"; done

HARBOR_PHP_VERSIONS="8.1 8.2 8.3"   # last one IS installed
assert_eq "installed_php_versions: filters to installed" \
  "8.1 8.3" "$(installed_php_versions | tr '\n' ' ' | sed 's/ $//')"
assert_ok "installed_php_versions: rc 0 when last is installed" installed_php_versions

HARBOR_PHP_VERSIONS="8.1 8.3 8.5"   # last one is NOT installed — the regression
assert_eq "installed_php_versions: still filters with last missing" \
  "8.1 8.3" "$(installed_php_versions | tr '\n' ' ' | sed 's/ $//')"
assert_ok "installed_php_versions: rc 0 when last is missing" installed_php_versions
assert_contains "installed_php_versions: last-missing does not kill set -e caller" \
  SURVIVED "$( ( set -e; installed_php_versions >/dev/null; echo SURVIVED ) 2>/dev/null )"

HARBOR_PHP_VERSIONS="7.2 7.4"       # none installed at all
assert_eq "installed_php_versions: none installed prints nothing" "" "$(installed_php_versions)"
assert_ok "installed_php_versions: rc 0 when none installed" installed_php_versions

report
