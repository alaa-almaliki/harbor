#!/usr/bin/env bash
# test_services.sh — service catalog, selection parsing, resolution semantics.
set -uo pipefail
. "$HARBOR_TEST_DIR/lib.sh"
harbor_load common manifest ports services compose init ergo

# --- catalog -------------------------------------------------------------------
cat="$(services_catalog)"
case " $cat " in *" mysql "*) pass "catalog: includes mysql" ;;
  *) fail "catalog: includes mysql" "mysql present" "$cat" ;; esac
case " $cat " in *" opensearch "*) pass "catalog: includes opensearch" ;;
  *) fail "catalog: includes opensearch" "opensearch present" "$cat" ;; esac

assert_ok   "validate: known service" services_validate mysql opensearch
assert_fail "validate: unknown service" services_validate mysql nope

# --- resolution: absent vs empty vs written ------------------------------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkproj() {  # mkproj <name> <services-line-or-empty>
  mkdir -p "$tmp/projects/$1/.harbor"
  { printf 'framework: laravel\nphp: "8.3"\n'
    if [ -n "${2-}" ]; then printf '%s\n' "$2"; fi
  } > "$tmp/projects/$1/.harbor/harbor.yml"
}
mkproj absent ""
mkproj empty 'services: {}'
mkproj written 'services: { opensearch: "os:1" }'
mkproj legacy 'services: [mysql, rabbitmq]'
mkproj esearch 'services: { elasticsearch: "es:1" }'

{ export HARBOR_PROJECTS="$tmp/projects"
  assert_eq "resolve: absent key -> framework default" \
    "mysql" "$(_project_services absent laravel)"
  assert_eq "resolve: empty map -> no services" \
    "" "$(_project_services empty laravel)"
  assert_eq "resolve: written map -> as written" \
    "opensearch" "$(_project_services written laravel)"
  assert_eq "resolve: legacy list -> as written" \
    "mysql rabbitmq" "$(_project_services legacy laravel)"
  assert_eq "resolve: absent key, magento -> magento default" \
    "mysql opensearch rabbitmq" "$(_project_services absent magento)"

  # --- project_has_service -----------------------------------------------------
  assert_ok   "has_service: legacy list includes mysql" project_has_service legacy mysql
  assert_ok   "has_service: legacy list includes rabbitmq" project_has_service legacy rabbitmq
  assert_fail "has_service: legacy list excludes opensearch" project_has_service legacy opensearch
  assert_fail "has_service: empty map -> no service present" project_has_service empty mysql
  assert_ok   "has_service: absent key -> framework default present" project_has_service absent mysql

  # substring-bleed guard: space-padded `case` match must not let "opensearch"/
  # "elasticsearch" satisfy a check for "search". If the padding in
  # project_has_service's `case " $(...) " in *" $svc "*)` were dropped, these
  # would false-positive.
  assert_fail "has_service: opensearch does not bleed into 'search'" project_has_service written search
  assert_fail "has_service: elasticsearch does not bleed into 'search'" project_has_service esearch search
  assert_ok   "has_service: opensearch project reports opensearch" project_has_service written opensearch
  assert_ok   "has_service: elasticsearch project reports elasticsearch" project_has_service esearch elasticsearch; }

# --- --services parsing --------------------------------------------------------
assert_eq "parse: csv"           "mysql opensearch" "$(services_parse_arg 'mysql,opensearch')"
assert_eq "parse: spaces + csv"  "mysql opensearch" "$(services_parse_arg 'mysql, opensearch')"
assert_eq "parse: empty = none"  ""                 "$(services_parse_arg '')"
assert_eq "parse: literal none"  ""                 "$(services_parse_arg 'none')"
assert_eq "parse: dedupes"       "mysql"            "$(services_parse_arg 'mysql,mysql')"
assert_fail "parse: rejects unknown" services_parse_arg 'mysql,bogus'

# --- picker parsing (pure; no TTY) --------------------------------------------
CAT="mysql opensearch rabbitmq meilisearch elasticsearch"
DEF="mysql"
assert_eq "pick: empty input -> defaults"  "mysql"            "$(services_pick_parse ''       "$CAT" "$DEF")"
assert_eq "pick: 'none' -> no services"    ""                 "$(services_pick_parse 'none'   "$CAT" "$DEF")"
assert_eq "pick: numbers"                  "mysql rabbitmq"   "$(services_pick_parse '1 3'    "$CAT" "$DEF")"
assert_eq "pick: commas accepted"          "mysql rabbitmq"   "$(services_pick_parse '1,3'    "$CAT" "$DEF")"
assert_eq "pick: order follows catalog"    "mysql rabbitmq"   "$(services_pick_parse '3 1'    "$CAT" "$DEF")"
assert_eq "pick: dedupes"                  "mysql"            "$(services_pick_parse '1 1'    "$CAT" "$DEF")"
assert_eq "pick: out of range invalid"     "__INVALID__"      "$(services_pick_parse '9'      "$CAT" "$DEF")"
assert_eq "pick: zero invalid"             "__INVALID__"      "$(services_pick_parse '0'      "$CAT" "$DEF")"
assert_eq "pick: garbage invalid"          "__INVALID__"      "$(services_pick_parse 'wat'    "$CAT" "$DEF")"
assert_eq "pick: whitespace-only -> defaults" "mysql"         "$(services_pick_parse '   '    "$CAT" "$DEF")"
assert_eq "pick: leading/trailing spaces"  "mysql rabbitmq"   "$(services_pick_parse '  1 3 ' "$CAT" "$DEF")"
assert_eq "pick: inner spacing preserved as separate tokens" \
                                           "mysql rabbitmq"   "$(services_pick_parse '1   3' "$CAT" "$DEF")"

# --- shrink detection (pure) ---------------------------------------------------
assert_eq "dropped: none"        ""          "$(services_dropped "mysql opensearch" "mysql opensearch")"
assert_eq "dropped: one"         "opensearch" "$(services_dropped "mysql opensearch" "mysql")"
assert_eq "dropped: all"         "mysql"     "$(services_dropped "mysql" "")"
assert_eq "dropped: growth only" ""          "$(services_dropped "mysql" "mysql opensearch")"

# --- _services_at_risk: three-way docker-volume-inspect outcome (pure) --------
# services_confirm_shrink's whole job is deciding whether to prompt before a
# service (and its data) is dropped. `_services_at_risk` is the extracted,
# stdin-free risk assessment (a testability seam per CLAUDE.md §6.5) — assert
# the determination directly instead of driving the interactive confirm().
#
# One `docker` stub, mode-selected via $_DOCKER_STUB, reused for the rest of
# this file (including the cmd_render decline test below) rather than
# redefined per-scenario — shellcheck's SC2329 flags an earlier `docker()`
# definition as "never invoked" once it's shadowed by a later redefinition in
# the same file, since it can't trace the call happening inside the sourced
# _services_at_risk. A single definition sidesteps that false positive.
docker() {
  case "$_DOCKER_STUB" in
    # `docker info` (and everything else) fails: daemon entirely unreachable.
    down) return 1 ;;
  esac
  case "$1" in
    info) return 0 ;;
    volume)
      case "$_DOCKER_STUB" in
        # 2. `inspect` fails with the real "no such volume" wording Docker
        # uses on this machine (verified: `docker volume inspect
        # definitely-not-a-real-volume-xyz` -> "Error response from daemon:
        # get definitely-not-a-real-volume-xyz: no such volume") -> genuinely
        # absent -> NOT at risk.
        absent) printf 'Error response from daemon: get %s: no such volume\n' "$3" >&2; return 1 ;;
        # 3. `inspect` fails for some other reason (permission error, wrong
        # DOCKER_HOST/context, transient daemon fault, ...) -> unknown ->
        # assume at risk. This is the assertion that pins the fix: the old
        # code treated ANY inspect failure as "volume absent" and silently
        # skipped the prompt.
        other) printf 'permission denied\n' >&2; return 1 ;;
        # 1. `inspect` succeeds -> volume exists -> at risk.
        *) return 0 ;;
      esac
      ;;
  esac
}

_DOCKER_STUB=ok
out="$(_services_at_risk atriskproj mysql "")"
assert_contains "at_risk: inspect succeeds -> reported at risk" "mysql:" "$out"

_DOCKER_STUB=absent
out="$(_services_at_risk atriskproj mysql "")"
assert_eq "at_risk: inspect fails with 'no such volume' -> NOT at risk" "" "$out"

_DOCKER_STUB=other
out="$(_services_at_risk atriskproj mysql "")"
assert_contains "at_risk: inspect fails with unrelated error -> assumed at risk" "mysql:" "$out"

# --- cmd_render: declining the confirm gate must not touch the manifest -------
# Regression test: _materialize_services (which rewrites a legacy list-format
# `services:` into the explicit map form, and strips db.image) used to run
# BEFORE services_confirm_shrink. So declining the shrink prompt still left the
# manifest mutated on disk while Harbor printed "aborted — manifest unchanged".
# Pins the invariant that matters: the manifest is byte-identical after a
# declined render, for a legacy list-format project.
export HARBOR_PROJECTS="$tmp/projects"
export HARBOR_PORTS_DIR="$tmp/ports"
export HARBOR_LOCK_DIR="$tmp/lock"
mkdir -p "$HARBOR_PORTS_DIR" "$HARBOR_LOCK_DIR"

mkproj shrink 'services: [mysql, rabbitmq]'
# Pre-allocate ports (ports_ensure requires an existing file) and a compose file
# whose service list is a SUPERSET of what the manifest resolves to — mysql +
# rabbitmq + opensearch vs. the manifest's mysql + rabbitmq — which is exactly
# the "shrink" that makes services_confirm_shrink prompt.
printf 'HARBOR_INDEX=0\nDB_PORT=20000\n' > "$HARBOR_PORTS_DIR/shrink"
cat > "$(project_harbor_dir shrink)/docker-compose.yml" <<'EOF'
services:
  mysql:
    image: mysql:8.0
  rabbitmq:
    image: rabbitmq:3.13
  opensearch:
    image: opensearchproject/opensearch:2.19.0
volumes:
  dbdata:
EOF

mf="$(manifest_path shrink)"
before_sum="$(shasum "$mf")"

# Switch the shared `docker` stub (defined above) to "down" so `docker info`
# fails deterministically — no real Docker calls, no dependence on whether
# Docker happens to be running on this machine. This forces
# services_confirm_shrink to assume data is at risk and prompt, without ever
# reaching `docker volume inspect`.
_DOCKER_STUB=down

# confirm() reads stdin via `read -r -p`; a piped 'n' declines without a TTY.
# HARBOR_YES=1 FORCES yes, so it must stay unset here — the whole point of this
# test is exercising a real decline.
unset HARBOR_YES
render_out="$tmp/render.out"
render_rc=0
( printf 'n\n' | cmd_render shrink ) >"$render_out" 2>&1 || render_rc=$?

after_sum="$(shasum "$mf")"

assert_eq "render decline: cmd_render returns nonzero" "1" "$render_rc"
assert_contains "render decline: gate was actually reached (shrink warning shown)" \
  "removing opensearch from 'shrink'" "$(cat "$render_out")"
assert_contains "render decline: prints 'manifest unchanged'" \
  "aborted — manifest unchanged" "$(cat "$render_out")"
assert_eq "render decline: manifest byte-identical after decline" "$before_sum" "$after_sum"
assert_eq "render decline: legacy services: line still list-form" \
  "services: [mysql, rabbitmq]" "$(grep '^services:' "$mf")"

# --- _ps_db_column: `harbor ps` DB-column decision logic (pure) ---------------
# Regression test: `harbor ps` used to render `db:-` for BOTH "no mysql
# service" (intentional) and "has mysql but var/ports/<name> is missing" (a
# real, reachable drift case — verified on a live project). `_ps_db_column`
# must check project_has_service BEFORE ports_load, so a DB-less project
# never depends on ports_load succeeding, and the two states must render as
# visually distinct markers.
mkproj psdb_none 'services: {}'
mkproj psdb_ok 'services: [mysql]'
mkproj psdb_broken 'services: [mysql]'
printf 'HARBOR_INDEX=1\nDB_PORT=20020\n' > "$HARBOR_PORTS_DIR/psdb_ok"
rm -f "$HARBOR_PORTS_DIR/psdb_broken"

assert_eq "ps db column: no mysql service -> db:-" \
  "db:-" "$(_ps_db_column psdb_none)"
assert_eq "ps db column: mysql + ports allocated -> db:<port>" \
  "db:20020" "$(_ps_db_column psdb_ok)"
assert_eq "ps db column: mysql + NO ports file -> db:? (needs attention)" \
  "db:?" "$(_ps_db_column psdb_broken)"

report
