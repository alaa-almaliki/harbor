#!/usr/bin/env bash
# link.sh — provision/remove an nginx vhost for a project (Phase 4).
# Renders Harbor-owned etc/nginx/sites/<name>.test.conf, adds exact cert SANs,
# reissues the shared cert, reloads nginx. Nothing written to brew's nginx dir.

link_detect_framework() {
  local dir="$1"
  [ -f "$dir/bin/magento" ] && { echo magento; return; }
  [ -f "$dir/artisan" ]     && { echo laravel; return; }
  [ -f "$dir/bin/console" ] && { echo symfony; return; }
  [ -f "$dir/spark" ]       && { echo codeigniter; return; }
  if [ -f "$dir/composer.json" ]; then
    grep -q 'laravel/framework'         "$dir/composer.json" 2>/dev/null && { echo laravel; return; }
    grep -q 'symfony/framework-bundle'  "$dir/composer.json" 2>/dev/null && { echo symfony; return; }
    grep -qE 'codeigniter[0-9]*/framework' "$dir/composer.json" 2>/dev/null && { echo codeigniter; return; }
    grep -q 'magento/product'           "$dir/composer.json" 2>/dev/null && { echo magento; return; }
  fi
  # CodeIgniter 3 bootstrap lives at system/core/CodeIgniter.php
  { [ -f "$dir/system/core/CodeIgniter.php" ] || [ -f "$dir/system/CodeIgniter.php" ]; } && { echo codeigniter; return; }
  echo plain
}

link_docroot() {
  local name="$1" framework="$2" dir="$3" mf override sub
  mf="$(manifest_path "$name")"
  override="$(manifest_get "$mf" docroot "")"
  [ -n "$override" ] && { echo "$dir/$override"; return; }
  case "$framework" in
    magento) sub=pub ;;
    laravel) sub=public ;;
    symfony) if [ -d "$dir/public" ]; then sub=public; elif [ -d "$dir/web" ]; then sub=web; else sub=public; fi ;;
    codeigniter) if [ -d "$dir/public" ]; then sub=public; else sub=""; fi ;;
    *) sub="" ;;
  esac
  if [ -n "$sub" ]; then echo "$dir/$sub"; else echo "$dir"; fi
}

link_php() {
  local name="$1" dir="$2" mf v
  mf="$(manifest_path "$name")"
  v="$(manifest_get "$mf" php "")"
  [ -z "$v" ] && [ -f "$dir/.php-version" ] && v="$(tr -d ' \n\r' < "$dir/.php-version")"
  [ -z "$v" ] && v="$(default_php)"
  echo "$v"
}

link_server_names() {
  local name="$1" mf out extra
  mf="$(manifest_path "$name")"
  out="$name.$HARBOR_TLD"
  extra="$(manifest_list "$mf" domains)"
  [ -n "$extra" ] && out="$out $extra"
  echo "$out"
}

# fastcgi_param PHP_VALUE block from manifest php_ini (handles dotted keys)
link_php_value_block() {
  local mf="$1" pair out=""
  [ -f "$mf" ] || return 0
  while IFS= read -r pair; do
    [ -n "$pair" ] || continue
    if [ -z "$out" ]; then out="$pair"; else out="$out
$pair"; fi
  done <<EOF
$(manifest_pairs "$mf" php_ini)
EOF
  # NOT `[ -n "$out" ] && printf …` — a project with no php_ini keys would make
  # this function return nonzero; harmless at today's call site (a prefix
  # assignment swallows it) but a trap for the next plain caller. CLAUDE.md §3.
  if [ -n "$out" ]; then printf '        fastcgi_param PHP_VALUE "%s";' "$out"; fi
}

# Magento domain-multistore: http-context map blocks (empty otherwise)
link_map_block() {
  local mf="$1" framework="$2" pair k host code type
  [ "$framework" = magento ] || return 0
  [ -f "$mf" ] || return 0
  [ "$(manifest_get "$mf" multistore.mode none)" = domain ] || return 0
  code='    map $http_host $MAGE_RUN_CODE {
        default "";'
  type='    map $http_host $MAGE_RUN_TYPE {
        default "store";'
  local any=0
  while IFS= read -r pair; do
    [ -n "$pair" ] || continue
    k="${pair%%=*}"; host="${pair#*=}"; any=1
    code="$code
        $host $k;"
    type="$type
        $host store;"
  done <<EOF
$(manifest_pairs "$mf" multistore.stores)
EOF
  [ "$any" = 1 ] || return 0
  printf '%s\n    }\n%s\n    }\n' "$code" "$type"
}

link_mage_params() {
  local mf="$1" framework="$2"
  [ "$framework" = magento ] || return 0
  [ -f "$mf" ] || return 0
  [ "$(manifest_get "$mf" multistore.mode none)" = domain ] || return 0
  [ -n "$(manifest_map_keys "$mf" multistore.stores)" ] || return 0
  printf '        fastcgi_param MAGE_RUN_CODE $MAGE_RUN_CODE;\n        fastcgi_param MAGE_RUN_TYPE $MAGE_RUN_TYPE;'
}

# Render the vhost file (NO sudo). Echoes a summary line.
_link_build() {
  local name="$1" dir mf framework docroot phpver names sock body_tmpl out
  dir="$(project_dir "$name")"
  [ -d "$dir" ] || die "project dir not found: $dir"
  mf="$(manifest_path "$name")"
  framework="$(manifest_get "$mf" framework "")"; [ -n "$framework" ] || framework="$(link_detect_framework "$dir")"
  docroot="$(link_docroot "$name" "$framework" "$dir")"
  phpver="$(link_php "$name" "$dir")"
  valid_php_version "$phpver" || die "site php '$phpver' unsupported"
  [ -x "$(php_fpm_bin "$phpver")" ] || die "php@$phpver not installed → brew install php@$phpver"
  sock="$(php_sock "$phpver")"
  names="$(link_server_names "$name")"
  [ -d "$docroot" ] || warn "docroot does not exist yet: $docroot (site will 404 until created)"

  body_tmpl="$HARBOR_TEMPLATES/nginx/body/$framework.conf.tmpl"
  [ -f "$body_tmpl" ] || body_tmpl="$HARBOR_TEMPLATES/nginx/body/plain.conf.tmpl"

  local custom_inc=""
  [ -f "$dir/.harbor/nginx.conf" ] && custom_inc="    include $dir/.harbor/nginx.conf;"

  out="$HARBOR_NGINX_SITES/$name.$HARBOR_TLD.conf"
  mkdir -p "$HARBOR_NGINX_SITES"
  NAME="$name" FRAMEWORK="$framework" PHP_VER="$phpver" \
  SERVER_NAMES="$names" DOCROOT="$docroot" PHP_SOCK="$sock" \
  CERT="$HARBOR_CERT" CERT_KEY="$HARBOR_CERT_KEY" LOG_DIR="$HARBOR_LOG_DIR" \
  BREW_PREFIX="$BREW_PREFIX" \
  PHP_VALUE_BLOCK="$(link_php_value_block "$mf")" \
  MAGE_PARAMS="$(link_mage_params "$mf" "$framework")" \
  MAP_BLOCK="$(link_map_block "$mf" "$framework")" \
  CUSTOM_INCLUDE="$custom_inc" \
  BODY="$(cat "$body_tmpl")" \
  render "$HARBOR_TEMPLATES/nginx/vhost.conf.tmpl" "$out"

  # remember the values for the caller
  _LINK_FRAMEWORK="$framework"; _LINK_PHP="$phpver"; _LINK_DOCROOT="$docroot"; _LINK_NAMES="$names"
  echo "$framework php=$phpver root=$docroot names=[$names]"
}

cmd_link() {
  require_name "${1-}"; local name="$1"
  local mf; mf="$(manifest_path "$name")"
  _link_build "$name" >/dev/null
  # exact SANs (+ one-level wildcard for magento domain stores)
  local sans="$_LINK_NAMES"
  if [ "$_LINK_FRAMEWORK" = magento ] && [ "$(manifest_get "$mf" multistore.mode none)" = domain ]; then
    sans="$sans *.$name.$HARBOR_TLD"
  fi
  log "reissuing cert with SANs: $sans"
  # shellcheck disable=SC2086
  tls_add_sans $sans >/dev/null
  nginx_reload
  ok "linked $name -> https://$name.$HARBOR_TLD  ($_LINK_FRAMEWORK, php $_LINK_PHP)"
}

cmd_unlink() {
  require_name "${1-}"; local name="$1"
  local out="$HARBOR_NGINX_SITES/$name.$HARBOR_TLD.conf"
  [ -f "$out" ] || { warn "no vhost for $name"; return 0; }
  rm -f "$out"
  if [ -f "$HARBOR_CERT_SANS" ]; then
    grep -v -E "^(\*\.)?$name\.$HARBOR_TLD$" "$HARBOR_CERT_SANS" > "$HARBOR_CERT_SANS.tmp" 2>/dev/null || true
    mv "$HARBOR_CERT_SANS.tmp" "$HARBOR_CERT_SANS"
    tls_setup >/dev/null 2>&1 || true
  fi
  nginx_reload
  ok "unlinked $name"
}
