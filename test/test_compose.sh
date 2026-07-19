#!/usr/bin/env bash
# test_compose.sh — fragment assembly (lib/compose.sh _compose_assemble).
# Regression suite for the volume-less-service bug: a service with no
# templates/compose/volumes fragment must never make _compose_assemble return
# nonzero, or the plain `_compose_assemble … > docker-compose.yml` call in
# init.sh kills `harbor render`/`init` under set -e with no error output.
# Hermetic: HARBOR_TEMPLATES points at a throwaway dir, so the real templates
# are never read and the assertions don't drift when a service is added.
set -uo pipefail
. "$HARBOR_TEST_DIR/lib.sh"
harbor_load common compose

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
HARBOR_TEMPLATES="$tmp/templates"
mkdir -p "$HARBOR_TEMPLATES/compose/services" "$HARBOR_TEMPLATES/compose/volumes"

printf 'services:\n' > "$HARBOR_TEMPLATES/compose/header.yml.tmpl"
# "withvol" has both fragments; "novol" is service-only (e.g. a stateless
# sidecar) — the documented CLAUDE.md §6 case where a volume fragment is optional
printf '  withvol:\n    image: withvol:1\n' > "$HARBOR_TEMPLATES/compose/services/withvol.yml.tmpl"
printf '  novol:\n    image: novol:1\n'     > "$HARBOR_TEMPLATES/compose/services/novol.yml.tmpl"
printf '  withvol-data:\n'                  > "$HARBOR_TEMPLATES/compose/volumes/withvol.yml.tmpl"

# run it the way init_render_compose does — a plain call under set -e
assemble_errexit() { ( set -e; _compose_assemble "$@" >/dev/null; echo SURVIVED ) 2>/dev/null; }

# --- a service WITH a volume fragment emits the volumes: section -------------
assert_ok "withvol: returns 0" _compose_assemble withvol
assert_contains "withvol: service block emitted" "image: withvol:1" "$(_compose_assemble withvol)"
assert_contains "withvol: volumes section emitted" "withvol-data:" "$(_compose_assemble withvol)"

# --- a volume-less service is inert, not fatal -------------------------------
# This is the regression: `[ -f "$frag" ] && render_str "$frag"` as the loop
# body's last statement made the missing-fragment case the return value.
assert_ok "novol alone: returns 0" _compose_assemble novol
assert_contains "novol alone: service block emitted" "image: novol:1" "$(_compose_assemble novol)"
assert_fail "novol alone: no empty volumes section" \
  grep -q '^volumes:' <<<"$(_compose_assemble novol)"

# the ordering that actually triggered it: volume-less service LAST, so its
# false guard is the final statement of the volumes loop
assert_ok "novol last: returns 0" _compose_assemble withvol novol
assert_contains "novol last: under set -e does not kill render" \
  SURVIVED "$(assemble_errexit withvol novol)"
assert_contains "novol last: volumes section still has withvol" \
  "withvol-data:" "$(_compose_assemble withvol novol)"

# --- an unknown service still dies loudly (not silently) ---------------------
assert_fail "unknown service aborts" _compose_assemble nosuchsvc
assert_contains "unknown service names itself" "unknown service 'nosuchsvc'" \
  "$( (_compose_assemble nosuchsvc) 2>&1 || true )"

report
