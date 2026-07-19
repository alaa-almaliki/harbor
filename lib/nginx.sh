#!/usr/bin/env bash
# nginx.sh — Harbor's own nginx (own nginx.conf, LaunchDaemon for :80/:443).
# Nothing is written into brew's nginx dir. Per-site vhosts arrive in Phase 4.

nginx_bin() { command -v nginx; }

# Pre-create nginx log files owned by the invoking user. nginx's root master
# open()s logs with O_APPEND|O_CREAT and never chowns an existing file, so a
# born-user-owned log stays ours after nginx (re)opens it on start/reload — root
# still writes to it, but WE can truncate it (`harbor logs clear`) without sudo.
# Only creates missing files; a pre-existing root-owned log is left as-is.
nginx_ensure_logs() {
  local f
  for f in "$@"; do [ -e "$f" ] || : > "$f"; done
}

# ensure the global + every linked site's log files exist (user-owned), parsing
# the log paths straight out of each rendered site conf.
nginx_ensure_logs_all() {
  ensure_dirs
  nginx_ensure_logs "$HARBOR_LOG_DIR/nginx-error.log" "$HARBOR_LOG_DIR/nginx-access.log"
  local c logs
  for c in "$HARBOR_NGINX_SITES"/*.conf; do
    [ -f "$c" ] || continue
    logs="$(awk '/(access|error)_log[[:space:]]/{print $2}' "$c" | tr -d ';')"
    # NOT `[ -n "$logs" ] && …` — as the last statement in the loop body a false
    # guard becomes the function's return value, and a plain caller under set -e
    # dies silently with no output (see CLAUDE.md §3, test_db.sh).
    if [ -n "$logs" ]; then
      # shellcheck disable=SC2086
      nginx_ensure_logs $logs
    fi
  done
}

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
  # pre-create logs (incl. the launchd stdout) user-owned before the root daemon opens them
  nginx_ensure_logs_all
  nginx_ensure_logs "$HARBOR_LOG_DIR/nginx.launchd.log"
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
  nginx_ensure_logs_all   # so any new/removed site log is reopened user-owned
  nginx_test || die "nginx config test failed"
  log "reloading nginx (sudo — signals the root LaunchDaemon on :80/:443)"
  sudo "$nbin" -s reload -c "$HARBOR_NGINX_CONF" 2>/dev/null \
    || launchd_kickstart "$HARBOR_LD_PREFIX.nginx" || true
}

nginx_teardown() {
  launchd_daemon_remove "$HARBOR_LD_PREFIX.nginx"
  rm -f "$HARBOR_NGINX_CONF"
}
