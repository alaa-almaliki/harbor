#!/usr/bin/env bash
# test_ports.sh — per-project port + Redis-index allocation (lib/ports.sh).
# Uses a throwaway HARBOR_PORTS_DIR/HARBOR_LOCK_DIR; never touches real state.
set -uo pipefail
. "$HARBOR_TEST_DIR/lib.sh"
harbor_load common ports

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export HARBOR_PORTS_DIR="$tmp/ports"
export HARBOR_LOCK_DIR="$tmp/lock"
mkdir -p "$HARBOR_PORTS_DIR" "$HARBOR_LOCK_DIR"

# Read one KEY from a written ports file.
val() { grep -E "^$2=" "$(ports_file "$1")" | cut -d= -f2; }

# --- _ports_write: deterministic math from the index -------------------------
# base = 20000 + idx*20 ; redis block = idx*4
_ports_write demo 0
assert_eq "ports: idx0 DB_PORT"        "20000" "$(val demo DB_PORT)"
assert_eq "ports: idx0 OPENSEARCH"     "20001" "$(val demo OPENSEARCH_PORT)"
assert_eq "ports: idx0 RABBITMQ"       "20002" "$(val demo RABBITMQ_PORT)"
assert_eq "ports: idx0 RABBITMQ_UI"    "20003" "$(val demo RABBITMQ_UI_PORT)"
assert_eq "ports: idx0 MEILI"          "20004" "$(val demo MEILI_PORT)"
assert_eq "ports: idx0 ELASTIC"        "20005" "$(val demo ELASTIC_PORT)"
assert_eq "ports: idx0 REDIS cache"    "0"     "$(val demo REDIS_DB_CACHE)"
assert_eq "ports: idx0 REDIS spare"    "3"     "$(val demo REDIS_DB_SPARE)"

_ports_write other 3
assert_eq "ports: idx3 base"           "20060" "$(val other HARBOR_PORT_BASE)"
assert_eq "ports: idx3 DB_PORT"        "20060" "$(val other DB_PORT)"
assert_eq "ports: idx3 RABBITMQ"       "20062" "$(val other RABBITMQ_PORT)"
assert_eq "ports: idx3 REDIS cache"    "12"    "$(val other REDIS_DB_CACHE)"
assert_eq "ports: idx3 REDIS session"  "14"    "$(val other REDIS_DB_SESSION)"

# --- _ports_max_index --------------------------------------------------------
assert_eq "ports: max index across files" "3" "$(_ports_max_index)"

# --- ports_allocate: sequential + idempotent ---------------------------------
rm -rf "$HARBOR_PORTS_DIR"; mkdir -p "$HARBOR_PORTS_DIR"
ports_allocate alpha >/dev/null
ports_allocate beta  >/dev/null
assert_eq "ports_allocate: first project idx 0" "0" "$(val alpha HARBOR_INDEX)"
assert_eq "ports_allocate: second project idx 1" "1" "$(val beta HARBOR_INDEX)"
assert_eq "ports_allocate: alpha base"  "20000" "$(val alpha DB_PORT)"
assert_eq "ports_allocate: beta base"   "20020" "$(val beta DB_PORT)"

# Re-allocating an existing project must not change its index (idempotent).
ports_allocate alpha >/dev/null
assert_eq "ports_allocate: idempotent (index unchanged)" "0" "$(val alpha HARBOR_INDEX)"

# New allocation after two takes the next free index, not a reused one.
ports_allocate gamma >/dev/null
assert_eq "ports_allocate: third project idx 2" "2" "$(val gamma HARBOR_INDEX)"

# --- ports_load exports the values -------------------------------------------
assert_eq "ports_load: exports DB_PORT" "20020" "$( ports_load beta && printf '%s' "$DB_PORT" )"

# --- ports_release -----------------------------------------------------------
ports_release gamma
assert_fail "ports_release: file removed" test -f "$(ports_file gamma)"

# --- ports_ensure: backfills without re-allocating ---------------------------
# Simulate a legacy file missing newer offsets; ensure keeps the index.
printf 'HARBOR_INDEX=5\nDB_PORT=20100\n' > "$(ports_file legacy)"
ports_ensure legacy
assert_eq "ports_ensure: keeps index"        "5"     "$(val legacy HARBOR_INDEX)"
assert_eq "ports_ensure: backfills MEILI"    "20104" "$(val legacy MEILI_PORT)"

report
