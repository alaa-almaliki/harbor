#!/usr/bin/env bash
# ports.sh — per-project host-port + shared-Redis DB-index allocation.
#
# Each project gets a stable integer index. Host ports come from a contiguous
# block: base = HARBOR_PORT_BASE + index*HARBOR_PORT_BLOCK. Redis is shared, so a
# project instead gets a 4-index block on the shared instance. Persisted to
# var/ports/<name> (KEY=VALUE). bash 3.2 safe (no associative arrays).
#
# Block offsets (keep < HARBOR_PORT_BLOCK; offsets 6-19 are free for new services):
#   DB=0  OPENSEARCH=1  RABBITMQ=2  RABBITMQ_UI=3  MEILI=4  ELASTIC=5
# To add an optional service, claim the next free offset in _ports_write and
# render {{<SVC>_PORT}} in its compose fragment.
# Redis DB indices: base = index*4 -> cache, page_cache, session, spare

ports_file() { printf '%s' "$HARBOR_PORTS_DIR/$1"; }

# Highest index currently allocated (-1 if none).
_ports_max_index() {
  local max=-1 f idx
  for f in "$HARBOR_PORTS_DIR"/*; do
    [ -e "$f" ] || continue
    idx="$(grep -E '^HARBOR_INDEX=' "$f" 2>/dev/null | cut -d= -f2)"
    [ -n "$idx" ] && [ "$idx" -gt "$max" ] && max="$idx"
  done
  printf '%s' "$max"
}

_ports_write() {
  local name="$1" idx="$2" file base redis
  file="$(ports_file "$name")"
  base=$(( HARBOR_PORT_BASE + idx * HARBOR_PORT_BLOCK ))
  redis=$(( idx * 4 ))
  {
    echo "HARBOR_INDEX=$idx"
    echo "HARBOR_PORT_BASE=$base"
    echo "DB_PORT=$base"
    echo "OPENSEARCH_PORT=$(( base + 1 ))"
    echo "RABBITMQ_PORT=$(( base + 2 ))"
    echo "RABBITMQ_UI_PORT=$(( base + 3 ))"
    echo "MEILI_PORT=$(( base + 4 ))"
    echo "ELASTIC_PORT=$(( base + 5 ))"
    echo "REDIS_DB_CACHE=$redis"
    echo "REDIS_DB_PAGE=$(( redis + 1 ))"
    echo "REDIS_DB_SESSION=$(( redis + 2 ))"
    echo "REDIS_DB_SPARE=$(( redis + 3 ))"
  } > "$file"
}

# Allocate (or return existing) a block for a project. Idempotent, lock-guarded.
ports_allocate() {
  local name="$1"
  harbor_with_lock "ports" _ports_allocate_locked "$name"
}
_ports_allocate_locked() {
  local name="$1" file idx
  mkdir -p "$HARBOR_PORTS_DIR"
  file="$(ports_file "$name")"
  [ -f "$file" ] && { printf '%s' "$file"; return 0; }
  idx=$(( $(_ports_max_index) + 1 ))
  _ports_write "$name" "$idx"
  printf '%s' "$file"
}

# Load a project's allocated ports into the environment (exported).
ports_load() {
  local file; file="$(ports_file "$1")"
  [ -f "$file" ] || return 1
  set -a
  # shellcheck disable=SC1090
  . "$file"
  set +a
}

ports_release() { rm -f "$(ports_file "$1")"; }

# Backfill a project's ports file with any slots added since it was written.
# Ports are deterministic from the persisted HARBOR_INDEX, so re-writing is a
# no-op except for newly-added offsets — lets an existing project adopt a new
# optional service without re-allocating. Idempotent, lock-guarded.
ports_ensure() {
  local name="$1" file idx
  file="$(ports_file "$name")"
  [ -f "$file" ] || return 1
  idx="$(grep -E '^HARBOR_INDEX=' "$file" 2>/dev/null | cut -d= -f2)"
  [ -n "$idx" ] || return 1
  harbor_with_lock "ports" _ports_write "$name" "$idx"
}

# Is a TCP port currently listening on 127.0.0.1? (best-effort, for fail-fast)
port_in_use() {
  local p="$1"
  command -v lsof >/dev/null 2>&1 || return 1
  lsof -nP -iTCP@127.0.0.1:"$p" -sTCP:LISTEN >/dev/null 2>&1
}
