#!/usr/bin/env bash
# test_db.sh — hook-runner semantics (lib/db.sh _run_hooks). Regression suite
# for the silent-import-death bug: a non-executable file (e.g. a seeded
# *.sample) must never make _run_hooks return nonzero, or `set -e` kills the
# whole import pipeline with no error output. No Docker: _db_mysql is stubbed.
set -uo pipefail
. "$HARBOR_TEST_DIR/lib.sh"
harbor_load common db

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export HARBOR_PROJECTS="$tmp/projects"
HARBOR_ETC="$tmp/etc"   # keep the global hooks dir out of the real repo

hooks="$HARBOR_PROJECTS/demo/.harbor/hooks"
mkdir -p "$hooks/pre-import.d" "$hooks/post-import.d"

# stub the mysql runner: record what was piped in, never touch Docker
SQL_LOG="$tmp/sql.log"
_db_mysql() { cat >> "$SQL_LOG"; }
HARBOR_IMPORT_DB=demo

# run _run_hooks the way db_import does — a plain call under set -e — so a
# poisoned return value is caught as the silent death it causes in production.
run_hooks_errexit() { ( set -e; _run_hooks "$1" demo; echo SURVIVED ) 2>/dev/null; }

# --- non-executable *.sample files are inert, not fatal ----------------------
touch "$hooks/pre-import.d/10-trim-dump.sh.sample"
touch "$hooks/post-import.d/10-local-overrides.sql.sample"
assert_ok "pre-import: seeded .sample alone returns 0" _run_hooks pre-import demo
assert_ok "post-import: seeded .sql.sample alone returns 0" _run_hooks post-import demo
assert_contains "pre-import: .sample under set -e does not kill the pipeline" \
  "SURVIVED" "$(run_hooks_errexit pre-import)"
assert_fail "post-import: .sql.sample is not piped into mysql" test -s "$SQL_LOG"

# --- executable hooks run; *.sql is piped into the DB ------------------------
printf '#!/bin/sh\necho ran > "%s/hook.ran"\n' "$tmp" > "$hooks/pre-import.d/20-real.sh"
chmod +x "$hooks/pre-import.d/20-real.sh"
printf 'UPDATE t SET v = 1;\n' > "$hooks/post-import.d/20-real.sql"
_run_hooks pre-import demo >/dev/null
assert_ok "pre-import: executable hook ran" test -f "$tmp/hook.ran"
_run_hooks post-import demo >/dev/null
assert_contains "post-import: *.sql piped into mysql" \
  "UPDATE t SET v = 1;" "$(cat "$SQL_LOG")"

# --- _validate_hooks: pre-flight hook checks ---------------------------------
assert_ok "validate: seeded .sample files pass silently" _validate_hooks demo
out="$(_validate_hooks demo 2>&1)"
assert_fail "validate: .sample files produce no warnings" \
  grep -q "SKIPPED" <<EOF
$out
EOF

touch "$hooks/pre-import.d/40-forgot-chmod.sh"   # not executable
out="$(_validate_hooks demo 2>&1)"
assert_contains "validate: non-executable hook warns" \
  "40-forgot-chmod.sh is not executable" "$out"
assert_ok "validate: non-executable hook is a warning, not fatal" _validate_hooks demo
rm "$hooks/pre-import.d/40-forgot-chmod.sh"

printf '#!/bin/bash\nif then fi (((\n' > "$hooks/pre-import.d/50-broken-syntax.sh"
chmod +x "$hooks/pre-import.d/50-broken-syntax.sh"
assert_fail "validate: shell hook with syntax error dies" _validate_hooks demo
assert_contains "validate: syntax error names the hook" "50-broken-syntax.sh has a shell syntax error" \
  "$( (_validate_hooks demo) 2>&1 || true )"
rm "$hooks/pre-import.d/50-broken-syntax.sh"

printf 'UPDATE t SET v=1;\n' > "$hooks/pre-import.d/60-misplaced.sql"
out="$(_validate_hooks demo 2>&1)"
assert_contains "validate: pre-import *.sql warns it never runs" \
  "only runs post-import" "$out"
rm "$hooks/pre-import.d/60-misplaced.sql"

# --- _dump_looks_complete: truncated-dump detection --------------------------
printf 'INSERT INTO `t` VALUES (1);\n-- Dump completed on 2026-07-16\n' > "$tmp/complete.sql"
assert_ok "complete: ends with mysqldump marker" _dump_looks_complete "$tmp/complete.sql"

printf 'CREATE TABLE `t` (`a` int);\nINSERT INTO `t` VALUES (1);\n' > "$tmp/semi.sql"
assert_ok "complete: ends with ';'" _dump_looks_complete "$tmp/semi.sql"

printf 'INSERT INTO `t` VALUES (1);\n\n   \n' > "$tmp/trail.sql"
assert_ok "complete: trailing blank lines ignored" _dump_looks_complete "$tmp/trail.sql"

printf 'INSERT INTO `t` VALUES (1,'"'"'{\\"charges.data.' > "$tmp/cut.sql"
assert_fail "truncated: ends mid-statement" _dump_looks_complete "$tmp/cut.sql"

: > "$tmp/empty.sql"
assert_fail "truncated: empty file" _dump_looks_complete "$tmp/empty.sql"

# --- a failing hook dies loudly (not a silent set -e exit) -------------------
printf '#!/bin/sh\nexit 1\n' > "$hooks/pre-import.d/30-broken.sh"
chmod +x "$hooks/pre-import.d/30-broken.sh"
assert_fail "pre-import: failing hook aborts" _run_hooks pre-import demo
assert_contains "pre-import: failing hook names itself" "hook failed: 30-broken.sh" \
  "$( (_run_hooks pre-import demo) 2>&1 || true )"

report
