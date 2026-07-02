#!/usr/bin/env bash
# tools.sh — run code under a project's pinned PHP (+ nvm), with Xdebug on demand.

# a dir containing a `php` that is the project's version (+xdebug when 'on')
cli_php_pathdir() {
  local v="$1" real d so dflags="" default_loaded=0
  d="$HARBOR_RUN/cli/$v"
  real="$(php_cli_bin "$v")"
  mkdir -p "$d"
  # mirror fpm-exec: only load xdebug if the version's own config doesn't already,
  # so this works whether or not brew's php.ini enables it (no double-load).
  "$real" -m 2>/dev/null | grep -qi '^xdebug$' && default_loaded=1
  if [ "$(xdebug_state)" = "on" ]; then
    if [ "$default_loaded" -eq 0 ] && so="$(xdebug_so_for "$v")"; then
      dflags="-d zend_extension=$so"
    fi
    dflags="$dflags -d xdebug.mode=debug,develop -d xdebug.start_with_request=trigger"
  elif [ "$default_loaded" -eq 1 ]; then
    dflags="-d xdebug.mode=off"
  fi
  cat > "$d/php" <<EOF
#!/usr/bin/env bash
exec "$real" $dflags "\$@"
EOF
  chmod +x "$d/php"
  printf '%s' "$d"
}

_project_php_ver() {
  local name="$1" dir; dir="$(project_dir "$name")"
  link_php "$name" "$dir"
}

# _project_run_env <name> — resolve the environment for running a project's code.
# Sets _PR_DIR / _PR_VER / _PR_PHPDIR (ports_load-style globals, so `die` fires in
# the caller's shell) and fails fast if the project dir or its pinned PHP is
# missing. Shared preamble for run / composer / shell.
_project_run_env() {
  local name="$1"
  _PR_DIR="$(project_dir "$name")"; [ -d "$_PR_DIR" ] || die "no project dir: $_PR_DIR"
  _PR_VER="$(_project_php_ver "$name")"
  [ -x "$(php_cli_bin "$_PR_VER")" ] || die "php@$_PR_VER not installed → brew install php@$_PR_VER"
  _PR_PHPDIR="$(cli_php_pathdir "$_PR_VER")"
}

cmd_run() {
  require_name "${1-}"; local name="$1"; shift || true
  [ $# -gt 0 ] || die "usage: harbor run <name> <cmd...>"
  _project_run_env "$name"; local dir="$_PR_DIR" phpdir="$_PR_PHPDIR"
  # PATH puts .harbor/scripts (committable per-project commands) ahead of tool
  # shims, so `harbor run <name> invoice` resolves a per-project script.
  if [ $# -eq 1 ]; then
    ( cd "$dir" && PATH="$(project_run_path "$phpdir" "$dir")" sh -c "$1" )
  else
    ( cd "$dir" && PATH="$(project_run_path "$phpdir" "$dir")" "$@" )
  fi
}

cmd_composer() {
  require_name "${1-}"; local name="$1"; shift || true
  _project_run_env "$name"; local dir="$_PR_DIR" phpdir="$_PR_PHPDIR" cli comp
  cli="$(php_cli_bin "$_PR_VER")"
  comp="$(command -v composer)" || die "composer not found (brew install composer)"
  ( cd "$dir" && PATH="$(project_run_path "$phpdir" "$dir")" COMPOSER_MEMORY_LIMIT=-1 "$cli" "$comp" "$@" )
}

# framework console passthroughs (run under project PHP)
cmd_artisan() { require_name "${1-}"; local n="$1"; shift; cmd_run "$n" php artisan "$@"; }
cmd_console() { require_name "${1-}"; local n="$1"; shift; cmd_run "$n" php bin/console "$@"; }
cmd_spark()   { require_name "${1-}"; local n="$1"; shift; cmd_run "$n" php spark "$@"; }
cmd_magento() { require_name "${1-}"; local n="$1"; shift; cmd_run "$n" php bin/magento "$@"; }

# ── node / npm via nvm ──────────────────────────────────────────────────────
_nvm_run() {
  local name="$1" prog="$2"; shift 2
  local dir nvmsh want
  dir="$(project_dir "$name")"; [ -d "$dir" ] || die "no project dir: $dir"
  nvmsh="${NVM_DIR:-$HOME/.nvm}/nvm.sh"
  [ -s "$nvmsh" ] || die "nvm not found (~/.nvm/nvm.sh) — install nvm or add node yourself"
  want="$(manifest_get "$(manifest_path "$name")" node "")"
  (
    cd "$dir" || exit 1
    export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
    # shellcheck disable=SC1090
    . "$nvmsh" >/dev/null 2>&1
    local target="$want"
    [ -z "$target" ] && [ -f .nvmrc ] && target="$(tr -d ' \n\r' < .nvmrc)"
    if [ -n "$target" ] && ! nvm use "$target" >/dev/null 2>&1; then
      if confirm "node $target not installed — install via nvm?"; then
        nvm install "$target" >/dev/null 2>&1 && nvm use "$target" >/dev/null 2>&1
      else
        warn "using current default node"
      fi
    fi
    command -v "$prog" >/dev/null 2>&1 || die "$prog not available via nvm"
    exec "$prog" "$@"
  )
}
cmd_node() { require_name "${1-}"; local n="$1"; shift; _nvm_run "$n" node "$@"; }
cmd_npm()  { require_name "${1-}"; local n="$1"; shift; _nvm_run "$n" npm "$@"; }
