#!/usr/bin/env bash
# test_init.sh — agent-skill seeding semantics (lib/init.sh) and project
# discovery (lib/update.sh). Uses a throwaway HARBOR_PROJECTS; the real skill
# source ($HARBOR_ROOT/ai/skills/harbor) is only read, never written.
set -uo pipefail
. "$HARBOR_TEST_DIR/lib.sh"
harbor_load common manifest init update

[ -d "$HARBOR_ROOT/ai/skills/harbor" ] || skip_all "no ai/skills/harbor source"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export HARBOR_PROJECTS="$tmp/projects"
mkdir -p "$HARBOR_PROJECTS"

dest="$(project_dir demo)/.claude/skills/harbor"

# --- init_write_agent_skills: seeds when absent ------------------------------
init_write_agent_skills demo 0
assert_ok "seed: SKILL.md created" test -f "$dest/SKILL.md"

# --- non-clobbering (force=0) keeps project-side edits -----------------------
printf 'LOCAL EDIT\n' > "$dest/SKILL.md"
init_write_agent_skills demo 0
assert_eq "seed: force=0 does not clobber existing" \
  "LOCAL EDIT" "$(cat "$dest/SKILL.md")"

# --- force refresh (force=1) overwrites managed files, keeps extras ----------
printf 'keep me\n' > "$dest/EXTRA.txt"
init_write_agent_skills demo 1
assert_fail "reseed: force=1 overwrites edited SKILL.md" \
  grep -q "LOCAL EDIT" "$dest/SKILL.md"
assert_ok   "reseed: force=1 restores real SKILL.md" \
  grep -q "Working in a Harbor project" "$dest/SKILL.md"
assert_ok   "reseed: force=1 preserves extra files" test -f "$dest/EXTRA.txt"

# --- _harbor_projects: only dirs with a .harbor manifest ---------------------
# demo has a .claude skill but no manifest, so it must NOT be listed.
mkdir -p "$HARBOR_PROJECTS/alpha/.harbor" "$HARBOR_PROJECTS/beta/.harbor" "$HARBOR_PROJECTS/nope"
: > "$HARBOR_PROJECTS/alpha/.harbor/harbor.yml"
: > "$HARBOR_PROJECTS/beta/.harbor/harbor.yml"
assert_eq "_harbor_projects: lists manifest dirs only" \
  "alpha
beta" \
  "$(_harbor_projects | sort)"

report
