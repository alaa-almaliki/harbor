#!/usr/bin/env bash
# setup.sh — one-time host prep + teardown. Idempotent. Harbor-owned; brew config
# is never touched. Sudo only for the nginx LaunchDaemon and /etc/resolver/test.

config_init() {
  [ -f "$HARBOR_CONFIG" ] && return 0
  mkdir -p "$(dirname "$HARBOR_CONFIG")"
  cat > "$HARBOR_CONFIG" <<EOF
# Harbor global config (KEY=VALUE). Per-project manifest overrides these.
DEFAULT_PHP=$HARBOR_DEFAULT_PHP
DNS_PORT=$HARBOR_DNS_PORT
PHP_MEMORY_LIMIT=2G
LOCALE=en_US
CURRENCY=USD
TIMEZONE=UTC
ADMIN_USER=admin
ADMIN_PASSWORD=Admin123!
MYSQL_ROOT_PASSWORD=root
MYSQL_IMAGE=mysql:8.0
OPENSEARCH_HEAP=512m
EOF
  step "wrote global config -> $HARBOR_CONFIG"
}

cmd_setup() {
  log "harbor setup — preparing host (Harbor-owned; brew config untouched)"
  if ! cmd_doctor; then
    die "resolve the required items above first (e.g. 'mkcert -install'), then re-run: harbor setup"
  fi
  ensure_dirs
  config_init
  log "TLS (wildcard cert + CA bundle)"; tls_setup
  log "DNS (own dnsmasq + resolver)";    dns_setup
  log "PHP pools (ondemand, per version)"; php_setup_pools
  log "nginx (own config + LaunchDaemon)"; nginx_setup
  log "shared stack (mailpit + redis)";  shared_up
  ok "harbor setup complete"
  cat <<EOF

Next:
  harbor doctor            # should now be all green
  harbor php               # (Phase 3) pool status / Xdebug
  harbor link <name>       # (Phase 4) serve a project at https://<name>.test
EOF
}

# pause Harbor so its ports (:80/:443/:6379/:1025/:8025) are free for another
# stack. Keeps plists, resolver, and certs — resume instantly with `harbor start`.
cmd_stop() {
  log "stopping Harbor (frees :80 :443 :6379 :1025 :8025 for Docker)"
  : > "$HARBOR_STOPPED"
  step "shared stack (redis + mailpit) down"; shared_down
  local v
  for v in $(installed_php_versions); do launchd_agent_unload "$(php_ld_label "$v")"; done
  step "php pools stopped"
  launchd_agent_unload "$HARBOR_LD_PREFIX.dnsmasq"; step "dnsmasq stopped"
  log "stopping nginx (sudo)"; launchd_daemon_stop "$HARBOR_LD_PREFIX.nginx"
  ok "Harbor stopped. Running project stacks (if any) use high ports (20000+) and are left alone — 'harbor down <name>' to stop those too."
  step "resume with: harbor start"
}

cmd_start() {
  [ -f "$(daemon_plist "$HARBOR_LD_PREFIX.nginx")" ] || die "Harbor not set up yet — run: harbor setup"
  log "starting Harbor (ensure other stacks freed :80/:443/:6379/1025/8025 first)"
  rm -f "$HARBOR_STOPPED"
  local v
  for v in $(installed_php_versions); do launchd_agent_load "$(php_ld_label "$v")"; done
  step "php pools started"
  launchd_agent_load "$HARBOR_LD_PREFIX.dnsmasq"; step "dnsmasq started"
  log "starting nginx (sudo)"; launchd_daemon_start "$HARBOR_LD_PREFIX.nginx" || warn "nginx failed to start — is :80/:443 free?"
  shared_up
  ok "Harbor started — https://<name>.test back online"
}

cmd_teardown() {
  local purge=0
  [ "${1-}" = "--purge" ] && purge=1
  if ! confirm "Tear down Harbor (stop services, remove launchd units + resolver)?"; then
    warn "aborted"; return 1
  fi
  log "removing nginx LaunchDaemon"; nginx_teardown
  log "removing dnsmasq + resolver";  dns_teardown
  log "removing php pools";           php_remove_pools
  log "stopping shared stack";        shared_down
  log "stopping sandbox MySQL";       sandbox_down
  if [ "$purge" = "1" ]; then
    HARBOR_YES=1 sandbox_destroy >/dev/null 2>&1 || true
    rm -rf "$HARBOR_ETC"
    tls_teardown
    rm -f "$HARBOR_RUN"/*.sock "$HARBOR_RUN"/*.pid
    warn "purged rendered config + certs"
  fi
  ok "teardown complete — brew nginx/php/dnsmasq untouched"
}
