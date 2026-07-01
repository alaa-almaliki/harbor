#!/usr/bin/env bash
# doctor.sh — host requirements report. REPORT ONLY (never installs).
# Exits non-zero if a Required item is missing.

_D_REQ_MISS=0

_d_ok()   { printf '  %s[ok]%s %-20s %s\n' "$_c_grn" "$_c_reset" "$1" "${2:-}"; }
_d_miss() { printf '  %s[--]%s %-20s %s\n' "$_c_ylw" "$_c_reset" "$1" "${2:-}"; }
_d_bad()  { printf '  %s[!!]%s %-20s %s\n' "$_c_red" "$_c_reset" "$1" "${2:-}"; }

# _d_req <name> <test-cmd...> ; on failure prints hint stored in _D_HINT
_d_have() { command -v "$1" >/dev/null 2>&1; }

_d_section() { printf '\n%s%s%s\n' "$_c_blu" "$1" "$_c_reset"; }

_d_required() {
  _d_section "Required"

  if _d_have brew; then _d_ok "homebrew" "$(command -v brew)"; else
    _d_bad "homebrew" "missing  → https://brew.sh"; _D_REQ_MISS=$((_D_REQ_MISS+1)); fi

  local vers; vers="$(installed_php_versions | tr '\n' ' ')"
  if [ -n "$vers" ]; then _d_ok "php-fpm" "$vers(≥1 required)"; else
    _d_miss "php-fpm" "none  → brew install php"; _D_REQ_MISS=$((_D_REQ_MISS+1)); fi

  if _d_have nginx; then _d_ok "nginx" "$(nginx -v 2>&1 | sed 's#.*/##')"; else
    _d_miss "nginx" "missing  → brew install nginx"; _D_REQ_MISS=$((_D_REQ_MISS+1)); fi

  if _d_have dnsmasq; then _d_ok "dnsmasq" "$(command -v dnsmasq)"; else
    _d_miss "dnsmasq" "missing  → brew install dnsmasq"; _D_REQ_MISS=$((_D_REQ_MISS+1)); fi

  if _d_have mkcert; then
    _d_ok "mkcert" "$(mkcert -version 2>/dev/null || echo present)"
    local caroot; caroot="$(mkcert -CAROOT 2>/dev/null)"
    if [ -n "$caroot" ] && [ -f "$caroot/rootCA.pem" ]; then _d_ok "mkcert CA" "installed"; else
      _d_bad "mkcert CA" "not installed  → mkcert -install"; _D_REQ_MISS=$((_D_REQ_MISS+1)); fi
  else
    _d_miss "mkcert" "missing  → brew install mkcert"; _D_REQ_MISS=$((_D_REQ_MISS+1)); fi

  if _d_have docker; then _d_ok "docker (cli)" "$(docker --version 2>/dev/null | sed 's/,.*//')"; else
    _d_miss "docker (cli)" "missing  → install Docker Desktop"; _D_REQ_MISS=$((_D_REQ_MISS+1)); fi

  if docker info >/dev/null 2>&1; then _d_ok "docker (daemon)" "running"; else
    _d_bad "docker (daemon)" "not running  → start Docker Desktop"; _D_REQ_MISS=$((_D_REQ_MISS+1)); fi

  if docker compose version >/dev/null 2>&1; then _d_ok "docker compose" "v2"; else
    _d_miss "docker compose" "v2 missing  → update Docker Desktop"; _D_REQ_MISS=$((_D_REQ_MISS+1)); fi
}

_d_config() {
  _d_section "Harbor configuration"
  if [ -f /etc/resolver/test ]; then _d_ok "/etc/resolver/test" "present"; else
    _d_miss "/etc/resolver/test" "absent  → harbor setup"; fi
  if [ -f "$HARBOR_CERT" ]; then _d_ok "*.test cert" "present"; else
    _d_miss "*.test cert" "absent  → harbor setup"; fi
  if [ -f "$HARBOR_CA_BUNDLE" ]; then _d_ok "CA bundle" "present"; else
    _d_miss "CA bundle" "absent  → harbor setup"; fi
  if [ -f "$HARBOR_NGINX_CONF" ]; then _d_ok "nginx.conf" "rendered"; else
    _d_miss "nginx.conf" "absent  → harbor setup"; fi
}

_d_optional() {
  _d_section "Optional"
  if _d_have composer; then _d_ok "composer" "$(composer --version 2>/dev/null | awk '{print $3}')"; else
    _d_miss "composer" "→ brew install composer"; fi
  if _d_have nvm || [ -s "$HOME/.nvm/nvm.sh" ]; then _d_ok "nvm" "present"; else
    _d_miss "nvm" "→ for per-project node"; fi
  local v so
  for v in $(installed_php_versions); do
    if so="$(xdebug_so_for "$v")"; then _d_ok "xdebug $v" "$(basename "$so")"; else
      _d_miss "xdebug $v" "→ pecl install xdebug (for $v)"; fi
  done
}

# Per-project PHP extension check against the pinned version.
_d_project() {
  local name="$1" mf php loaded want missing="" e
  mf="$(manifest_path "$name")"
  [ -f "$mf" ] || die "no manifest for '$name' ($mf)"
  php="$(manifest_get "$mf" php "$(default_php)")"
  _d_section "Project '$name' (php $php)"
  local bin; bin="$(php_cli_bin "$php")"
  [ -x "$bin" ] || { _d_bad "php $php" "not installed  → brew install php@$php"; return; }
  loaded="$("$bin" -m 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr '\n' ' ')"
  local framework baseline
  framework="$(manifest_get "$mf" framework plain)"
  case "$framework" in
    magento) baseline="bcmath ctype curl dom gd iconv intl mbstring openssl pdo_mysql simplexml soap sockets sodium xsl zip" ;;
    laravel|symfony) baseline="ctype curl dom mbstring openssl pdo_mysql tokenizer xml" ;;
    *) baseline="curl mbstring pdo_mysql" ;;
  esac
  want="$baseline $(manifest_list "$mf" extensions)"
  for e in $want; do
    case " $loaded " in
      *" $(printf '%s' "$e" | tr '[:upper:]' '[:lower:]') "*) : ;;
      *) missing="$missing $e" ;;
    esac
  done
  if [ -n "$(_mf_trim "$missing")" ]; then
    _d_bad "extensions" "missing:$missing  → pecl/brew install for php@$php"
  else
    _d_ok "extensions" "all present"
  fi

  # Docker file-sharing hint for containerized tools (best effort)
  if manifest_has "$mf" tools; then
    _d_miss "docker file-sharing" "ensure $HARBOR_PROJECTS and \$TMPDIR are shared in Docker Desktop"
  fi
}

cmd_doctor() {
  local name="${1-}"
  _D_REQ_MISS=0
  printf '%sHarbor doctor%s — report only (never installs)\n' "$_c_dim" "$_c_reset"
  _d_required
  _d_config
  _d_optional
  [ -n "$name" ] && _d_project "$name"
  _d_section "Summary"
  if [ "$_D_REQ_MISS" -gt 0 ]; then
    err "$_D_REQ_MISS required item(s) missing — run the printed brew commands, then re-run."
    return 1
  fi
  ok "all required present"
  return 0
}
