#!/usr/bin/env bash
# compose.sh — shared stack lifecycle (Mailpit + Redis). Per-project stacks: Phase 5.

HARBOR_SHARED_COMPOSE="$HARBOR_DOCKER/docker-compose.yml"
HARBOR_SHARED_REDIS="harbor-shared-redis-1"   # container name from shared.yml (name: harbor-shared)

# die unless the Docker daemon is reachable (shared by every stack that shells to
# `docker compose` — shared, per-project, and the sandbox)
require_docker() { docker info >/dev/null 2>&1 || die "docker daemon not running — start Docker/OrbStack"; }

shared_render() {
  mkdir -p "$HARBOR_DOCKER"
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
  require_name "${1-}"; local name="$1"
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
  require_name "${1-}"; local name="$1"
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

cmd_destroy() {
  require_name "${1-}"; local name="$1"; shift || true
  local files=0; [ "${1-}" = "--files" ] && files=1
  confirm "Destroy '$name' (drop containers + volumes + ports + vhost)?" || { warn "aborted"; return 1; }
  redis_flush_project "$name"
  [ -f "$(project_compose_file "$name")" ] && project_compose "$name" down -v >/dev/null 2>&1 || true
  cmd_unlink "$name" >/dev/null 2>&1 || true
  ports_release "$name"
  if [ "$files" = 1 ]; then rm -rf "$(project_dir "$name")"; warn "deleted $(project_dir "$name")"; fi
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
    *) require_name "${1-}"; local name="$1"; shift || true
       # See cmd_up: bulk lifecycle commands no-op on a service-less project
       # rather than refusing.
       if ! project_has_stack "$name"; then
         step "no container logs for '$name' (no services)"; return 0
       fi
       project_compose "$name" logs --tail=200 "$@" ;;
  esac
}
