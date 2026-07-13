#!/usr/bin/env bash
# tools.sh — run code under a project's pinned PHP (+ nvm), with Xdebug on demand.

# `-d key=value` CLI flags from a manifest's php_ini flow map (empty if none).
# Mirrors link_php_value_block (FPM's fastcgi_param PHP_VALUE) so the manifest is
# the single source of truth for both web and CLI php ini — e.g. a Magento project
# with `php_ini: { memory_limit: 2G }` gets it on `harbor magento`/`run`/`composer`
# too, not just web requests. (Values with spaces aren't supported here, same as
# the ini keys Harbor projects actually set: memory_limit, max_execution_time, …)
_cli_php_ini_flags() {
  local mf="$1" pair out=""
  [ -f "$mf" ] || return 0
  while IFS= read -r pair; do
    [ -n "$pair" ] || continue
    out="$out -d $pair"
  done <<EOF
$(manifest_pairs "$mf" php_ini)
EOF
  printf '%s' "$out"
}

# a dir containing a `php` that is the project's version (+xdebug when 'on', +the
# project's manifest php_ini). Keyed by project so two projects sharing a PHP
# version but pinning different ini don't clobber each other's shim.
cli_php_pathdir() {
  local v="$1" name="${2:-}" real d so dflags="" default_loaded=0 ini=""
  d="$HARBOR_RUN/cli/${name:-_}/$v"
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
  # manifest php_ini last so it wins over Harbor's own defaults if a project pins one.
  [ -n "$name" ] && ini="$(_cli_php_ini_flags "$(manifest_path "$name")")"
  cat > "$d/php" <<EOF
#!/usr/bin/env bash
exec "$real" $dflags $ini "\$@"
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
  _PR_PHPDIR="$(cli_php_pathdir "$_PR_VER" "$name")"
}

cmd_run() {
  # <name> is optional when run inside a project (cwd under projects/<name> or a
  # `harbor shell`); an explicit existing-project arg still wins.
  resolve_project "${1:-}" "harbor run [<name>] <cmd...>"; local name="$_RP_NAME"
  [ "$_RP_SHIFT" = 1 ] && shift
  [ $# -gt 0 ] || die "usage: harbor run [<name>] <cmd...>  (omit <name> inside a project)"
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
  resolve_project "${1:-}" "harbor composer [<name>] <args...>"; [ "$_RP_SHIFT" = 1 ] && shift; local name="$_RP_NAME"
  _project_run_env "$name"; local dir="$_PR_DIR" phpdir="$_PR_PHPDIR" cli comp
  cli="$(php_cli_bin "$_PR_VER")"
  comp="$(command -v composer)" || die "composer not found (brew install composer)"
  ( cd "$dir" && PATH="$(project_run_path "$phpdir" "$dir")" COMPOSER_MEMORY_LIMIT=-1 "$cli" "$comp" "$@" )
}

# framework console passthroughs (run under project PHP; <name> optional inside a project)
cmd_artisan() { resolve_project "${1:-}" "harbor artisan [<name>] <args...>"; [ "$_RP_SHIFT" = 1 ] && shift; cmd_run "$_RP_NAME" php artisan "$@"; }
cmd_console() { resolve_project "${1:-}" "harbor console [<name>] <args...>"; [ "$_RP_SHIFT" = 1 ] && shift; cmd_run "$_RP_NAME" php bin/console "$@"; }
cmd_spark()   { resolve_project "${1:-}" "harbor spark [<name>] <args...>";   [ "$_RP_SHIFT" = 1 ] && shift; cmd_run "$_RP_NAME" php spark "$@"; }
cmd_magento() { resolve_project "${1:-}" "harbor magento [<name>] <args...>"; [ "$_RP_SHIFT" = 1 ] && shift; cmd_run "$_RP_NAME" php bin/magento "$@"; }

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
cmd_node() { resolve_project "${1:-}" "harbor node [<name>] <args...>"; [ "$_RP_SHIFT" = 1 ] && shift; _nvm_run "$_RP_NAME" node "$@"; }
cmd_npm()  { resolve_project "${1:-}" "harbor npm [<name>] <args...>";  [ "$_RP_SHIFT" = 1 ] && shift; _nvm_run "$_RP_NAME" npm "$@"; }
