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

# --- manifest_key_present: a real PRESENCE test, unlike manifest_has's VALUE
# test — a bare "empty:" key (present, nothing after the colon) must read as
# PRESENT here, the opposite of manifest_has above. This is the crux of
# Finding 1: a hand-edited bare `services:` is the obvious way to write "no
# services," and a value test can't tell that apart from the key never having
# existed at all.
assert_ok   "manifest_key_present: present key"      manifest_key_present "$fx" framework
assert_ok   "manifest_key_present: present map"      manifest_key_present "$fx" services
assert_ok   "manifest_key_present: bare/empty value STILL present" \
  manifest_key_present "$fx" empty
assert_fail "manifest_key_present: absent key"       manifest_key_present "$fx" nope
assert_fail "manifest_key_present: no file -> absent" manifest_key_present /no/such/file key

# --- manifest_raw_line: verbatim line capture (comment and all) --------------
rlfx="$(mktemp)"
cat > "$rlfx" <<'YAML'
framework: laravel
services: { mysql: "mysql:8.0" }  # pinned by ops
bare:
YAML
assert_eq "raw_line: captures trailing comment verbatim" \
  'services: { mysql: "mysql:8.0" }  # pinned by ops' "$(manifest_raw_line "$rlfx" services)"
assert_eq "raw_line: bare key captured as-is" "bare:" "$(manifest_raw_line "$rlfx" bare)"
assert_eq "raw_line: absent key -> empty" "" "$(manifest_raw_line "$rlfx" nope)"

# --- manifest_set_raw_line: writes a captured line back byte-for-byte --------
manifest_set_raw_line "$rlfx" services 'services: { mysql: "mysql:8.0" }  # pinned by ops'
assert_eq "set_raw_line: round-trips the comment" \
  'services: { mysql: "mysql:8.0" }  # pinned by ops' "$(grep '^services:' "$rlfx")"
manifest_set_raw_line "$rlfx" newkey 'newkey: [a, b]   # appended verbatim'
assert_eq "set_raw_line: appends an absent key verbatim" \
  'newkey: [a, b]   # appended verbatim' "$(grep '^newkey:' "$rlfx")"
rm -f "$rlfx"

# --- manifest_set_line: in-place single-line rewrite ---------------------------
sfx="$(mktemp)"
cat > "$sfx" <<'YAML'
# a comment that must survive
framework: laravel
services: { mysql: "mysql:8.0" }
php: "8.3"   # trailing comment
YAML

manifest_set_line "$sfx" services '{ opensearch: "os:1" }'
assert_eq "set_line: replaces the key" \
  'services: { opensearch: "os:1" }' "$(grep '^services:' "$sfx")"
assert_eq "set_line: leading comment survives" \
  '# a comment that must survive' "$(sed -n 1p "$sfx")"
assert_eq "set_line: unrelated trailing comment survives" \
  'php: "8.3"   # trailing comment' "$(grep '^php:' "$sfx")"
assert_eq "set_line: line count unchanged" 4 "$(wc -l < "$sfx" | tr -d ' ')"

manifest_set_line "$sfx" node 20
assert_eq "set_line: appends an absent key" 'node: 20' "$(grep '^node:' "$sfx")"

# a key that appears only as a nested map key must NOT be treated as top-level
cat > "$sfx" <<'YAML'
multistore: { mode: domain, stores: { de: de.shop.test } }
YAML
manifest_set_line "$sfx" mode block
assert_eq "set_line: does not match a key inside a flow map" \
  'multistore: { mode: domain, stores: { de: de.shop.test } }' "$(sed -n 1p "$sfx")"
assert_eq "set_line: appends instead" 'mode: block' "$(grep '^mode:' "$sfx")"

# a key containing a regex metacharacter must be matched literally — a "."
# must not act as "any char" and accidentally match an unrelated top-level key
cat > "$sfx" <<'YAML'
phpZversion: keep-me
YAML
manifest_set_line "$sfx" "php.version" "8.4"
assert_eq "set_line: dot in key does not match an unrelated key" \
  'phpZversion: keep-me' "$(sed -n 1p "$sfx")"
# checks line 2 specifically (not just "the file contains this substring
# somewhere") — a grep -F presence check would pass even if the dot had acted
# as a wildcard and merged the write into line 1, since the resulting text
# would still contain "php.version: 8.4" (just on the wrong, and now-only, line)
assert_eq "set_line: literal-dot key is appended, not merged" \
  'php.version: 8.4' "$(sed -n 2p "$sfx")"
assert_eq "set_line: unrelated key line count still 2" 2 "$(wc -l < "$sfx" | tr -d ' ')"

# a key containing an ERE-only metachar (+ ? | ( ) { }) on the REPLACE path:
# grep (BRE) treats these as literal and takes the replace branch, but awk's
# `~` (ERE) treats them as metachars and never matches — so the old
# grep-to-decide / awk-to-replace split silently dropped the write. This is
# the reviewer's exact repro.
cat > "$sfx" <<'YAML'
php+version: 1.0
YAML
manifest_set_line "$sfx" "php+version" "2.0"
assert_eq "set_line: ERE metachar key (+) is replaced, not silently dropped" \
  'php+version: 2.0' "$(sed -n 1p "$sfx")"

# a key with several ERE metachars at once, on the replace path — also checks
# that the written line carries the RAW key, never a backslash-escaped form
cat > "$sfx" <<'YAML'
a(b|c)+d: old
YAML
manifest_set_line "$sfx" 'a(b|c)+d' 'new'
assert_eq "set_line: multi-metachar key is replaced with the raw (unescaped) key" \
  'a(b|c)+d: new' "$(sed -n 1p "$sfx")"

# appending to a file with no trailing newline must not glue onto the last line
sfx2="$(mktemp)"
printf 'foo: bar' > "$sfx2"
manifest_set_line "$sfx2" baz qux
assert_eq "set_line: no-trailing-newline — previous last line intact" \
  'foo: bar' "$(sed -n 1p "$sfx2")"
assert_eq "set_line: no-trailing-newline — new key on its own line" \
  'baz: qux' "$(sed -n 2p "$sfx2")"
assert_eq "set_line: no-trailing-newline — exactly two lines" 2 "$(wc -l < "$sfx2" | tr -d ' ')"
rm -f "$sfx2"

rm -f "$sfx"

# --- manifest_del_line: removes a top-level key entirely ---------------------
# Unlike manifest_set_line, there is no value to fall back to: the key's line
# must disappear, not become "key:" with nothing after it — that's a
# different file (present-but-empty) than the key never having existed, even
# though manifest_get reads both the same on the way back out.
dfx="$(mktemp)"
cat > "$dfx" <<'YAML'
# a comment that must survive
framework: laravel
services: { mysql: "mysql:8.0" }
php: "8.3"   # trailing comment
YAML

manifest_del_line "$dfx" services
assert_fail "del_line: key line is gone" grep -q '^services:' "$dfx"
assert_eq "del_line: leading comment survives" \
  '# a comment that must survive' "$(sed -n 1p "$dfx")"
assert_eq "del_line: unrelated trailing comment survives" \
  'php: "8.3"   # trailing comment' "$(grep '^php:' "$dfx")"
assert_eq "del_line: line count decreases by exactly one" 3 "$(wc -l < "$dfx" | tr -d ' ')"

# safe no-op when the key is absent
manifest_del_line "$dfx" nope
assert_eq "del_line: absent key -> no-op, line count unchanged" 3 "$(wc -l < "$dfx" | tr -d ' ')"

# a key that appears only nested inside a flow map must NOT be treated as
# top-level — same anchoring property manifest_set_line relies on
cat > "$dfx" <<'YAML'
multistore: { mode: domain, stores: { de: de.shop.test } }
YAML
manifest_del_line "$dfx" mode
assert_eq "del_line: does not match a key nested inside a flow map" \
  'multistore: { mode: domain, stores: { de: de.shop.test } }' "$(sed -n 1p "$dfx")"
assert_eq "del_line: untouched file stays exactly one line" 1 "$(wc -l < "$dfx" | tr -d ' ')"

rm -f "$dfx"

# --- manifest_restore_line: had_it=1 rewrites verbatim, had_it=0 deletes ------
rfx="$(mktemp)"
cat > "$rfx" <<'YAML'
framework: laravel
services: { mysql: "mysql:8.0" }  # pinned by ops
YAML
# key existed -> restore rewrites the captured line verbatim (comment kept)
raw="$(manifest_raw_line "$rfx" services)"
manifest_set_line "$rfx" services '{ opensearch: "os:1" }'   # mutate
manifest_restore_line "$rfx" services "$raw" 1               # restore
assert_eq "restore_line: had_it=1 puts the verbatim line (comment) back" \
  'services: { mysql: "mysql:8.0" }  # pinned by ops' "$(grep '^services:' "$rfx")"
# key absent -> restore deletes the line rather than leaving a bare key
manifest_set_line "$rfx" node 20
manifest_restore_line "$rfx" node "" 0
assert_eq "restore_line: had_it=0 deletes the line entirely" \
  "" "$(grep '^node:' "$rfx" || true)"
rm -f "$rfx"

report
