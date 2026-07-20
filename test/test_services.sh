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
mkproj bare 'services:'
mkproj written 'services: { opensearch: "os:1" }'
mkproj legacy 'services: [mysql, rabbitmq]'
mkproj esearch 'services: { elasticsearch: "es:1" }'

{ export HARBOR_PROJECTS="$tmp/projects"
  assert_eq "resolve: absent key -> framework default" \
    "mysql" "$(_project_services absent laravel)"
  assert_eq "resolve: empty map -> no services" \
    "" "$(_project_services empty laravel)"
  # Finding 1: a bare `services:` (present, nothing after the colon — the
  # obvious hand-edit for "no services") must resolve the SAME as an explicit
  # `{}`, not fall back to the framework default. Before the fix, `_project_services`
  # tested presence via `manifest_has` (a VALUE test), so this read identically
  # to the key being absent and silently handed back "mysql".
  assert_eq "resolve: bare value -> no services (Finding 1)" \
    "" "$(_project_services bare laravel)"
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

# --- cmd_services: a declined change on a manifest with NO services: key -----
# must leave it with NO services: key — not a bare "services:" line. Task 10's
# whole restore mechanism exists to make a decline a true no-op; a manifest
# that gains an empty "services:" line is a different (though semantically
# equivalent, since manifest_get reads both as absent) file than before.
mkproj nosvckey ""   # framework laravel, no services: line at all (legacy project)
printf 'HARBOR_INDEX=2\nDB_PORT=20040\n' > "$HARBOR_PORTS_DIR/nosvckey"
cat > "$(project_harbor_dir nosvckey)/docker-compose.yml" <<'EOF'
services:
  mysql:
    image: mysql:8.0
volumes:
  dbdata:
EOF

mf2="$(manifest_path nosvckey)"
before_sum2="$(shasum "$mf2")"

# Force the shrink-confirm gate to trigger (compose has mysql, we're dropping
# it) and then decline it, same stub/technique as the render-decline test above.
_DOCKER_STUB=down
unset HARBOR_YES
svc_out="$tmp/services.out"
svc_rc=0
( printf 'n\n' | cmd_services rm nosvckey mysql ) >"$svc_out" 2>&1 || svc_rc=$?

after_sum2="$(shasum "$mf2")"

assert_eq "services decline: cmd_services returns nonzero" "1" "$svc_rc"
assert_eq "services decline: manifest byte-identical (no bare services: line left behind)" \
  "$before_sum2" "$after_sum2"
assert_fail "services decline: services key is still absent, not present-empty" \
  manifest_has "$mf2" services

# --- cmd_render: propagates a real (non-decline) render failure ---------------
# Regression test for the "false success under `if !`" review finding.
# cmd_render is now called as an `if` condition (cmd_services' render-then-
# restore, right below) — and bash disables `set -e` for a condition's WHOLE
# call graph (a real, general trap; see CLAUDE.md §3). init_render_compose's
# "stop the stack before deleting the compose file" branch has a bare
# `return 1` on a failed `docker compose down`; cmd_render used to call it as
# a bare statement relying on `set -e` to abort — which never fires under
# `if !`, so cmd_render fell through to init_write_connection/etc. and printed
# "ok rendered ..." (return 0) while leaving docker-compose.yml stale and the
# manifest already pointing at the new (unapplied) service list. Reproduced
# with a stubbed failing `docker compose ... down`: RC=0, manifest said
# `services: {  }`, docker-compose.yml still listed mysql.
#
# This test can't rely on `set -e` at all — test files run `set -uo pipefail`
# deliberately (CLAUDE.md §6.5), so a bare failing statement wouldn't abort
# here either, with or without the bug. It asserts the RETURN VALUE
# propagates, which is exactly what `init_render_compose ... || return 1`
# provides regardless of errexit context.
mkproj renderfail 'services: {}'
printf 'HARBOR_INDEX=3\nDB_PORT=20060\n' > "$HARBOR_PORTS_DIR/renderfail"
cat > "$(project_harbor_dir renderfail)/docker-compose.yml" <<'EOF'
services:
  mysql:
    image: mysql:8.0
volumes:
  dbdata:
EOF

# Stub project_compose itself (not docker) — simplest, most direct way to
# control what init_render_compose's calls into it do, without emulating real
# `docker compose` argv. Mode-selected via $_PC_FAIL (default: fail, what this
# scenario needs) and every call is logged to $pc_log, so this ONE definition
# is reused by every later scenario in this file that needs to fake
# project_compose — a second `project_compose() {...}` further down would get
# THIS one flagged as "never invoked" (SC2329) once it's shadowed, same
# reasoning the shared `docker()` stub documents elsewhere in this suite.
pc_log="$tmp/project_compose.log"
_PC_FAIL=1
project_compose() {
  local n="$1"; shift
  printf '%s %s\n' "$n" "$*" >> "$pc_log"
  [ "$_PC_FAIL" = 1 ] && return 1
  return 0
}

export HARBOR_YES=1   # bypass the (unrelated) shrink-confirm prompt
render2_rc=0
cmd_render renderfail >/dev/null 2>&1 || render2_rc=$?

assert_eq "render: propagates init_render_compose's down-failure as nonzero" "1" "$render2_rc"

# --- cmd_services: restores the manifest on a NON-decline render failure -----
# Once cmd_render actually propagates a real failure (the fix above),
# cmd_services' existing `if ! cmd_render ...` restore must fire for ANY
# nonzero return — not just a declined confirm gate. Same stubbed
# project_compose failure as above; this project never sees a decline prompt
# (HARBOR_YES=1 the whole way), so a passing restore here proves the restore
# logic is keyed on cmd_render's return code, not on "was it a decline".
mkproj svcrenderfail 'services: { mysql: "mysql:8.0" }'
printf 'HARBOR_INDEX=4\nDB_PORT=20080\n' > "$HARBOR_PORTS_DIR/svcrenderfail"
cat > "$(project_harbor_dir svcrenderfail)/docker-compose.yml" <<'EOF'
services:
  mysql:
    image: mysql:8.0
volumes:
  dbdata:
EOF

mf3="$(manifest_path svcrenderfail)"
before_sum3="$(shasum "$mf3")"

svc3_out="$tmp/services3.out"
svc3_rc=0
cmd_services rm svcrenderfail mysql >"$svc3_out" 2>&1 || svc3_rc=$?

after_sum3="$(shasum "$mf3")"

assert_eq "services: a non-decline render failure returns nonzero" "1" "$svc3_rc"
assert_eq "services: manifest restored (checksum identical) after a non-decline render failure" \
  "$before_sum3" "$after_sum3"
assert_contains "services: reports reverted, not a decline message" \
  "reverted: svcrenderfail services unchanged" "$(cat "$svc3_out")"
unset HARBOR_YES

# --- cmd_services: pre-flights ports_ensure BEFORE writing the manifest ------
# Regression test for the other half of the same finding: a `die` reachable
# inside cmd_render's call graph (ports_ensure's own die, lib/init.sh) calls
# `exit`, terminating the process before cmd_services' restore (above) ever
# runs. Reproduced by deleting a project's var/ports/<name> file before
# `harbor services add`: the manifest was rewritten to the new service list
# and the process then died on "ports not allocated", with no restore and no
# hint that harbor.yml had already changed. cmd_services now runs the same
# ports_ensure precondition BEFORE the manifest write, so the die happens
# before any mutation, not after.
mkproj noports 'services: { mysql: "mysql:8.0" }'
# deliberately no var/ports/<name> file for 'noports'
mf4="$(manifest_path noports)"
before_sum4="$(shasum "$mf4")"
noports_out="$tmp/noports.out"
noports_rc=0
( cmd_services add noports opensearch ) >"$noports_out" 2>&1 || noports_rc=$?
after_sum4="$(shasum "$mf4")"

assert_eq "services: dies nonzero when ports aren't allocated (preflight)" "1" "$noports_rc"
assert_contains "services: reports the ports-not-allocated fix hint" \
  "ports not allocated for noports" "$(cat "$noports_out")"
assert_eq "services: manifest untouched by the ports-preflight die (no half-applied write)" \
  "$before_sum4" "$after_sum4"

# --- cmd_services: EXIT trap restores after a `die` AFTER the manifest write --
# The ports preflight covers the one die reachable before the write. This pins
# the general net: a `die` deeper in cmd_render's graph — reachable only AFTER
# cmd_services has already rewritten the services line — calls `exit` and skips
# the explicit `if ! cmd_render` restore. The EXIT trap must fire and put the
# manifest back byte-for-byte anyway. Stub init_render_compose to die post-write.
mkproj svcdie 'services: { mysql: "mysql:8.0" }'
printf 'HARBOR_INDEX=6\nDB_PORT=20120\n' > "$HARBOR_PORTS_DIR/svcdie"
mf5="$(manifest_path svcdie)"
before_sum5="$(shasum "$mf5")"
die_out="$tmp/svcdie.out"
die_rc=0
# shellcheck disable=SC2329  # invoked indirectly: cmd_render calls it by name
( init_render_compose() { die "boom after the manifest write"; }
  HARBOR_YES=1 cmd_services add svcdie opensearch ) >"$die_out" 2>&1 || die_rc=$?
after_sum5="$(shasum "$mf5")"

assert_eq "services: a die deep in cmd_render exits nonzero" "1" "$die_rc"
assert_eq "services: EXIT trap restores the manifest after a post-write die" \
  "$before_sum5" "$after_sum5"

# --- cmd_services: Finding 1 end-to-end — a bare `services:` must not get a
# user permanently stuck ------------------------------------------------------
# Full reproduction from the review: hand-edit `services: { mysql: "..." }`
# down to a bare `services:` (the obvious YAML way to write "none"). Before
# the fix, `_project_services` silently resolved this back to the framework
# default ("mysql"), so `cmd_services add <name> mysql` computed
# new == cur == "mysql" and reported "no change" — the user had no way to add
# mysql through the tool at all. This is pure growth (nothing dropped, no
# existing compose file), so no confirm gate is involved.
mkproj barefull 'services:'
printf 'HARBOR_INDEX=5\nDB_PORT=20100\n' > "$HARBOR_PORTS_DIR/barefull"

bare_out="$tmp/bare.out"
bare_rc=0
cmd_services add barefull mysql >"$bare_out" 2>&1 || bare_rc=$?

assert_eq "Finding 1: bare services: -> add mysql succeeds" "0" "$bare_rc"
assert_fail "Finding 1: add is NOT reported as 'no change'" \
  grep -q "no change" "$bare_out"
assert_eq "Finding 1: manifest now resolves mysql as an active service" \
  "mysql" "$(_project_services barefull laravel)"
assert_ok "Finding 1: project_has_service now sees mysql" \
  project_has_service barefull mysql

# --- init_render_compose: Finding 2 — a PARTIAL shrink stops only the DROPPED
# service, leaving the rest of the stack running -------------------------------
# Before the fix, `init_render_compose` only ran `project_compose ... down`
# on the shrink-to-EMPTY path; shrinking to a still-non-empty list just
# rewrote docker-compose.yml. `docker compose up -d` merely WARNS about
# "orphans" and leaves them running (`project_compose` never passes
# `--remove-orphans`), so the dropped service's container/heap stayed up —
# directly contradicting the shrink-confirm prompt the user just agreed to.
# The shared project_compose stub (defined above) records its calls instead
# of touching real Docker; here it must SUCCEED (unlike its default fail
# mode), so its logged calls reflect what init_render_compose actually asked
# it to do. The manifest already resolves to mysql-only (as if `services rm
# opensearch` already rewrote it), while the EXISTING compose file on disk
# still lists both, which is exactly the "old vs. new" comparison
# init_render_compose now makes before overwriting that file.
mkproj partialshrink 'services: { mysql: "mysql:8.0" }'
ports_allocate partialshrink >/dev/null
cat > "$(project_harbor_dir partialshrink)/docker-compose.yml" <<'EOF'
services:
  mysql:
    image: mysql:8.0
  opensearch:
    image: opensearchproject/opensearch:2.19.0
volumes:
  dbdata:
  osdata:
EOF

: > "$pc_log"
_PC_FAIL=0
ps_init_rc=0
init_render_compose partialshrink laravel >/dev/null 2>&1 || ps_init_rc=$?
_PC_FAIL=1   # restore default in case anything later in this file relies on it

assert_eq "partial shrink: init_render_compose succeeds" "0" "$ps_init_rc"
assert_contains "partial shrink: stops only the dropped service (opensearch)" \
  "partialshrink rm -s -f opensearch" "$(cat "$pc_log")"
assert_fail "partial shrink: does NOT stop the kept service (mysql)" \
  grep -q 'rm -s -f.*mysql' "$pc_log"
assert_fail "partial shrink: never calls a full 'down' (would drop the kept service too)" \
  grep -q ' down' "$pc_log"
psshrink_cf="$(project_harbor_dir partialshrink)/docker-compose.yml"
assert_contains "partial shrink: rewritten compose file keeps mysql" \
  "mysql:" "$(cat "$psshrink_cf")"
assert_fail "partial shrink: rewritten compose file drops opensearch" \
  grep -q 'opensearch:' "$psshrink_cf"

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

# --- services_select: arg-count vs emptiness (Edge 1) --------------------------
# cmd_init calls services_select with only 2 args and wants the framework
# default. cmd_services calls it with a 3rd arg that IS the project's current
# list, which for a DB-less project is the empty string — that must NOT be
# treated as "no arg given" and fall through to the framework default, or a
# bare Enter on `harbor services` would silently add mysql to a project that
# intentionally has none. HARBOR_YES=1 exercises the same non-interactive
# short-circuit that returns `defaults` directly, so this pins the resolved
# value without needing a TTY.
export HARBOR_YES=1
assert_eq "select: called with 2 args -> framework default" \
  "mysql" "$(services_select noargsproj laravel)"
assert_eq "select: called with explicit empty 3rd arg -> stays empty" \
  "" "$(services_select emptyargproj laravel "")"
unset HARBOR_YES

# --- services add/rm list algebra (pure) ---------------------------------------
assert_eq "apply: add new"        "mysql opensearch" "$(services_apply "mysql" add opensearch)"
assert_eq "apply: add existing"   "mysql"            "$(services_apply "mysql" add mysql)"
assert_eq "apply: rm present"     "mysql"            "$(services_apply "mysql opensearch" rm opensearch)"
assert_eq "apply: rm absent"      "mysql"            "$(services_apply "mysql" rm rabbitmq)"
assert_eq "apply: rm last"        ""                 "$(services_apply "mysql" rm mysql)"
assert_eq "apply: add two"        "mysql a b"        "$(services_apply "mysql" add a b)"

# --- services_fix_hint: the shared refusal tail (used by db.sh + magento.sh) ---
# It must name the project's manifest path, carry both the `render` and `up`
# next-steps, interpolate <what>, and reach STDOUT (it's advice, not the error).
fh_dir="$(mktemp -d)"; trap 'rm -rf "$fh_dir"' EXIT
( export HARBOR_PROJECTS="$fh_dir/projects"
  hint="$(services_fix_hint shop them 2>/dev/null)"     # capture stdout only
  assert_contains "fix_hint: names the manifest path"  "shop/.harbor/harbor.yml" "$hint"
  assert_contains "fix_hint: interpolates <what>"      "add them to"             "$hint"
  assert_contains "fix_hint: gives the render step"    "harbor render shop"      "$hint"
  assert_contains "fix_hint: gives the up step"        "harbor up shop"          "$hint" )

report
