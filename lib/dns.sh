#!/usr/bin/env bash
# dns.sh — Harbor's own dnsmasq instance (loopback, port 5354) resolving *.test,
# plus the macOS resolver hook. Brew's dnsmasq.conf is never touched.

dns_port() { config_get DNS_PORT "$HARBOR_DNS_PORT"; }

dns_setup() {
  local dnsbin label tmp port
  dnsbin="$(command -v dnsmasq)" || die "dnsmasq not found (brew install dnsmasq)"
  port="$(dns_port)"
  mkdir -p "$HARBOR_ETC/dnsmasq"
  DNS_PORT="$port" TLD="$HARBOR_TLD" \
    render "$HARBOR_TEMPLATES/dnsmasq/harbor.conf.tmpl" "$HARBOR_DNSMASQ_CONF"

  label="$HARBOR_LD_PREFIX.dnsmasq"
  tmp="$HARBOR_RUN/$label.plist"
  LABEL="$label" DNSMASQ_BIN="$dnsbin" DNSMASQ_CONF="$HARBOR_DNSMASQ_CONF" \
    LOG="$HARBOR_LOG_DIR/dnsmasq.log" \
    render "$HARBOR_TEMPLATES/launchd/dnsmasq.plist.tmpl" "$tmp"
  launchd_agent_install "$label" "$tmp"
  rm -f "$tmp"
  step "dnsmasq on 127.0.0.1:$port resolving *.$HARBOR_TLD"

  dns_write_resolver "$port"
}

dns_write_resolver() {
  local port="$1" file="/etc/resolver/$HARBOR_TLD"
  if [ -f "$file" ] && grep -q "^port $port$" "$file" 2>/dev/null; then
    step "/etc/resolver/$HARBOR_TLD already configured"
    return 0
  fi
  log "writing $file (sudo — macOS DNS hook for *.$HARBOR_TLD)"
  sudo mkdir -p /etc/resolver
  printf 'nameserver 127.0.0.1\nport %s\n' "$port" | sudo tee "$file" >/dev/null
}

dns_teardown() {
  launchd_agent_remove "$HARBOR_LD_PREFIX.dnsmasq"
  if [ -f "/etc/resolver/$HARBOR_TLD" ]; then
    log "removing /etc/resolver/$HARBOR_TLD (sudo)"
    sudo rm -f "/etc/resolver/$HARBOR_TLD"
  fi
}
