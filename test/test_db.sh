#!/usr/bin/env bash
# test_db.sh — hook-runner semantics (lib/db.sh _run_hooks). Regression suite
# for the silent-import-death bug: a non-executable file (e.g. a seeded
# *.sample) must never make _run_hooks return nonzero, or `set -e` kills the
# whole import pipeline with no error output. No Docker: _db_mysql is stubbed.
set -uo pipefail
. "$HARBOR_TEST_DIR/lib.sh"
harbor_load common manifest services init db

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

# --- streamed DEFINER strip == in-place strip_definers ------------------------
printf 'CREATE DEFINER=`prod`@`%%` PROCEDURE p() SQL SECURITY DEFINER BEGIN END;\nINSERT INTO `t` VALUES ("keep DEFINER-free data");\n' > "$tmp/def.sql"
cp "$tmp/def.sql" "$tmp/def-inplace.sql"
strip_definers "$tmp/def-inplace.sql"
_db_stream "$tmp/def.sql" | LC_ALL=C sed -E "$_DEFINER_SED" > "$tmp/def-stream.sql"
assert_eq "definer strip: stream output matches in-place" \
  "$(cat "$tmp/def-inplace.sql")" "$(cat "$tmp/def-stream.sql")"

gzip -c "$tmp/def.sql" > "$tmp/def.sql.gz"
assert_eq "definer strip: gz stream matches too" \
  "$(cat "$tmp/def-inplace.sql")" "$(_db_stream "$tmp/def.sql.gz" | LC_ALL=C sed -E "$_DEFINER_SED")"

# --- _fk_wrapped: FK + unique checks off around the dump ----------------------
printf 'INSERT INTO `t` VALUES (1);\n' > "$tmp/fk.sql"
fkout="$(_fk_wrapped "$tmp/fk.sql")"
assert_contains "fk_wrapped: FK checks off"      "SET FOREIGN_KEY_CHECKS=0; SET UNIQUE_CHECKS=0;" "$fkout"
assert_contains "fk_wrapped: checks restored"    "SET UNIQUE_CHECKS=1; SET FOREIGN_KEY_CHECKS=1;" "$fkout"
assert_contains "fk_wrapped: dump body included" "INSERT INTO \`t\` VALUES (1);" "$fkout"

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

# --- _db_require: guard for a service-less project (host-independent) --------
# _db_require only reads the manifest via project_has_service (no Docker,
# no compose file, no launchd) — a pure-logic function per CLAUDE.md §6.5.
mkproj() {  # mkproj <name> <services-line-or-empty>
  mkdir -p "$tmp/projects/$1/.harbor"
  { printf 'framework: laravel\nphp: "8.3"\n'
    if [ -n "${2-}" ]; then printf '%s\n' "$2"; fi
  } > "$tmp/projects/$1/.harbor/harbor.yml"
}
mkproj hasdb 'services: { mysql: "mysql:8.0" }'
mkproj nodb  'services: {}'

assert_ok   "_db_require: passes when mysql service present" _db_require hasdb
assert_fail "_db_require: fails when mysql service absent"   _db_require nodb

# message content
err_out="$( (_db_require nodb) 2>&1 1>/dev/null )"
assert_contains "_db_require: error names the project" "no database service for 'nodb'" "$err_out"

# which stream: the error must reach stderr, not stdout
stdout_out="$( (_db_require nodb) 2>/dev/null )"
case "$stdout_out" in
  *"no database service"*) fail "_db_require: error does not leak to stdout" \
    "no 'no database service' on stdout" "$stdout_out" ;;
  *) pass "_db_require: error does not leak to stdout" ;;
esac
assert_contains "_db_require: error reaches stderr" "no database service for 'nodb'" "$err_out"

report
