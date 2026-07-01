#!/usr/bin/env bash
# tls.sh — wildcard *.test cert via mkcert + combined CA bundle (system + mkcert
# root) so host PHP trusts *.test for server-to-server calls.

_tls_ensure_sans() { [ -s "$HARBOR_CERT_SANS" ] || printf '*.%s\n' "$HARBOR_TLD" > "$HARBOR_CERT_SANS"; }

tls_setup() {
  need_cmd mkcert
  mkdir -p "$HARBOR_CERTS"
  _tls_ensure_sans
  local sans; sans="$(tr '\n' ' ' < "$HARBOR_CERT_SANS")"
  step "issuing wildcard cert for: $sans"
  # shellcheck disable=SC2086
  mkcert -cert-file "$HARBOR_CERT" -key-file "$HARBOR_CERT_KEY" $sans >/dev/null 2>&1 \
    || die "mkcert failed — is the local CA installed? run: mkcert -install"
  tls_build_ca_bundle
}

tls_build_ca_bundle() {
  local caroot root sys
  caroot="$(mkcert -CAROOT 2>/dev/null)"
  root="$caroot/rootCA.pem"
  [ -f "$root" ] || die "mkcert root CA not found ($root) — run: mkcert -install"
  sys="/etc/ssl/cert.pem"
  [ -f "$sys" ] || sys="$BREW_PREFIX/etc/ca-certificates/cert.pem"
  {
    [ -f "$sys" ] && cat "$sys"
    cat "$root"
  } > "$HARBOR_CA_BUNDLE"
  step "CA bundle -> $HARBOR_CA_BUNDLE (system + mkcert root)"
}

# add extra SAN host(s) and re-issue
tls_add_sans() {
  local h
  _tls_ensure_sans
  for h in "$@"; do
    grep -qx "$h" "$HARBOR_CERT_SANS" 2>/dev/null || echo "$h" >> "$HARBOR_CERT_SANS"
  done
  tls_setup
}

tls_teardown() {
  rm -f "$HARBOR_CERT" "$HARBOR_CERT_KEY" "$HARBOR_CA_BUNDLE"
}
