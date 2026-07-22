#!/usr/bin/env bash
# compose.sh — shared stack lifecycle (Mailpit + Redis). Per-project stacks: Phase 5.

HARBOR_SHARED_COMPOSE="$HARBOR_DOCKER/docker-compose.yml"
HARBOR_SHARED_REDIS="harbor-shared-redis-1"   # container name from shared.yml (name: harbor-shared)

# die unless the Docker daemon is reachable (shared by every stack that shells to
# `docker compose` — shared, per-project, and the sandbox)
require_docker() { docker info >/dev/null 2>&1 || die "docker daemon not running — start Docker/OrbStack"; }

shared_render() {
  mkdir -p "$HARBOR_DOCKER"
  MAILPIT_PLATFORM="$(service_platform_line mailpit)" \
  REDIS_PLATFORM="$(service_platform_line redis)" \
  render "$HARBOR_TEMPLATES/compose/shared.yml.tmpl" "$HARBOR_SHARED_COMPOSE"
}

shared_up() {
  shared_render
  require_docker
  step "starting shared stack (mailpit :1025/:8025 + redis :6379)"
  docker compose -f "$HARBOR_SHARED_COMPOSE" up -d >/dev/null
}

shared_down() {
  [ -f "$HARBOR_SHARED_COMPOSE" ] || return 0
  docker compose -f "$HARBOR_SHARED_COMPOSE" down >/dev/null 2>&1 || true
}

# ── per-project stacks ──────────────────────────────────────────────────────
project_compose_file() { printf '%s' "$(project_harbor_dir "$1")/docker-compose.yml"; }

# does this project have a container stack at all? A project with `services: {}`
# has no compose file — that is a valid state, not an error.
project_has_stack() { [ -f "$(project_compose_file "$1")" ]; }

# project_compose_services <compose-file> — the service names (top-level keys
# under `services:`) actually present in a GENERATED compose file,
# space-separated; empty if the file doesn't exist. Only the keys under
# `services:` — a generated compose also has a top-level `volumes:` block
# whose entries sit at the SAME two-space indent, so a bare /^  [a-z]+:$/
# would pick up e.g. `dbdata` too and misreport it as a service (verified
# against a real generated file: it matched `mysql` AND `dbdata`). Shared by
# cmd_render (to detect a shrink for the confirm gate) and
# init_render_compose (to know which container(s) to stop on a partial
# shrink) so the two never drift on what "the old service list" means.
project_compose_services() {
  local f="$1"
  [ -f "$f" ] || { printf ''; return 0; }
  awk '
    /^services:/ { in_s = 1; next }
    /^[a-z]/     { in_s = 0 }
    in_s && /^  [a-z][a-z0-9_-]*:$/ { gsub(/[ :]/, ""); print }
  ' "$f" | tr '\n' ' ' | sed 's/ $//'
}

# _compose_assemble <svc...> — print a docker-compose.yml on stdout by concatenating
# per-service fragments (templates/compose/services/<svc>.yml.tmpl) under one
# `services:` header, then their volume decls under one `volumes:` footer. Render
# vars ({{DB_PORT}} …) must be set by the caller. Callers validate service names
# first (see init_render_compose) so this never emits a partial file mid-run.
_compose_assemble() {
  local svc frag any=0
  render_str "$HARBOR_TEMPLATES/compose/header.yml.tmpl"
  for svc in "$@"; do
    frag="$HARBOR_TEMPLATES/compose/services/$svc.yml.tmpl"
    [ -f "$frag" ] || die "unknown service '$svc' → add templates/compose/services/$svc.yml.tmpl"
    render_str "$frag"
  done
  for svc in "$@"; do [ -f "$HARBOR_TEMPLATES/compose/volumes/$svc.yml.tmpl" ] && any=1; done
  if [ "$any" -eq 1 ]; then
    printf 'volumes:\n'
    for svc in "$@"; do
      frag="$HARBOR_TEMPLATES/compose/volumes/$svc.yml.tmpl"
      # NOT `[ -f "$frag" ] && …` — a volume-less service as the last arg would
      # make the loop (and the function) return nonzero, killing the plain
      # `_compose_assemble … > docker-compose.yml` caller under set -e with no
      # output. See CLAUDE.md §3.
      if [ -f "$frag" ]; then render_str "$frag"; fi
    done
  fi
}

project_compose() {
  local name="$1"; shift
  local f; f="$(project_compose_file "$name")"
  [ -f "$f" ] || die "no stack for '$name' — run: harbor init $name"
  docker compose -f "$f" "$@"
}

# Poll until every given container id reports healthy (a container with no
# healthcheck counts as ready). $1 = whitespace-separated ids, $2 = max tries
# (2s each). Emits progress dots; returns 1 on timeout. Shared by project stacks
# and the sandbox (lib/sandbox.sh) — the caller prints the intro + result line.
_wait_healthy_ids() {
  local ids="$1" max="${2:-90}" i=0 st pend states
  [ -n "$ids" ] || return 0
  while [ "$i" -lt "$max" ]; do
    # one docker inspect for all containers; a container with no healthcheck -> "none"
    # shellcheck disable=SC2086
    states="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' $ids 2>/dev/null)"
    pend=""
    for st in $states; do
      case "$st" in healthy|none) : ;; *) pend="x" ;; esac
    done
    [ -z "$pend" ] && return 0
    printf '.'; i=$((i + 1)); sleep 2
  done
  return 1
}

# block until all of a project's containers with a healthcheck report healthy
_wait_ready() {
  local name="$1" max="${2:-90}" ids
  ids="$(project_compose "$name" ps -q 2>/dev/null)" || return 0
  [ -n "$ids" ] || return 0
  printf '   waiting for services to be healthy'
  if _wait_healthy_ids "$ids" "$max"; then printf ' ready\n'; return 0; fi
  printf '\n'; warn "timeout waiting for health (continuing)"; return 1
}

# flush only this project's Redis indices on the shared instance
redis_flush_project() {
  local name="$1" idx
  ports_load "$name" 2>/dev/null || return 0
  docker exec "$HARBOR_SHARED_REDIS" true >/dev/null 2>&1 || return 0
  for idx in "$REDIS_DB_CACHE" "$REDIS_DB_PAGE" "$REDIS_DB_SESSION" "$REDIS_DB_SPARE"; do
    docker exec "$HARBOR_SHARED_REDIS" redis-cli -n "$idx" flushdb >/dev/null 2>&1 || true
  done
}

cmd_up() {
  resolve_project "${1-}" "harbor up [<name>]"; local name="$_RP_NAME"
  # Lifecycle commands run in bulk across every project degrade to a no-op;
  # commands that are a direct request for a specific missing thing refuse
  # (see `harbor db`/`harbor mysql`, Task 8). `up` is bulk-run material (e.g.
  # from a script over every project), so a service-less project is a no-op,
  # not a failure.
  if ! project_has_stack "$name"; then
    step "nothing to start for '$name' (no services)"; return 0
  fi
  require_docker
  log "starting stack: $name"
  project_compose "$name" up -d
  _wait_ready "$name" || true
  ok "up: $name ($(project_harbor_dir "$name")/connection.txt has the details)"
}

cmd_down() {
  resolve_project "${1-}" "harbor down [<name>]"; local name="$_RP_NAME"
  # See cmd_up: bulk lifecycle commands no-op on a service-less project rather
  # than refusing.
  if ! project_has_stack "$name"; then
    step "nothing to stop for '$name' (no services)"; return 0
  fi
  log "stopping stack: $name (flushing its Redis indices)"
  redis_flush_project "$name"
  project_compose "$name" down
  ok "down: $name (MySQL data kept; use 'harbor destroy' to drop volumes)"
}

# No name -> restart Harbor itself (nginx/php/dnsmasq/shared stack). With a name
# -> restart that project's containers.
cmd_restart() {
  if [ -z "${1-}" ]; then platform_restart; return; fi
  local name="$1"
  # See cmd_up: bulk lifecycle commands no-op on a service-less project rather
  # than refusing.
  if ! project_has_stack "$name"; then
    step "nothing to restart for '$name' (no services)"; return 0
  fi
  project_compose "$name" restart
  _wait_ready "$name" || true
  ok "restarted: $name"
}

# Drop any Docker volumes left for this project, whether or not a compose file
# still exists. `render` deletes the compose file once `services:` goes empty
# (stack stopped first, volumes deliberately kept — dropping data is destroy's
# job, never render's), so a service-less project has no compose file for
# `down -v` to act on; this is the fallback that still reaches its volumes.
# Volumes are named harbor-<name>_<vol> by the compose `name:` header
# (templates/compose/header.yml.tmpl). Project names are
# `[a-z0-9][a-z0-9-]*` (valid_name) — no underscores — so the first `_` after
# "harbor-<name>" is always the compose-inserted separator, never part of
# another project's name: anchoring on "^harbor-<name>_" cannot match
# "harbor-<name>2_...". Safe to call even when nothing matches (idempotent).
#
# Returns 1 (WITHOUT removing anything) when `docker volume ls` itself fails,
# rather than treating a failed listing the same as an empty one. Those are
# not the same thing: `docker volume ls -q 2>/dev/null | grep ... || true`
# turns "the daemon is unreachable" into the empty string, which reads
# identically to "genuinely no matching volumes" — the caller (cmd_destroy)
# would then confirm, skip `down -v`, find "no" volumes, unlink, release
# ports, and report success while `harbor-<name>_dbdata` stays on disk with no
# Harbor command left able to reach it (the compose file and manifest are
# already gone by then). The one command whose entire job is reversibility
# must not claim to have removed things it could not even enumerate.
_destroy_project_volumes() {
  local name="$1" out vols v
  if ! out="$(docker volume ls -q 2>&1)"; then
    warn "could not list docker volumes for '$name' ($out)"
    return 1
  fi
  vols="$(printf '%s\n' "$out" | grep -E "^harbor-${name}_" || true)"
  if [ -n "$vols" ]; then
    # one `docker volume rm` for all of them — volume names never contain
    # whitespace, so the word-split is safe and saves a daemon round-trip per
    # volume (a Magento stack has three).
    # shellcheck disable=SC2086  # deliberate word-split of the volume list
    docker volume rm $vols >/dev/null 2>&1 || true
  fi
  return 0
}

cmd_destroy() {
  resolve_project "${1-}" "harbor destroy [<name>] [--files]"
  [ "$_RP_SHIFT" = 1 ] && shift; local name="$_RP_NAME"
  local files=0; [ "${1-}" = "--files" ] && files=1
  confirm "Destroy '$name' (drop containers + volumes + ports + vhost)?" || { warn "aborted"; return 1; }
  redis_flush_project "$name"
  if project_has_stack "$name"; then
    project_compose "$name" down -v >/dev/null 2>&1 || true
  fi
  # Unlink/ports-release don't touch Docker, so they still run (and are
  # reported) even when the volume sweep couldn't — a partial destroy that
  # says so honestly beats one that silently claims full success (see
  # _destroy_project_volumes above).
  local vols_ok=1
  _destroy_project_volumes "$name" || vols_ok=0
  cmd_unlink "$name" >/dev/null 2>&1 || true
  ports_release "$name"
  if [ "$files" = 1 ]; then rm -rf "$(project_dir "$name")"; warn "deleted $(project_dir "$name")"; fi
  if [ "$vols_ok" = 0 ]; then
    warn "destroy: $name unlinked and ports released, but its volumes could NOT be confirmed removed (docker unreachable?) — check: docker volume ls | grep harbor-$name ; re-run 'harbor destroy $name' once docker is reachable"
    return 1
  fi
  ok "destroyed: $name"
}

# Truncate matching log files in place (keep the inode so running daemons keep
# their open handles — rm would orphan the file until restart). Prints the count
# truncated; silently skips any file we can't write. nginx logs are user-owned
# (pre-created by nginx_ensure_logs), so no sudo is involved.
_logs_truncate() {
  local f n=0
  for f in "$@"; do
    [ -f "$f" ] && [ -w "$f" ] || continue
    : > "$f"; n=$((n + 1))
  done
  printf '%s' "$n"
}

# harbor logs clear [all|nginx|php|dnsmasq|<name>]
_logs_clear() {
  local target="${1:-all}" n
  case "$target" in
    all)      n="$(_logs_truncate "$HARBOR_LOG_DIR"/*.log)" ;;
    nginx)    n="$(_logs_truncate "$HARBOR_LOG_DIR"/nginx-*.log "$HARBOR_LOG_DIR"/site-*.log)" ;;
    php)      n="$(_logs_truncate "$HARBOR_LOG_DIR"/php-*.log)" ;;
    dnsmasq)  n="$(_logs_truncate "$HARBOR_LOG_DIR"/dnsmasq.log)" ;;
    *) require_name "$target"; n="$(_logs_truncate "$HARBOR_LOG_DIR"/site-"$target".*.log)" ;;
  esac
  ok "cleared $n log file(s) ($target)"
}

cmd_logs() {
  case "${1-}" in
    clear)   shift; _logs_clear "${1-}" ;;
    nginx)   shift; tail -n 200 ${1:+-F} "$HARBOR_LOG_DIR"/nginx-*.log 2>/dev/null || warn "no nginx logs yet" ;;
    php)     shift; tail -n 200 ${1:+-F} "$HARBOR_LOG_DIR"/php-*.log 2>/dev/null || warn "no php logs yet" ;;
    dnsmasq) shift; tail -n 200 ${1:+-F} "$HARBOR_LOG_DIR"/dnsmasq.log 2>/dev/null || warn "no dnsmasq log yet" ;;
    *) resolve_project "${1-}" "harbor logs [<name>] | nginx|php|dnsmasq | clear [target]"
       [ "$_RP_SHIFT" = 1 ] && shift; local name="$_RP_NAME"
       # See cmd_up: bulk lifecycle commands no-op on a service-less project
       # rather than refusing.
       if ! project_has_stack "$name"; then
         step "no container logs for '$name' (no services)"; return 0
       fi
       project_compose "$name" logs --tail=200 "$@" ;;
  esac
}
