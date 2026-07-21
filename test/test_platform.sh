#!/usr/bin/env bash
# test_platform.sh — compose `platform:` pinning (lib/common.sh).
#
# Docker silently reuses a cached foreign-arch image, so an amd64 database kept
# running under emulation on Apple Silicon long after an arm64 build existed
# upstream — correct, but far slower, and the only symptom was a one-line
# warning at `up`. Pinning platform in the rendered compose makes the pull
# explicit; these pin the precedence chain and the `none` escape hatch.
#
# NOTE: config overrides go in a per-call env prefix, never a `( … )` subshell.
# PASS/FAIL are plain variables, so a subshell's assertions never reach report()
# — the file would tally 1 and run.sh would exit 0 even with failures inside.
set -uo pipefail
. "$HARBOR_TEST_DIR/lib.sh"
harbor_load common

tmp="$(mktemp -d)"
cfg="$tmp/config"
trap 'rm -rf "$tmp"' EXIT

# --- host_platform maps uname -m to a docker platform string -----------------
# Whatever this host is, the answer must be something Docker understands (or
# empty — an unrecognised arch yields no pin rather than a guess).
case "$(host_platform)" in
  linux/arm64|linux/amd64|"") pass "host: yields a docker platform or nothing" ;;
  *) fail "host: unexpected platform string '$(host_platform)'" ;;
esac

# --- precedence: <SVC>_PLATFORM -> DOCKER_PLATFORM -> host arch --------------
: > "$cfg"
assert_eq "default: falls back to the host arch" \
  "$(host_platform)" "$(HARBOR_CONFIG="$cfg" service_platform mysql)"

printf 'DOCKER_PLATFORM=linux/amd64\n' > "$cfg"
assert_eq "global override applies to the db" \
  "linux/amd64" "$(HARBOR_CONFIG="$cfg" service_platform mysql)"
assert_eq "global override applies to every other service too" \
  "linux/amd64" "$(HARBOR_CONFIG="$cfg" service_platform opensearch)"

# per-service beats global — the case that matters when exactly ONE image lacks
# an arm64 build and the rest of the stack should stay native
printf 'DOCKER_PLATFORM=linux/arm64\nMYSQL_PLATFORM=linux/amd64\n' > "$cfg"
assert_eq "per-service override beats the global" \
  "linux/amd64" "$(HARBOR_CONFIG="$cfg" service_platform mysql)"
assert_eq "other services keep the global" \
  "linux/arm64" "$(HARBOR_CONFIG="$cfg" service_platform rabbitmq)"

# the config key is the UPPERCASED service name + _PLATFORM, mirroring _IMAGE
printf 'ELASTICSEARCH_PLATFORM=linux/amd64\n' > "$cfg"
assert_eq "key is uppercased service name + _PLATFORM" \
  "linux/amd64" "$(HARBOR_CONFIG="$cfg" service_platform elasticsearch)"

# --- `none` disables the pin -------------------------------------------------
# The escape hatch for an image with no host-arch build (mysql:5.7 is amd64
# only). Unpinned, Docker emulates: slow but working. A pin it cannot satisfy
# fails the pull outright, which is strictly worse.
printf 'MYSQL_PLATFORM=none\n' > "$cfg"
assert_eq "none disables the pin for that service" \
  "" "$(HARBOR_CONFIG="$cfg" service_platform mysql)"
assert_eq "none does not leak to other services" \
  "$(host_platform)" "$(HARBOR_CONFIG="$cfg" service_platform opensearch)"
assert_eq "none renders no compose line" \
  "" "$(HARBOR_CONFIG="$cfg" service_platform_line mysql)"

printf 'DOCKER_PLATFORM=none\n' > "$cfg"
assert_eq "global none disables every pin" \
  "" "$(HARBOR_CONFIG="$cfg" service_platform meilisearch)"

# --- the rendered line -------------------------------------------------------
printf 'DOCKER_PLATFORM=linux/arm64\n' > "$cfg"
line="$(HARBOR_CONFIG="$cfg" service_platform_line mysql)"
# It is appended to the `image:` line, so it must carry its OWN leading newline.
# Without it the platform key lands on the same line as the image tag and docker
# compose rejects the file.
assert_eq "line starts with a newline" "" "$(printf '%s' "$line" | head -1)"
assert_contains "line is an indented platform: key" '    platform: linux/arm64' "$line"
# exactly one content line — a stray blank line inside a service block would be
# harmless, but a second key would not be
assert_eq "line has one platform key" "1" \
  "$(printf '%s' "$line" | grep -c 'platform:' | tr -d ' ')"

# --- safe as bare statements in a render's env prefix ------------------------
# Both run unguarded in init_render_compose/shared_render/sandbox_render, where
# a nonzero return aborts the entire render under set -e. CLAUDE.md §3.
# HARBOR_CONFIG must be set AFTER the lib is sourced — common.sh assigns it
# unconditionally, so an env prefix on the `bash -c` itself is overwritten and
# every case below would silently exercise the pinned path.
_returns_ok() { # <config body> <fn>
  printf '%s\n' "$1" > "$cfg"
  bash -c "HARBOR_ROOT='$HARBOR_ROOT'
           . '$HARBOR_ROOT/lib/common.sh'
           HARBOR_CONFIG='$cfg'
           $2 mysql >/dev/null"
}
assert_ok "unpinned: service_platform returns 0"      _returns_ok 'MYSQL_PLATFORM=none' service_platform
assert_ok "unpinned: service_platform_line returns 0" _returns_ok 'MYSQL_PLATFORM=none' service_platform_line
assert_ok "pinned: service_platform returns 0"        _returns_ok '' service_platform
assert_ok "pinned: service_platform_line returns 0"   _returns_ok '' service_platform_line

report
