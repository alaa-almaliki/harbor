#!/usr/bin/env bash
# test_magento.sh — magento_require_services: pure-logic guard for the three
# services (mysql, opensearch, rabbitmq) Magento needs. Host-independent: it
# only reads the manifest via project_has_service — no Docker, no compose
# file, no launchd — a pure-logic function per CLAUDE.md §6.5.
set -uo pipefail
. "$HARBOR_TEST_DIR/lib.sh"
harbor_load common manifest services init magento

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export HARBOR_PROJECTS="$tmp/projects"

mkproj() {  # mkproj <name> <services-line-or-empty>
  mkdir -p "$tmp/projects/$1/.harbor"
  { printf 'framework: magento\nphp: "8.3"\n'
    if [ -n "${2-}" ]; then printf '%s\n' "$2"; fi
  } > "$tmp/projects/$1/.harbor/harbor.yml"
}
mkproj full    'services: { mysql: "mysql:8.0", opensearch: "os:2", rabbitmq: "rabbitmq:3.13" }'
mkproj none    'services: {}'
mkproj partial 'services: { mysql: "mysql:8.0" }'
mkproj norabbit 'services: { mysql: "mysql:8.0", opensearch: "os:2" }'

# --- exit status -----------------------------------------------------------
# RabbitMQ is OPTIONAL for Magento: only mysql + opensearch are required.
assert_ok   "magento_require_services: all three present -> ok"    magento_require_services full
assert_ok   "magento_require_services: mysql+opensearch (no rabbitmq) -> ok" magento_require_services norabbit
assert_fail "magento_require_services: none present -> fails"      magento_require_services none
assert_fail "magento_require_services: opensearch missing -> fails" magento_require_services partial

# --- message content: names ALL missing REQUIRED services, not just the first --
# (real failure mode this guards against: an off-by-one/early-exit in the
# accumulation loop reporting only the first missing service it hits)
out_none="$( (magento_require_services none) 2>&1 1>/dev/null )"
assert_contains "none: message names mysql"      "mysql"      "$out_none"
assert_contains "none: message names opensearch" "opensearch" "$out_none"
case "$out_none" in
  *"rabbitmq"*) fail "none: message does not demand rabbitmq (optional)" \
    "no 'rabbitmq'" "$out_none" ;;
  *) pass "none: message does not demand rabbitmq (optional)" ;;
esac

out_partial="$( (magento_require_services partial) 2>&1 1>/dev/null )"
assert_contains "partial: message names opensearch" "opensearch" "$out_partial"
case "$out_partial" in
  *"mysql"*) fail "partial: message does not re-list mysql (already present)" \
    "no 'mysql'" "$out_partial" ;;
  *) pass "partial: message does not re-list mysql (already present)" ;;
esac

# --- which stream: the error must reach stderr, not stdout ------------------
# (regression: an earlier bug had a guard's step() fix-hints captured by a
# caller's command substitution because they went to stdout — see
# lib/install.sh's cmd_install magento branch for the workaround)
stdout_out="$( (magento_require_services none) 2>/dev/null )"
assert_contains "none: error reaches stderr" "magento needs:" "$out_none"
case "$stdout_out" in
  *"magento needs:"*) fail "none: error does not leak to stdout" \
    "no 'magento needs:' on stdout" "$stdout_out" ;;
  *) pass "none: error does not leak to stdout" ;;
esac

report
