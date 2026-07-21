#!/usr/bin/env bash
# store.sh — Magento multi-store routing (one mode per project: domain | path).
# Stores live in the manifest `multistore:` block; changes re-link the vhost.

_store_pairs() {  # <name> [websites|stores] — echo entries as "code=value" lines
  manifest_pairs "$(manifest_path "$1")" "multistore.${2-stores}"
}

# Join "code=value" lines into a flow-map body: `a: 1, b: 2`.
_store_inner() {
  local line inner="" code val
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    code="${line%%=*}"; val="${line#*=}"
    if [ -z "$inner" ]; then inner="$code: $val"; else inner="$inner, $code: $val"; fi
  done <<EOF
$1
EOF
  printf '%s' "$inner"
}

# Magento store codes are [a-z0-9_]; validating keeps the anchored grep below safe.
_valid_store_code() {
  case "$1" in ""|*[!a-zA-Z0-9_]*) die "invalid store code '$1' (letters, digits, '_')" ;; esac
}

# A path segment becomes an nginx prefix rewrite, so it must not shadow a real
# Magento entry point or a protected directory — /static/… rewritten to a store
# would break every asset on the site.
_STORE_RESERVED_PATHS="static media errors setup update admin rest graphql soap pub app vendor generated var lib tools dev index.php get.php static.php health_check.php"

_valid_store_path() {
  local seg; seg="$(link_store_seg "$1")"
  [ -n "$seg" ] || return 0   # "/" — the prefix-less default store
  case "$seg" in
    (*[!a-z0-9_-]*) die "invalid store path '$1' (lowercase letters, digits, '-', '_')" ;;
  esac
  case " $_STORE_RESERVED_PATHS " in
    (*" $seg "*) die "store path '$seg' collides with a Magento path — pick another" ;;
  esac
}

_store_rewrite() {  # <name> <mode> <website pairs> <store pairs>
  local name="$1" mode="$2" mf w s inner
  mf="$(manifest_path "$name")"
  w="$(_store_inner "${3-}")"
  s="$(_store_inner "${4-}")"
  inner="mode: $mode"
  # Emit only the maps that have entries — an empty `stores: { }` reads as if the
  # project had store-view routing it doesn't have.
  if [ -n "$w" ]; then inner="$inner, websites: { $w }"; fi
  if [ -n "$s" ]; then inner="$inner, stores: { $s }"; fi
  grep -v '^multistore:' "$mf" > "$mf.t"
  printf 'multistore: { %s }\n' "$inner" >> "$mf.t"
  mv "$mf.t" "$mf"
}

store_add() {
  require_name "${1-}"; local name="$1" code="${2-}"; shift 2 2>/dev/null || true
  [ -n "$code" ] || usage_die store "harbor store add <name> <code> --domain <host> | --path <seg> [--website]"
  _valid_store_code "$code"
  local mode="" val="" kind=stores
  case "${1-}" in
    --domain) mode=domain; val="${2-}" ;;
    --path)   mode=path;   val="${2-}" ;;
    *) die "specify --domain <host> or --path <seg>" ;;
  esac
  [ -n "$val" ] || die "missing value for ${1}"
  shift 2 2>/dev/null || true
  # --website / --store pick the MAGE_RUN_TYPE; store view stays the default so
  # every manifest written before websites: existed keeps its meaning.
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --website) kind=websites ;;
      --store)   kind=stores ;;
      *) usage_die store "unknown option '$1'" ;;
    esac
    shift
  done
  if [ "$mode" = path ]; then _valid_store_path "$val"; fi
  local mf cur; mf="$(manifest_path "$name")"; cur="$(manifest_get "$mf" multistore.mode none)"
  [ "$cur" != none ] && [ "$cur" != "$mode" ] && die "project is '$cur' multistore — one mode per project"
  # Scope is locked the same way mode is: a project routes by websites OR store
  # views, never both. Switching means editing the manifest, not a silent move.
  local want=store; if [ "$kind" = websites ]; then want=website; fi
  local scope; scope="$(link_store_scope "$mf")"
  if [ "$scope" != none ] && [ "$scope" != "$want" ]; then
    die "project routes by $scope code — one scope per project → edit multistore in $mf to switch"
  fi
  local wp="" sp=""
  if [ "$kind" = websites ]; then
    wp="$(_store_pairs "$name" websites | grep -v "^$code=" || true)
$code=$val"
  else
    sp="$(_store_pairs "$name" stores | grep -v "^$code=" || true)
$code=$val"
  fi
  _store_rewrite "$name" "$mode" "$wp" "$sp"
  local label=store; if [ "$kind" = websites ]; then label=website; fi
  ok "$label '$code' ($mode → $val) registered"
  cmd_link "$name"
  # Harbor routes the prefix; only Magento can make Magento *emit* it. Not done
  # for you: the scope may not exist yet, and web/url/use_store must stay 0 (at 1
  # Magento would prepend the store code on top of this prefix).
  if [ "$mode" = path ]; then
    local seg; seg="$(link_store_seg "$val")"
    if [ -n "$seg" ]; then
      log "next, point the $label at the prefix:"
      log "  harbor magento $name config:set --scope=$kind --scope-code=$code \\"
      log "      web/secure/base_url https://$name.$HARBOR_TLD/$seg/"
    fi
  fi
}

store_list() {
  require_name "${1-}"; local name="$1" mf w s; mf="$(manifest_path "$name")"
  printf 'multistore mode: %s\n' "$(manifest_get "$mf" multistore.mode none)"
  w="$(_store_pairs "$name" websites)"
  s="$(_store_pairs "$name" stores)"
  if [ -n "$w" ]; then printf 'websites (MAGE_RUN_TYPE=website):\n'; printf '%s\n' "$w" | sed 's/^/  /'; fi
  if [ -n "$s" ]; then printf 'stores (MAGE_RUN_TYPE=store):\n';    printf '%s\n' "$s" | sed 's/^/  /'; fi
}

store_rm() {
  require_name "${1-}"; local name="$1" code="${2-}"
  [ -n "$code" ] || usage_die store "harbor store rm <name> <code>"
  _valid_store_code "$code"
  local mode wp sp; mode="$(manifest_get "$(manifest_path "$name")" multistore.mode none)"
  wp="$(_store_pairs "$name" websites | grep -v "^$code=" || true)"
  sp="$(_store_pairs "$name" stores   | grep -v "^$code=" || true)"
  _store_rewrite "$name" "$mode" "$wp" "$sp"
  ok "'$code' removed"
  cmd_link "$name"
}

cmd_store() {
  local sub="${1-}"; shift || true
  case "$sub" in
    add) store_add "$@" ;;
    list) store_list "$@" ;;
    rm) store_rm "$@" ;;
    *) usage_die store "harbor store add|list|rm <name> ..." ;;
  esac
}
