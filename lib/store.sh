#!/usr/bin/env bash
# store.sh — Magento multi-store routing (one mode per project: domain | path).
# Stores live in the manifest `multistore:` block; changes re-link the vhost.

_store_pairs() {  # echo current stores as "code=value" lines
  manifest_pairs "$(manifest_path "$1")" multistore.stores
}

# Magento store codes are [a-z0-9_]; validating keeps the anchored grep below safe.
_valid_store_code() {
  case "$1" in ""|*[!a-zA-Z0-9_]*) die "invalid store code '$1' (letters, digits, '_')" ;; esac
}

_store_rewrite() {  # <name> <mode> <pairs(code=value lines)>
  local name="$1" mode="$2" pairs="$3" mf inner="" line code val
  mf="$(manifest_path "$name")"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    code="${line%%=*}"; val="${line#*=}"
    if [ -z "$inner" ]; then inner="$code: $val"; else inner="$inner, $code: $val"; fi
  done <<EOF
$pairs
EOF
  grep -v '^multistore:' "$mf" > "$mf.t"
  printf 'multistore: { mode: %s, stores: { %s } }\n' "$mode" "$inner" >> "$mf.t"
  mv "$mf.t" "$mf"
}

store_add() {
  require_name "${1-}"; local name="$1" code="${2-}"; shift 2 2>/dev/null || true
  [ -n "$code" ] || die "usage: harbor store add <name> <code> --domain <host> | --path <seg>"
  _valid_store_code "$code"
  local mode="" val=""
  case "${1-}" in
    --domain) mode=domain; val="${2-}" ;;
    --path)   mode=path;   val="${2-}" ;;
    *) die "specify --domain <host> or --path <seg>" ;;
  esac
  [ -n "$val" ] || die "missing value for ${1}"
  local mf cur; mf="$(manifest_path "$name")"; cur="$(manifest_get "$mf" multistore.mode none)"
  [ "$cur" != none ] && [ "$cur" != "$mode" ] && die "project is '$cur' multistore — one mode per project"
  local pairs; pairs="$(_store_pairs "$name" | grep -v "^$code=" || true)
$code=$val"
  _store_rewrite "$name" "$mode" "$pairs"
  [ "$mode" = path ] && { cmd_magento "$name" config:set web/url/use_store 1 >/dev/null 2>&1 || warn "enable web/url/use_store=1 in Magento when up"; }
  ok "store '$code' ($mode → $val) registered"
  cmd_link "$name"
}

store_list() {
  require_name "${1-}"; local name="$1" mf; mf="$(manifest_path "$name")"
  printf 'multistore mode: %s\n' "$(manifest_get "$mf" multistore.mode none)"
  _store_pairs "$name" | sed 's/^/  /'
}

store_rm() {
  require_name "${1-}"; local name="$1" code="${2-}"
  [ -n "$code" ] || die "usage: harbor store rm <name> <code>"
  _valid_store_code "$code"
  local mode pairs; mode="$(manifest_get "$(manifest_path "$name")" multistore.mode none)"
  pairs="$(_store_pairs "$name" | grep -v "^$code=" || true)"
  _store_rewrite "$name" "$mode" "$pairs"
  ok "store '$code' removed"
  cmd_link "$name"
}

cmd_store() {
  local sub="${1-}"; shift || true
  case "$sub" in
    add) store_add "$@" ;;
    list) store_list "$@" ;;
    rm) store_rm "$@" ;;
    *) die "usage: harbor store add|list|rm <name> ..." ;;
  esac
}
