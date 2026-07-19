#!/usr/bin/env bash
# test_nginx.sh — log-precreation semantics (lib/nginx.sh nginx_ensure_logs_all).
# Regression suite for the silent-death bug: a site conf whose log paths can't
# be parsed (or a conf with no log directives at all) must never make
# nginx_ensure_logs_all return nonzero, or `set -e` kills `harbor setup` with no
# error output. Pure filesystem work — no nginx, no launchd, no sudo.
set -uo pipefail
. "$HARBOR_TEST_DIR/lib.sh"
harbor_load common nginx

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# point every path Harbor writes at the throwaway dir
HARBOR_VAR="$tmp/var"
HARBOR_ETC="$tmp/etc"
HARBOR_RUN="$HARBOR_VAR/run"
HARBOR_LOG_DIR="$HARBOR_VAR/log"
HARBOR_PORTS_DIR="$HARBOR_VAR/ports"
HARBOR_LOCK_DIR="$HARBOR_VAR/lock"
HARBOR_CERTS="$tmp/certs"
HARBOR_NGINX_SITES="$HARBOR_ETC/nginx/sites"
mkdir -p "$HARBOR_NGINX_SITES"

# run it the way nginx_setup/nginx_reload do — a plain call under set -e — so a
# poisoned return value surfaces as the silent death it causes in production.
ensure_logs_errexit() { ( set -e; nginx_ensure_logs_all; echo SURVIVED ) 2>/dev/null; }

# --- baseline: the global logs are always created ---------------------------
assert_ok "no site confs: returns 0" nginx_ensure_logs_all
assert_ok "global error log created" test -f "$HARBOR_LOG_DIR/nginx-error.log"
assert_ok "global access log created" test -f "$HARBOR_LOG_DIR/nginx-access.log"

# --- a conf WITH log directives gets its logs pre-created, user-owned --------
cat > "$HARBOR_NGINX_SITES/demo.test.conf" <<EOF
server {
    access_log $HARBOR_LOG_DIR/site-demo.access.log;
    error_log  $HARBOR_LOG_DIR/site-demo.error.log;
}
EOF
assert_ok "conf with logs: returns 0" nginx_ensure_logs_all
assert_ok "site access log created" test -f "$HARBOR_LOG_DIR/site-demo.access.log"
assert_ok "site error log created" test -f "$HARBOR_LOG_DIR/site-demo.error.log"

# --- a conf with NO log directives is inert, not fatal ----------------------
# This is the regression: `[ -n "$logs" ] && …` as the loop body's last
# statement made the empty case the function's return value (CLAUDE.md §3).
printf 'server {\n    listen 80;\n}\n' > "$HARBOR_NGINX_SITES/zz-nologs.test.conf"
assert_ok "conf without logs: returns 0" nginx_ensure_logs_all
assert_contains "conf without logs under set -e does not kill setup" \
  SURVIVED "$(ensure_logs_errexit)"

# --- an existing log is left alone (never truncated, never re-created) ------
echo keepme > "$HARBOR_LOG_DIR/site-demo.access.log"
nginx_ensure_logs_all
assert_eq "existing log is not truncated" keepme "$(cat "$HARBOR_LOG_DIR/site-demo.access.log")"

report
