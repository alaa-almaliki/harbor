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

# A project's PHP version AND where it came from, as "<ver>|<source>". The one
# place the precedence lives — link_php is a thin wrapper so the version a site
# is rendered with and the version `harbor describe` reports can never drift.
link_php_source() {
  local name="$1" dir="$2" mf v
  mf="$(manifest_path "$name")"
  v="$(manifest_get "$mf" php "")"
  [ -n "$v" ] && { printf '%s|manifest php: (%s)\n' "$v" "$mf"; return 0; }
  if [ -f "$dir/.php-version" ]; then
    v="$(tr -d ' \n\r' < "$dir/.php-version")"
    [ -n "$v" ] && { printf '%s|%s\n' "$v" "$dir/.php-version"; return 0; }
  fi
  printf '%s|global default (harbor php <ver>)\n' "$(default_php)"
}

link_php() {
  local r; r="$(link_php_source "$1" "$2")"
  echo "${r%%|*}"
}

# The PHP for the CURRENT context, as "<ver>|<source>": the named project, else
# the project the cwd is in, else the global default. `harbor describe` and
# `harbor php <php-flag>` both answer "which php am I on?" and must never
# disagree, so both come through here. Not being in a project is not an error —
# the global default is a real answer ("what would a new site get?").
current_php_source() {
  local name="${1-}"
  [ -n "$name" ] || name="$(cwd_project 2>/dev/null || true)"
  if [ -n "$name" ]; then
    link_php_source "$name" "$(project_dir "$name")"
  else
    printf '%s|global default (not inside a project)\n' "$(default_php)"
  fi
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

# Normalise a `multistore.stores` path value to a bare segment. The manifest may
# spell it either way, so "/de", "de" and "/de/" all mean the same thing; "/" and
# "" both mean "no prefix" — i.e. the default store.
link_store_seg() {
  local v="${1-}"
  v="${v#/}"; v="${v%/}"
  printf '%s' "$v"
}

# Echo every multistore entry as "type|code|value", websites first.
#
# `type` is the MAGE_RUN_TYPE Magento expects — `website` for `multistore.websites`,
# `store` for `multistore.stores` (both singular: ScopeInterface::SCOPE_WEBSITE /
# SCOPE_STORE; the plural `websites` seen in some hand-written Magento vhosts is
# the *config-scope* constant, not a run type). A project uses ONE of the two maps
# — see link_store_assert_scope.
link_store_entries() {
  local mf="$1" pair
  [ -f "$mf" ] || return 0
  while IFS= read -r pair; do
    [ -n "$pair" ] || continue
    printf 'website|%s|%s\n' "${pair%%=*}" "${pair#*=}"
  done <<EOF
$(manifest_pairs "$mf" multistore.websites)
EOF
  while IFS= read -r pair; do
    [ -n "$pair" ] || continue
    printf 'store|%s|%s\n' "${pair%%=*}" "${pair#*=}"
  done <<EOF
$(manifest_pairs "$mf" multistore.stores)
EOF
}

# A project routes by websites OR by store views — never both. Two run types in
# one vhost is the confusion this rule exists to prevent, and it is easy to do by
# hand-editing the manifest, so the gate lives here rather than only in store_add.
#
# MUST be called as a plain statement, never inside `$(...)`: `die` there would
# exit only the command-substitution subshell, and the caller would carry on with
# an empty string as though the manifest were fine. CLAUDE.md §3.
link_store_assert_scope() {
  local mf="$1"
  [ -f "$mf" ] || return 0
  if [ -n "$(manifest_pairs "$mf" multistore.websites)" ] &&
     [ -n "$(manifest_pairs "$mf" multistore.stores)" ]; then
    die "manifest sets both multistore.websites and multistore.stores — a project routes by one or the other → remove whichever is wrong from $mf"
  fi
}

# Which scope a project routes by: website | store | none.
link_store_scope() {
  local mf="$1"
  [ -f "$mf" ] || { printf 'none'; return 0; }
  if [ -n "$(manifest_pairs "$mf" multistore.websites)" ]; then printf 'website'; return 0; fi
  if [ -n "$(manifest_pairs "$mf" multistore.stores)" ];   then printf 'store';   return 0; fi
  printf 'none'
}

# Magento multistore: http-context map blocks (empty unless mode is domain|path).
#   domain -> keyed on $http_host
#   path   -> keyed on $request_uri, which nginx never rewrites (unlike $uri), so
#             the store prefix is still visible here even though the rewrites in
#             link_store_path_block have stripped it before location matching.
# MAGE_RUN_TYPE is per-entry, so websites and store views can be mixed freely.
link_map_block() {
  local mf="$1" framework="$2" mode key ent rest t k v seg
  local dcode="" dtype="store" code type uri any=0
  [ "$framework" = magento ] || return 0
  [ -f "$mf" ] || return 0
  mode="$(manifest_get "$mf" multistore.mode none)"
  case "$mode" in
    (domain) key='$http_host' ;;
    (path)   key='$request_uri' ;;
    (*) return 0 ;;
  esac

  # In path mode the entry registered with "/" carries no prefix, so it can't be
  # a map entry — it supplies the map defaults instead (code AND type: a default
  # website needs MAGE_RUN_TYPE=website just as much as a prefixed one).
  if [ "$mode" = path ]; then
    while IFS= read -r ent; do
      [ -n "$ent" ] || continue
      t="${ent%%|*}"; rest="${ent#*|}"; k="${rest%%|*}"; v="${rest#*|}"
      if [ -z "$(link_store_seg "$v")" ]; then dcode="$k"; dtype="$t"; fi
    done <<EOF
$(link_store_entries "$mf")
EOF
  fi

  code="$(printf '    map %s $MAGE_RUN_CODE {\n        default "%s";' "$key" "$dcode")"
  type="$(printf '    map %s $MAGE_RUN_TYPE {\n        default "%s";' "$key" "$dtype")"
  # $harbor_request_uri — the request URI with the store prefix removed, computed
  # from $request_uri because that is the ONE URI variable nginx never rewrites.
  # It cannot be built from $uri: try_files' fallback performs an internal
  # redirect that reassigns $uri to /index.php, and fastcgi_param is evaluated
  # after it, so every deep URL would reach Magento as the homepage.
  uri='    map $request_uri $harbor_request_uri {
        default $request_uri;'

  while IFS= read -r ent; do
    [ -n "$ent" ] || continue
    t="${ent%%|*}"; rest="${ent#*|}"; k="${rest%%|*}"; v="${rest#*|}"
    if [ "$mode" = domain ]; then
      any=1
      code="$code
        $v $k;"
      type="$type
        $v $t;"
    else
      seg="$(link_store_seg "$v")"
      if [ -n "$seg" ]; then
        any=1
        code="$code
        ~^/$seg(/|\?|\$) \"$k\";"
        type="$type
        ~^/$seg(/|\?|\$) \"$t\";"
        # /<seg>/foo?a=1 -> /foo?a=1   and   /<seg> or /<seg>?a=1 -> / or /?a=1
        uri="$uri
        ~^/$seg(/.*)\$   \$1;
        ~^/$seg(\?.*)?\$ /\$1;"
      fi
    fi
  done <<EOF
$(link_store_entries "$mf")
EOF
  [ "$any" = 1 ] || return 0
  if [ "$mode" = path ]; then
    printf '%s\n    }\n%s\n    }\n%s\n    }\n' "$code" "$type" "$uri"
  else
    printf '%s\n    }\n%s\n    }\n' "$code" "$type"
  fi
}

# Magento path-multistore: strip the store prefix at server scope, so the rest of
# the vhost — and Magento's router — sees an ordinary path. `last` re-runs
# location matching, so /<seg>/app/etc/env.php still lands on the deny-all block.
link_store_path_block() {
  local mf="$1" framework="$2" ent seg out=""
  [ "$framework" = magento ] || return 0
  [ -f "$mf" ] || return 0
  [ "$(manifest_get "$mf" multistore.mode none)" = path ] || return 0
  while IFS= read -r ent; do
    [ -n "$ent" ] || continue
    seg="$(link_store_seg "${ent##*|}")"
    [ -n "$seg" ] || continue
    out="$out
    rewrite ^/$seg\$      /    last;
    rewrite ^/$seg/(.*)\$ /\$1 last;"
  done <<EOF
$(link_store_entries "$mf")
EOF
  if [ -n "$out" ]; then printf '%s' "$out"; fi
}

link_mage_params() {
  local mf="$1" framework="$2" mode
  [ "$framework" = magento ] || return 0
  [ -f "$mf" ] || return 0
  mode="$(manifest_get "$mf" multistore.mode none)"
  case "$mode" in
    (domain|path) ;;
    (*) return 0 ;;
  esac
  [ -n "$(link_store_entries "$mf")" ] || return 0
  printf '        fastcgi_param MAGE_RUN_CODE $MAGE_RUN_CODE;\n        fastcgi_param MAGE_RUN_TYPE $MAGE_RUN_TYPE;'
  # Path mode strips the prefix with a rewrite, but brew's fastcgi.conf has
  # already passed REQUEST_URI=$request_uri — the ORIGINAL, still-prefixed URI.
  # Magento derives its path-info from REQUEST_URI (minus SCRIPT_NAME's dir,
  # "/"), so it would try to route "/<seg>/catalog" and 404 — the rewrite alone
  # fixes nothing. Re-send it from $harbor_request_uri (see link_map_block).
  #
  # NEVER build this from $uri: try_files' /index.php fallback is an internal
  # redirect that reassigns $uri, and fastcgi_param is evaluated after it, so
  # $uri$is_args$args sends REQUEST_URI=/index.php for EVERY deep URL and the
  # whole site — every store, not just prefixed ones — renders the homepage with
  # a 200. Status codes and per-store markers both look healthy while this is
  # broken; assert on page identity (<title>, a route-specific element) instead.
  #
  # A repeated fastcgi_param is sent twice and PHP keeps the last, so this MUST
  # stay after the fastcgi.conf include in templates/nginx/body/magento.conf.tmpl.
  if [ "$mode" = path ]; then
    printf '\n        fastcgi_param REQUEST_URI $harbor_request_uri;'
  fi
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

  # Plain statement on purpose — the render below reads the manifest from inside
  # command substitutions, where a die could not stop it.
  link_store_assert_scope "$mf"

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
  STORE_PATH_BLOCK="$(link_store_path_block "$mf" "$framework")" \
  CUSTOM_INCLUDE="$custom_inc" \
  BODY="$(cat "$body_tmpl")" \
  render "$HARBOR_TEMPLATES/nginx/vhost.conf.tmpl" "$out"

  # remember the values for the caller
  _LINK_FRAMEWORK="$framework"; _LINK_PHP="$phpver"; _LINK_DOCROOT="$docroot"; _LINK_NAMES="$names"
  echo "$framework php=$phpver root=$docroot names=[$names]"
}

cmd_link() {
  resolve_project "${1-}" "harbor link [<name>]"; local name="$_RP_NAME"
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
  resolve_project "${1-}" "harbor unlink [<name>]"; local name="$_RP_NAME"
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
