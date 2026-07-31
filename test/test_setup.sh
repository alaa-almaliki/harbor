#!/usr/bin/env bash
# test_setup.sh — config_migrate: relocation of the global config from the
# pre-move ~/.config location into Harbor's in-tree etc/config. Pure filesystem
# logic (mv/rmdir), so it's unit-testable without touching the host.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"
harbor_load common setup

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# Override the paths AFTER sourcing — common.sh assigns both at source time, so
# an env prefix would be clobbered (see CLAUDE.md §6.5).
HARBOR_CONFIG="$tmp/etc/config"
HARBOR_CONFIG_LEGACY="$tmp/legacy/harbor/config"

# --- migrates a legacy config into the new in-tree path, preserving values ---
mkdir -p "$(dirname "$HARBOR_CONFIG_LEGACY")"
printf 'DB_BACKUP_KEEP=5\n' > "$HARBOR_CONFIG_LEGACY"
config_migrate >/dev/null
assert_ok   "migrate: new config created"            test -f "$HARBOR_CONFIG"
assert_fail "migrate: legacy config removed"         test -f "$HARBOR_CONFIG_LEGACY"
assert_eq   "migrate: settings preserved verbatim"   "DB_BACKUP_KEEP=5" "$(cat "$HARBOR_CONFIG")"
assert_fail "migrate: emptied legacy dir removed"    test -d "$(dirname "$HARBOR_CONFIG_LEGACY")"

# --- idempotent: a second run is a no-op, new file untouched -----------------
config_migrate >/dev/null
assert_eq   "idempotent: new file unchanged"         "DB_BACKUP_KEEP=5" "$(cat "$HARBOR_CONFIG")"

# --- no legacy present: no-op, must NOT create a new file --------------------
rm -f "$HARBOR_CONFIG"
config_migrate >/dev/null
assert_fail "no legacy -> nothing created"           test -f "$HARBOR_CONFIG"

# --- new already exists: legacy is left untouched (never clobbers) -----------
mkdir -p "$(dirname "$HARBOR_CONFIG")" "$(dirname "$HARBOR_CONFIG_LEGACY")"
printf 'DB_BACKUP_KEEP=9\n' > "$HARBOR_CONFIG"
printf 'DB_BACKUP_KEEP=1\n' > "$HARBOR_CONFIG_LEGACY"
config_migrate >/dev/null
assert_eq   "new exists: not clobbered by legacy"    "DB_BACKUP_KEEP=9" "$(cat "$HARBOR_CONFIG")"
assert_ok   "new exists: legacy left in place"       test -f "$HARBOR_CONFIG_LEGACY"

report
