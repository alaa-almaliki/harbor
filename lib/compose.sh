#!/usr/bin/env bash
# compose.sh — shared stack lifecycle (Mailpit + Redis). Per-project stacks: Phase 5.

HARBOR_SHARED_COMPOSE="$HARBOR_DOCKER/docker-compose.yml"
HARBOR_SHARED_REDIS="harbor-shared-redis-1"   # container name from shared.yml (name: harbor-shared)

shared_render() {
  mkdir -p "$HARBOR_DOCKER"
  render "$HARBOR_TEMPLATES/compose/shared.yml.tmpl" "$HARBOR_SHARED_COMPOSE"
}

shared_up() {
  shared_render
  docker info >/dev/null 2>&1 || die "docker daemon not running — start Docker/OrbStack"
  step "starting shared stack (mailpit :1025/:8025 + redis :6379)"
  docker compose -f "$HARBOR_SHARED_COMPOSE" up -d >/dev/null
}

shared_down() {
  [ -f "$HARBOR_SHARED_COMPOSE" ] || return 0
  docker compose -f "$HARBOR_SHARED_COMPOSE" down >/dev/null 2>&1 || true
}

# ── per-project stacks ──────────────────────────────────────────────────────
project_compose_file() { printf '%s' "$(project_harbor_dir "$1")/docker-compose.yml"; }

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
      [ -f "$frag" ] && render_str "$frag"
    done
  fi
}

project_compose() {
  local name="$1"; shift
  local f; f="$(project_compose_file "$name")"
  [ -f "$f" ] || die "no stack for '$name' — run: harbor init $name"
  docker compose -f "$f" "$@"
}

# block until all containers with a healthcheck report healthy
_wait_ready() {
  local name="$1" max="${2:-90}" i=0 ids st pend
  ids="$(project_compose "$name" ps -q 2>/dev/null)" || return 0
  [ -n "$ids" ] || return 0
  printf '   waiting for services to be healthy'
  local states
  while [ "$i" -lt "$max" ]; do
    # one docker inspect for all containers; a container with no healthcheck -> "none"
    # shellcheck disable=SC2086
    states="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' $ids 2>/dev/null)"
    pend=""
    for st in $states; do
      case "$st" in healthy|none) : ;; *) pend="x" ;; esac
    done
    [ -z "$pend" ] && { printf ' ready\n'; return 0; }
    printf '.'; i=$((i + 1)); sleep 2
  done
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
  docker info >/dev/null 2>&1 || die "docker daemon not running — start Docker/OrbStack"
  log "starting stack: $name"
  project_compose "$name" up -d
  _wait_ready "$name" || true
  ok "up: $name ($(project_harbor_dir "$name")/connection.txt has the details)"
}

cmd_down() {
  require_name "${1-}"; local name="$1"
  log "stopping stack: $name (flushing its Redis indices)"
  redis_flush_project "$name"
  project_compose "$name" down
  ok "down: $name (MySQL data kept; use 'harbor destroy' to drop volumes)"
}

cmd_restart() {
  require_name "${1-}"; local name="$1"
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

cmd_logs() {
  case "${1-}" in
    nginx)   shift; tail -n 200 ${1:+-F} "$HARBOR_LOG_DIR"/nginx-*.log 2>/dev/null || warn "no nginx logs yet" ;;
    php)     shift; tail -n 200 ${1:+-F} "$HARBOR_LOG_DIR"/php-*.log 2>/dev/null || warn "no php logs yet" ;;
    dnsmasq) shift; tail -n 200 ${1:+-F} "$HARBOR_LOG_DIR"/dnsmasq.log 2>/dev/null || warn "no dnsmasq log yet" ;;
    *) require_name "${1-}"; local name="$1"; shift || true
       project_compose "$name" logs --tail=200 "$@" ;;
  esac
}
