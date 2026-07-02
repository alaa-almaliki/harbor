#!/usr/bin/env bash
# ergo.sh — ergonomics: consoles, open, ps/list, status (+ self-heal), secure, mail.

_port_listening() { lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }

cmd_open() {
  require_name "${1-}"; local name="$1"
  open "https://$name.$HARBOR_TLD" 2>/dev/null || echo "https://$name.$HARBOR_TLD"
}

cmd_mysql() {
  require_name "${1-}"; local name="$1"; shift || true
  _db_load "$name"; _db_up_check "$name"
  project_compose "$name" exec -e MYSQL_PWD="$DB_ROOT_PASSWORD" mysql mysql -uroot "$(db_ident "$name")" "$@"
}

cmd_redis() {
  require_name "${1-}"; local name="$1"; shift || true
  ports_load "$name" || die "not initialized: $name"
  docker exec -it "$HARBOR_SHARED_REDIS" redis-cli -n "$REDIS_DB_CACHE" "$@"
}

cmd_shell() {
  require_name "${1-}"; local name="$1"
  _project_run_env "$name"; local dir="$_PR_DIR" v="$_PR_VER" phpdir="$_PR_PHPDIR"
  log "shell in $dir (php $v + .harbor/scripts on PATH; exit to leave)"
  ( cd "$dir" && PATH="$(project_run_path "$phpdir" "$dir")" HARBOR_PROJECT="$name" "${SHELL:-/bin/bash}" )
}

# harbor secure [host...] — reissue cert (add SAN hosts), reload nginx
cmd_secure() {
  if [ $# -gt 0 ]; then
    # shellcheck disable=SC2068
    tls_add_sans $@ >/dev/null
  else
    tls_setup >/dev/null
  fi
  nginx_reload
  ok "certificate reissued"
}

cmd_mail() {
  case "${1-}" in
    up)   shared_up ;;
    down) shared_down ;;
    *)    open "http://localhost:8025" 2>/dev/null || echo "http://localhost:8025" ;;
  esac
}

# list all projects with state
cmd_ps() {
  ensure_dirs
  printf '%-16s %-11s %-5s %-6s %-6s %s\n' PROJECT FRAMEWORK PHP STACK LINKED PORTS
  local d name mf fw php stack linked dbp
  for d in "$HARBOR_PROJECTS"/*/; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"; [ "$name" = "*" ] && continue
    mf="$(manifest_path "$name")"; [ -f "$mf" ] || continue
    fw="$(manifest_get "$mf" framework "?")"
    php="$(manifest_get "$mf" php "?")"
    if [ -f "$(project_compose_file "$name")" ] && project_compose "$name" ps -q 2>/dev/null | grep -q .; then stack=up; else stack=down; fi
    [ -f "$HARBOR_NGINX_SITES/$name.$HARBOR_TLD.conf" ] && linked=yes || linked=no
    dbp=""; ports_load "$name" 2>/dev/null && dbp="db:$DB_PORT"
    printf '%-16s %-11s %-5s %-6s %-6s %s\n' "$name" "$fw" "$php" "$stack" "$linked" "$dbp"
  done
}

# overall status + self-heal dead com.harbor.* units
cmd_status() {
  printf '%sHarbor status%s\n' "$_c_blu" "$_c_reset"
  if [ -f "$HARBOR_STOPPED" ]; then
    warn "Harbor is STOPPED (paused) — resume with: harbor start"
    return 0
  fi
  printf 'default php : %s   xdebug: %s\n\n' "$(default_php)" "$(xdebug_state)"

  printf 'services:\n'
  local label heal=0
  # nginx: probe the port (no sudo needed to read daemon status)
  if _port_listening 443; then printf '  %-22s up (:80/:443)\n' "$HARBOR_LD_PREFIX.nginx"; else
    printf '  %-22s DOWN -> harbor setup\n' "$HARBOR_LD_PREFIX.nginx"; heal=1; fi
  # dnsmasq: user agent + resolve probe
  label="$HARBOR_LD_PREFIX.dnsmasq"
  if launchd_agent_loaded "$label"; then printf '  %-22s loaded (:%s)\n' "$label" "$(dns_port)"; else
    printf '  %-22s DEAD -> reloading\n' "$label"; launchd_agent_load "$label"; heal=1; fi
  local v
  for v in $(installed_php_versions); do
    label="$(php_ld_label "$v")"
    if launchd_agent_loaded "$label"; then printf '  %-22s loaded\n' "$label"; else
      printf '  %-22s DEAD -> reloading\n' "$label"; launchd_kickstart "$label"; heal=1; fi
  done
  if docker exec "$HARBOR_SHARED_REDIS" true >/dev/null 2>&1; then printf '  %-22s up\n' "shared redis"; else printf '  %-22s DOWN (harbor mail up)\n' "shared redis"; fi
  if curl -sf -o /dev/null http://127.0.0.1:8025 2>/dev/null; then printf '  %-22s up\n' "shared mailpit"; else printf '  %-22s DOWN (harbor mail up)\n' "shared mailpit"; fi
  [ "$heal" = 1 ] && warn "self-healed one or more dead units"

  printf '\nprojects:\n'
  cmd_ps | sed 's/^/  /'
}
