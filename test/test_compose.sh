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

# --- _destroy_project_volumes: the name-anchor must not over-match -----------
# Highest-risk logic in the optional-services work: `harbor destroy` selects
# volumes with `grep -E "^harbor-${name}_"`. A greedy pattern (missing the
# trailing `_`) would silently drop a DIFFERENT project's database whenever one
# project name is a prefix of another (shop / shop2 / shop-staging / shopping).
# No Docker call here — `docker` is stubbed: `volume ls -q` returns a fixed
# fixture list, `volume rm <v>` records <v> to a log file we assert on.
rm_log="$tmp/rm.log"
: > "$rm_log"
# `_VOLLS_MODE` (default "ok") lets the fixed "volume ls" fixture below be
# swapped for a hard failure (Finding 3, further down) without a second
# `docker()` redefinition — shellcheck's SC2329 flags an earlier `docker()`
# as "never invoked" once a later redefinition shadows it in the same file
# (it can't trace the call happening inside the sourced function under test),
# same reasoning test_services.sh documents for its `_DOCKER_STUB`.
docker() {
  case "$1 $2" in
    "volume ls")
      if [ "${_VOLLS_MODE:-ok}" = "fail" ]; then
        echo "Cannot connect to the Docker daemon at unix:///var/run/docker.sock" >&2
        return 1
      fi
      cat <<'VOLS'
harbor-shop_dbdata
harbor-shop_esdata
harbor-shop2_dbdata
harbor-shop-staging_dbdata
harbor-shopping_dbdata
VOLS
      ;;
    # records EVERY volume argument, not just the first: the removal is batched
    # into one `docker volume rm a b c`, and what matters is which volumes were
    # removed, not how many calls it took.
    "volume rm") shift 2; printf '%s\n' "$@" >> "$rm_log" ;;
    *) return 0 ;;
  esac
}

_destroy_project_volumes shop
removed="$(cat "$rm_log")"

assert_contains "destroy shop: removes its own dbdata" "harbor-shop_dbdata" "$removed"
assert_contains "destroy shop: removes its own esdata" "harbor-shop_esdata" "$removed"
assert_fail "destroy shop: leaves shop2's volume"          grep -q '^harbor-shop2_dbdata$'         "$rm_log"
assert_fail "destroy shop: leaves shop-staging's volume"   grep -q '^harbor-shop-staging_dbdata$'  "$rm_log"
assert_fail "destroy shop: leaves shopping's volume"       grep -q '^harbor-shopping_dbdata$'      "$rm_log"

# --- _destroy_project_volumes: Finding 3 — a FAILED `docker volume ls` must
# NOT be read as "no matching volumes" ----------------------------------------
# `docker volume ls -q 2>/dev/null | grep ... || true` used to turn ANY
# failure (daemon unreachable, wrong context, transient fault, ...) into the
# empty string — indistinguishable from a genuinely empty result. `harbor
# destroy` would then confirm, skip `down -v`, find "no" volumes, unlink,
# release ports, and report "destroyed: <name>" while the real volume stays
# on disk with no Harbor command left able to reach it (compose file and
# manifest are already gone by then). _destroy_project_volumes must now
# return nonzero on the enumeration failure and must not attempt to remove
# anything, since it has no idea what's actually there.
before_rm="$(cat "$rm_log")"
_VOLLS_MODE=fail
fail_out="$tmp/destroy_vols_fail.out"
fail_rc=0
_destroy_project_volumes shop >"$fail_out" 2>&1 || fail_rc=$?
_VOLLS_MODE=ok
after_rm="$(cat "$rm_log")"

assert_eq "destroy volumes: returns nonzero when 'docker volume ls' fails" "1" "$fail_rc"
assert_eq "destroy volumes: attempts no removal when it couldn't even list" \
  "$before_rm" "$after_rm"
assert_contains "destroy volumes: warns instead of staying silent" \
  "could not list" "$(cat "$fail_out")"

report
