#!/usr/bin/env bash
# nginx.sh — Harbor's own nginx (own nginx.conf, LaunchDaemon for :80/:443).
# Nothing is written into brew's nginx dir. Per-site vhosts arrive in Phase 4.

nginx_bin() { command -v nginx; }

nginx_render_conf() {
  mkdir -p "$HARBOR_NGINX_SITES"
  USER="$HARBOR_USER" \
  GROUP="$HARBOR_GROUP" \
  PID="$HARBOR_RUN/nginx.pid" \
  LOG_DIR="$HARBOR_LOG_DIR" \
  BREW_PREFIX="$BREW_PREFIX" \
  SITES="$HARBOR_NGINX_SITES" \
  CERT="$HARBOR_CERT" \
  CERT_KEY="$HARBOR_CERT_KEY" \
  render "$HARBOR_TEMPLATES/nginx/nginx.conf.tmpl" "$HARBOR_NGINX_CONF"
}

nginx_test() {
  # Run as root: this nginx binds listen sockets during -t, and :80/:443 are
  # privileged; root also validates the `user` directive without a warning.
  local nbin; nbin="$(nginx_bin)" || die "nginx not found"
  step "validating nginx config (sudo — binds :80/:443 during -t)"
  sudo "$nbin" -t -c "$HARBOR_NGINX_CONF" 2>&1 | sed 's/^/   nginx: /'
}

nginx_setup() {
  local nbin label tmp
  nbin="$(nginx_bin)" || die "nginx not found (brew install nginx)"
  nginx_render_conf
  nginx_test || die "nginx config test failed"
  label="$HARBOR_LD_PREFIX.nginx"
  tmp="$HARBOR_RUN/$label.plist"
  LABEL="$label" NGINX_BIN="$nbin" NGINX_CONF="$HARBOR_NGINX_CONF" \
    LOG="$HARBOR_LOG_DIR/nginx.launchd.log" \
    render "$HARBOR_TEMPLATES/launchd/nginx.plist.tmpl" "$tmp"
  launchd_daemon_install "$label" "$tmp"
  rm -f "$tmp"
  step "nginx LaunchDaemon installed (:80/:443)"
}

# reload after a vhost change (Phase 4+)
nginx_reload() {
  local nbin; nbin="$(nginx_bin)" || die "nginx not found"
  nginx_test || die "nginx config test failed"
  log "reloading nginx (sudo — signals the root LaunchDaemon on :80/:443)"
  sudo "$nbin" -s reload -c "$HARBOR_NGINX_CONF" 2>/dev/null \
    || launchd_kickstart "$HARBOR_LD_PREFIX.nginx" || true
}

nginx_teardown() {
  launchd_daemon_remove "$HARBOR_LD_PREFIX.nginx"
  rm -f "$HARBOR_NGINX_CONF"
}
