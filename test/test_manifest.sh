#!/usr/bin/env bash
# test_manifest.sh — the constrained-YAML manifest parser (lib/manifest.sh).
set -uo pipefail
. "$HARBOR_TEST_DIR/lib.sh"
harbor_load common manifest

# A fixture manifest exercising the supported subset: scalars, quoted scalars,
# flow lists, flow maps, nested flow maps, trailing comments, quoted commas.
fx="$(mktemp)"
trap 'rm -f "$fx"' EXIT
cat > "$fx" <<'YAML'
framework: laravel
php: "8.3"
node: 20
domains: [shop.test, admin.shop.test]
extensions: [imagick, redis]
php_ini: { memory_limit: 2G, "opcache.validate_timestamps": 1 }
services: { mysql: "mysql:8.0", opensearch: "opensearchproject/opensearch:2.19.0" }
db: { name: shop, user: shop, password: shop }
multistore: { mode: domain, stores: { de: de.shop.test, fr: fr.shop.test } }
csv: ["a,b", "c"]
commented: value   # trailing comment stripped
hashval: a#b
empty:
YAML

# --- manifest_get: scalars ---------------------------------------------------
assert_eq "manifest_get: plain scalar"      "laravel" "$(manifest_get "$fx" framework)"
assert_eq "manifest_get: quoted scalar"     "8.3"     "$(manifest_get "$fx" php)"
assert_eq "manifest_get: numeric scalar"    "20"      "$(manifest_get "$fx" node)"
assert_eq "manifest_get: missing -> default" "plain"  "$(manifest_get "$fx" nope plain)"
assert_eq "manifest_get: no file -> default" "d"      "$(manifest_get /no/such/file key d)"

# --- manifest_get: comments & hashes -----------------------------------------
assert_eq "manifest_get: strips trailing comment" "value" "$(manifest_get "$fx" commented)"
assert_eq "manifest_get: keeps inline hash"       "a#b"   "$(manifest_get "$fx" hashval)"

# --- manifest_get: flow maps + nesting ---------------------------------------
assert_eq "manifest_get: map value"          "shop"       "$(manifest_get "$fx" db.name)"
assert_eq "manifest_get: map value (user)"   "shop"       "$(manifest_get "$fx" db.user)"
assert_eq "manifest_get: image w/ colon"     "mysql:8.0"  "$(manifest_get "$fx" services.mysql)"
assert_eq "manifest_get: image path w/ colon" "opensearchproject/opensearch:2.19.0" \
  "$(manifest_get "$fx" services.opensearch)"
assert_eq "manifest_get: map value w/ unit"  "2G"         "$(manifest_get "$fx" php_ini.memory_limit)"
assert_eq "manifest_get: nested flow map"    "de.shop.test" "$(manifest_get "$fx" multistore.stores.de)"
assert_eq "manifest_get: nested flow map 2"  "fr.shop.test" "$(manifest_get "$fx" multistore.stores.fr)"
assert_eq "manifest_get: map sibling scalar" "domain"     "$(manifest_get "$fx" multistore.mode)"
assert_eq "manifest_get: missing map key -> default" "x"  "$(manifest_get "$fx" db.nope x)"

# --- manifest_list -----------------------------------------------------------
assert_eq "manifest_list: flow list"        "shop.test admin.shop.test" "$(manifest_list "$fx" domains)"
assert_eq "manifest_list: extensions"       "imagick redis" "$(manifest_list "$fx" extensions)"
assert_eq "manifest_list: quoted commas"    "a,b c" "$(manifest_list "$fx" csv)"
assert_eq "manifest_list: missing -> empty" ""      "$(manifest_list "$fx" nope)"

# --- manifest_map_keys -------------------------------------------------------
assert_eq "manifest_map_keys: services" "mysql opensearch" "$(manifest_map_keys "$fx" services)"
assert_eq "manifest_map_keys: db"       "name user password" "$(manifest_map_keys "$fx" db)"

# --- manifest_pairs ----------------------------------------------------------
assert_eq "manifest_pairs: db" \
  "name=shop
user=shop
password=shop" \
  "$(manifest_pairs "$fx" db)"

# --- manifest_has ------------------------------------------------------------
assert_ok   "manifest_has: present key"   manifest_has "$fx" framework
assert_ok   "manifest_has: present map"   manifest_has "$fx" services
assert_fail "manifest_has: absent key"    manifest_has "$fx" nope
assert_fail "manifest_has: empty value"   manifest_has "$fx" empty

report
