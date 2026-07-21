#!/usr/bin/env bash
# test_store.sh — Magento multistore vhost fragments (lib/link.sh).
#
# Regression suite for path mode rendering NOTHING: `harbor store add --path`
# wrote the manifest, but link_map_block/link_mage_params both returned early
# unless mode was `domain`, so the vhost had no prefix handling and every prefixed
# URL 404'd with no error anywhere. The three pieces below only work together —
# a map keyed on $request_uri, a prefix-stripping rewrite, and a REQUEST_URI
# fastcgi_param override — so each is pinned here.
set -uo pipefail
. "$HARBOR_TEST_DIR/lib.sh"
harbor_load common manifest link

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mf_path="$tmp/path.yml"
mf_slash="$tmp/slash.yml"
mf_domain="$tmp/domain.yml"
mf_none="$tmp/none.yml"
mf_web="$tmp/web.yml"
mf_mixed="$tmp/mixed.yml"
printf 'framework: magento\nmultistore: { mode: path, stores: { base: /, de_de: /de } }\n' > "$mf_path"
printf 'framework: magento\nmultistore: { mode: path, stores: { base: /, de_de: de } }\n' > "$mf_slash"
printf 'framework: magento\nmultistore: { mode: domain, stores: { de: de.shop.test } }\n' > "$mf_domain"
printf 'framework: magento\n' > "$mf_none"
printf 'framework: magento\nmultistore: { mode: path, websites: { main: /, de: /de, fr: /fr } }\n' > "$mf_web"
printf 'framework: magento\nmultistore: { mode: path, websites: { main: /, de: /de }, stores: { jp_jp: /store-jp } }\n' > "$mf_mixed"

# --- link_store_seg normalises every spelling of a path value ----------------
assert_eq "seg: bare"           "de" "$(link_store_seg de)"
assert_eq "seg: leading slash"  "de" "$(link_store_seg /de)"
assert_eq "seg: both slashes"   "de" "$(link_store_seg /de/)"
assert_eq "seg: root is empty"  ""   "$(link_store_seg /)"
assert_eq "seg: empty is empty" ""   "$(link_store_seg '')"

# --- path mode: map is keyed on $request_uri, NOT $uri -----------------------
# $uri is rewritten by link_store_path_block; $request_uri is not. Keying on
# $uri would evaluate after the strip and always yield the default store.
map_path="$(link_map_block "$mf_path" magento)"
assert_contains "path: map keyed on \$request_uri" 'map $request_uri $MAGE_RUN_CODE' "$map_path"
assert_contains "path: prefixed store is a regex entry" '~^/de(/|\?|$) "de_de";' "$map_path"
assert_contains "path: the \"/\" store becomes the map default" 'default "base";' "$map_path"
assert_contains "path: run type map present" 'map $request_uri $MAGE_RUN_TYPE' "$map_path"

# the "/" store must NOT also appear as an entry — it has no prefix to match,
# and an empty-segment `~^/(/|\?|$)` entry would swallow every request on the site
assert_eq "path: the \"/\" store emits no regex entry" "" \
  "$(printf '%s\n' "$map_path" | grep '~\^/(' || true)"
# one prefixed store => 1 code entry + 1 type entry + 2 uri-stripping entries
assert_eq "path: one prefixed store, four map entries" "4" \
  "$(printf '%s\n' "$map_path" | grep -c '~\^/' | tr -d ' ')"

# "/de" and "de" in the manifest must render identically
assert_eq "path: leading slash is immaterial" \
  "$(link_map_block "$mf_path" magento)" "$(link_map_block "$mf_slash" magento)"

# --- path mode: the prefix-stripping rewrites --------------------------------
rw="$(link_store_path_block "$mf_path" magento)"
assert_contains "path: exact-prefix rewrite" 'rewrite ^/de$      /    last;' "$rw"
assert_contains "path: sub-path rewrite"     'rewrite ^/de/(.*)$ /$1 last;' "$rw"
assert_eq "path: the \"/\" store emits no rewrite" "2" \
  "$(printf '%s\n' "$rw" | grep -c 'rewrite' | tr -d ' ')"

# --- path mode: REQUEST_URI override is what actually fixes the 404 ----------
# Without it Magento still sees the prefix in REQUEST_URI and routes it -> 404.
params_path="$(link_mage_params "$mf_path" magento)"
assert_contains "path: MAGE_RUN_CODE param" 'fastcgi_param MAGE_RUN_CODE $MAGE_RUN_CODE;' "$params_path"
assert_contains "path: REQUEST_URI from \$harbor_request_uri" \
  'fastcgi_param REQUEST_URI $harbor_request_uri;' "$params_path"

# REGRESSION: building REQUEST_URI from $uri sends /index.php for every deep URL.
# try_files' /index.php fallback is an internal redirect that reassigns $uri, and
# fastcgi_param is evaluated after it — so the ENTIRE site (every store, not just
# prefixed ones) renders the homepage with a 200. Status codes and per-store
# markers stay healthy while this is broken, so only this assertion catches it.
assert_eq "path: REQUEST_URI never built from \$uri" "" \
  "$(printf '%s\n' "$params_path" | grep 'REQUEST_URI \$uri' || true)"

# --- the $harbor_request_uri map strips the prefix, immune to try_files -------
assert_contains "path: uri map keyed on \$request_uri" \
  'map $request_uri $harbor_request_uri {' "$map_path"
assert_contains "path: unprefixed requests pass through" 'default $request_uri;' "$map_path"
assert_contains "path: /de/foo -> /foo"     '~^/de(/.*)$   $1;' "$map_path"
assert_contains "path: /de and /de?a -> /"  '~^/de(\?.*)?$ /$1;' "$map_path"
# domain mode rewrites nothing, so it must NOT emit the stripping map
assert_eq "domain: no uri-stripping map" "" \
  "$(printf '%s\n' "$(link_map_block "$mf_domain" magento)" | grep 'harbor_request_uri' || true)"

# --- websites: routes by website code with MAGE_RUN_TYPE=website -------------
# Magento compares against ScopeInterface::SCOPE_WEBSITE, which is SINGULAR.
# The plural `websites` is the config-scope constant and must NOT appear here.
map_web="$(link_map_block "$mf_web" magento)"
assert_contains "websites: prefixed entry uses the website code" '~^/de(/|\?|$) "de";' "$map_web"
assert_contains "websites: second prefixed entry" '~^/fr(/|\?|$) "fr";' "$map_web"
assert_contains "websites: run type is singular 'website'" '~^/de(/|\?|$) "website";' "$map_web"
assert_contains "websites: the \"/\" website is the code default" 'default "main";' "$map_web"
# the default entry's TYPE must follow it — a default website needs type=website
assert_contains "websites: default type follows the default entry" 'default "website";' "$map_web"
assert_eq "websites: never emits the plural run type" "" \
  "$(printf '%s\n' "$map_web" | grep '"websites"' || true)"
rw_web="$(link_store_path_block "$mf_web" magento)"
assert_contains "websites: /de rewrite" 'rewrite ^/de$      /    last;' "$rw_web"
assert_contains "websites: /fr rewrite" 'rewrite ^/fr$      /    last;' "$rw_web"
assert_contains "websites: fastcgi params emitted" 'MAGE_RUN_CODE' "$(link_mage_params "$mf_web" magento)"

# --- one scope per project: websites XOR stores ------------------------------
# Two run types in one vhost is the confusion this rule prevents. Easy to create
# by hand-editing the manifest, so the gate must fire on render, not just on add.
assert_eq "scope: websites-only project"  "website" "$(link_store_scope "$mf_web")"
assert_eq "scope: stores-only project"    "store"   "$(link_store_scope "$mf_path")"
assert_eq "scope: no multistore key"      "none"    "$(link_store_scope "$mf_none")"
assert_ok   "scope: websites-only passes the gate" link_store_assert_scope "$mf_web"
assert_ok   "scope: stores-only passes the gate"   link_store_assert_scope "$mf_path"
assert_ok   "scope: no multistore passes the gate" link_store_assert_scope "$mf_none"
assert_fail "scope: both maps is rejected"         link_store_assert_scope "$mf_mixed"
# hyphens are legal in a path segment whichever scope is in use
assert_contains "scope: hyphenated segment rewrites" 'rewrite ^/store-jp/(.*)$ /$1 last;' \
  "$(link_store_path_block "$mf_mixed" magento)"

# --- domain mode is unchanged by all of the above ----------------------------
map_domain="$(link_map_block "$mf_domain" magento)"
assert_contains "domain: still keyed on \$http_host" 'map $http_host $MAGE_RUN_CODE' "$map_domain"
assert_contains "domain: host -> code entry" 'de.shop.test de;' "$map_domain"
assert_eq "domain: emits no path rewrites" "" "$(link_store_path_block "$mf_domain" magento)"
params_domain="$(link_mage_params "$mf_domain" magento)"
assert_contains "domain: MAGE_RUN_CODE param" 'fastcgi_param MAGE_RUN_CODE' "$params_domain"
# the REQUEST_URI override is path-only — domain mode never rewrites the URI
assert_eq "domain: no REQUEST_URI override" "" \
  "$(printf '%s\n' "$params_domain" | grep 'REQUEST_URI' || true)"

# --- no multistore key: every fragment is inert, and none of them is fatal ---
# These run as bare statements in _link_build's prefix assignments; a nonzero
# return from the empty case would abort the render under set -e. CLAUDE.md §3.
assert_ok "no multistore: map_block returns 0"       link_map_block       "$mf_none" magento
assert_ok "no multistore: path_block returns 0"      link_store_path_block "$mf_none" magento
assert_ok "no multistore: mage_params returns 0"     link_mage_params     "$mf_none" magento
assert_eq "no multistore: map_block is empty"   "" "$(link_map_block "$mf_none" magento)"
assert_eq "no multistore: path_block is empty"  "" "$(link_store_path_block "$mf_none" magento)"
assert_eq "no multistore: mage_params is empty" "" "$(link_mage_params "$mf_none" magento)"

# non-magento frameworks never get any of it, even with a multistore key
assert_eq "laravel: no map block"  "" "$(link_map_block "$mf_path" laravel)"
assert_eq "laravel: no path block" "" "$(link_store_path_block "$mf_path" laravel)"

report
