#!/usr/bin/env bash
# test_help.sh — per-command help topics (lib/help.sh). Pure logic: no host, no
# PHP, no Docker. The drift guards are the point: help that silently stops
# covering a command is worse than no help, because you trust it.
set -uo pipefail
. "$HARBOR_TEST_DIR/lib.sh"
harbor_load common completion help   # help_topics derives from completion's _HARBOR_CMDS

# --- passthrough classification ----------------------------------------------
# These exec another tool, so their --help belongs to that tool.
for c in run composer artisan console spark magento node npm; do
  assert_ok "passthrough: $c" help_passthrough "$c"
done
# These are Harbor's own structured commands — they answer --help themselves.
for c in db php xdebug store logs up destroy doctor; do
  assert_fail "not passthrough: $c" help_passthrough "$c"
done

# --- topic lookup -------------------------------------------------------------
assert_fail "unknown topic returns nonzero" help_topic definitely-not-a-command
assert_eq "unknown topic prints nothing" "" "$(help_topic definitely-not-a-command 2>&1)"

# --- every advertised topic actually exists ----------------------------------
# help_topics derives from completion's _HARBOR_CMDS, so this also guards THAT
# list: a command that completes but has no topic (or a topic `harbor help`
# advertises but can't print) fails here.
missing=""
for t in $(help_topics); do
  help_topic "$t" >/dev/null 2>&1 || missing="$missing $t"
done
assert_eq "every advertised topic has text" "" "$missing"

# --- every dispatchable command has a topic ----------------------------------
# Parses bin/harbor's dispatch case arms. Only `help` is excluded (it IS this
# system); `version`'s arm is `version|-v|--version)`, which the [a-z|] pattern
# can't match, so it never reaches the loop.
cmds="$(awk '/^main\(\)/,/^}/' "$HARBOR_ROOT/bin/harbor" \
        | grep -oE '^ {4}[a-z|]+\)' | tr -d ' )' | tr '|' ' ')"
# The parse silently skips any arm containing - or ", so it can only ever
# UNDER-collect — i.e. fail open and stay green while covering nothing. Assert a
# floor so shrinkage is loud.
n_cmds=0; for c in $cmds; do n_cmds=$((n_cmds + 1)); done
assert_ok "dispatch parse found a sane number of commands (got $n_cmds)" test "$n_cmds" -ge 40

uncovered=""
for c in $cmds; do
  [ "$c" = help ] && continue
  help_topic "$c" >/dev/null 2>&1 || uncovered="$uncovered $c"
done
assert_eq "every dispatched command has a topic" "" "$uncovered"

# --- help_intercept: who answers --help --------------------------------------
# 1st arg: plainly ours.
assert_ok "intercept: db --help is ours" help_intercept db --help
assert_contains "intercept: prints the db topic" "harbor db —" "$(help_intercept db --help 2>&1)"
assert_ok "intercept: -h works too" help_intercept db -h
assert_fail "intercept: no --help anywhere -> nothing to do" help_intercept db create shop

# 2nd arg: the <cmd>-<sub> topic when there is one...
assert_ok "intercept: db sandbox --help is ours" help_intercept db sandbox --help
assert_contains "intercept: prints the sandbox topic" "harbor db sandbox —" \
  "$(help_intercept db sandbox --help 2>&1)"
# ...else fall back to the command's own topic. These are the cases that used to
# reach the command as data, with real consequences: `logs nginx --help` hung on
# `tail -F`, `xdebug on --help` enabled Xdebug and restarted every pool, and
# `php use --help` reported `unsupported version '--help'`.
_owns() {  # <cmd> <sub> — `harbor <cmd> <sub> --help` must be answered by us
  assert_ok "intercept: $1 $2 --help is ours (not data)" help_intercept "$1" "$2" --help
  assert_contains "intercept: $1 $2 --help -> the $1 topic" "harbor $1" \
    "$(help_intercept "$1" "$2" --help 2>&1 | head -1)"
}
_owns logs nginx      # used to hang: tail -F
_owns xdebug on       # used to enable Xdebug + restart every pool
_owns php use         # used to report `unsupported version '--help'`
_owns store add
_owns tools sync
_owns secure host     # used to add `--help` as a cert SAN

# 3rd arg onward: only a real <cmd>-<sub> topic wins; otherwise Harbor has handed
# argv to a tool and the flag is the tool's.
assert_ok "intercept: db sandbox create --help is ours" help_intercept db sandbox create --help
assert_fail "intercept: tool <name> <tool> --help reaches the tool" \
  help_intercept tool shop wkhtmltopdf --help
assert_eq "intercept: ...and prints nothing itself" "" \
  "$(help_intercept tool shop wkhtmltopdf --help 2>&1)"
assert_fail "intercept: db import <name> <file> --help falls through" \
  help_intercept db import shop dump.sql --help

# Passthrough is never intercepted, at any position.
assert_fail "intercept: composer --help falls through" help_intercept composer --help
assert_eq "intercept: passthrough prints nothing" "" "$(help_intercept composer --help 2>&1)"
assert_fail "intercept: run <name> php --help falls through" help_intercept run app php --help

# --- usage_die: one arrow, chosen not hand-written ----------------------------
# Structured commands point at --help; passthrough points at `harbor help <cmd>`
# (their --help belongs to the tool). Call sites never pick.
out="$( (usage_die db "harbor db ...") 2>&1 || true)"
assert_contains "usage_die: structured -> --help" "harbor db --help" "$out"
out="$( (usage_die run "harbor run ...") 2>&1 || true)"
assert_contains "usage_die: passthrough -> harbor help run" "harbor help run" "$out"
# A hyphenated topic key renders as the command the user actually types.
out="$( (usage_die db-sandbox "harbor db sandbox ...") 2>&1 || true)"
assert_contains "usage_die: db-sandbox -> 'harbor db sandbox --help'" "harbor db sandbox --help" "$out"
assert_fail "usage_die exits nonzero" usage_die db "harbor db ..."

# --- topic shape --------------------------------------------------------------
# Each topic leads with `harbor <cmd> — purpose` and shows a Usage line, so they
# scan identically. Checked on a representative sample.
for t in db php xdebug run; do
  out="$(help_topic "$t" 2>&1)"
  assert_contains "topic $t: leads with its name" "harbor $t" "$(printf '%s' "$out" | head -1)"
  assert_contains "topic $t: has a Usage line" "Usage:" "$out"
done

report
