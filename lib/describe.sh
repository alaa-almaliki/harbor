#!/usr/bin/env bash
# describe.sh — `harbor describe <topic>`: report the EFFECTIVE configuration for
# the current project, with the paths to prove it.
#
# Read-only by design: it answers "what would `harbor run` / a web request
# actually get here?" and mutates nothing the other commands wouldn't. That's the
# whole point — Harbor resolves a project's PHP from three places (manifest,
# .php-version, global default) and applies its ini on two surfaces (FPM and the
# CLI shim), so "which php am I on?" is a question with a non-obvious answer.

_dsc_section() { printf '\n%s%s%s\n' "$_c_blu" "$1" "$_c_reset"; }
_dsc_row()     { printf '  %-20s %s\n' "$1" "${2:--}"; }
_dsc_note()    { printf '  %s%s%s\n' "$_c_dim" "$1" "$_c_reset"; }

# _dsc_pathrow <label> <path> — like _dsc_row, but flags a path that isn't there.
# Generated files (socket, pool conf, vhost) legitimately go missing when Harbor
# is stopped or a project isn't linked, and that absence is the useful bit.
_dsc_pathrow() {
  if [ -e "$2" ]; then _dsc_row "$1" "$2"
  else _dsc_row "$1" "$2  ${_c_ylw}(absent)${_c_reset}"; fi
}

# One PHP call for everything we want out of the runtime, as KEY=VALUE lines.
# Called with the project's SHIM (not brew's php), so the values reported are the
# ones Harbor really applies — xdebug toggle and manifest php_ini included.
_dsc_php_probe() {
  "$1" -d display_errors=0 -r '
$keys = ["memory_limit","max_execution_time","upload_max_filesize","post_max_size",
         "date.timezone","opcache.enable","opcache.enable_cli","extension_dir",
         "xdebug.mode","xdebug.start_with_request","xdebug.client_host","xdebug.client_port"];
printf("version=%s\n", PHP_VERSION);
printf("ini_loaded=%s\n", php_ini_loaded_file() ? php_ini_loaded_file() : "-");
printf("ini_scandir=%s\n", PHP_CONFIG_FILE_SCAN_DIR ? PHP_CONFIG_FILE_SCAN_DIR : "-");
$s = php_ini_scanned_files();
$f = $s ? array_filter(array_map("trim", explode(",", $s))) : array();
printf("ini_scanned=%s\n", $f ? implode(" ", array_map("basename", $f)) : "-");
printf("extensions=%d\n", count(get_loaded_extensions()));
foreach ($keys as $k) { $v = ini_get($k); printf("%s=%s\n", $k, ($v === false || $v === "") ? "-" : $v); }
' 2>/dev/null
}

# Exact key lookup in the probe output. Not `grep "^$1="` — the keys contain dots,
# which grep would read as wildcards.
_dsc_probe_get() {
  printf '%s\n' "$_DSC_PROBE" | awk -F= -v k="$1" '$1==k { sub(/^[^=]*=/, ""); print; exit }'
}

# harbor describe php [<name>]
describe_php() {
  local name="" dir="" mf="" ver="" src=""

  if [ "$#" -ge 1 ] && [ -n "${1-}" ]; then
    require_name "$1"
    [ -d "$(project_dir "$1")" ] || die "no such project '$1' → harbor list"
    name="$1"
  else
    # Outside a project is not an error: fall back to the global default so this
    # still answers "what would a new site get?". `|| true` because cwd_project
    # returns 1 (not a failure here) when the cwd isn't under projects/.
    name="$(cwd_project 2>/dev/null || true)"
  fi

  # Same helper `harbor php -v` uses, so the two can never disagree about which
  # PHP you're on.
  local vs; vs="$(current_php_source "$name")"
  ver="${vs%%|*}"; src="${vs#*|}"
  if [ -n "$name" ]; then
    dir="$(project_dir "$name")"
    mf="$(manifest_path "$name")"
  fi

  valid_php_version "$ver" || die "unsupported php version '$ver' (have: $HARBOR_PHP_VERSIONS)"
  local cli fpm; cli="$(php_cli_bin "$ver")"; fpm="$(php_fpm_bin "$ver")"
  [ -x "$cli" ] || die "php@$ver not installed → brew install php@$ver"

  # Probe THROUGH the shim `harbor run`/`composer`/`magento` exec, so what we
  # print is what those commands get. Writing it is the same idempotent side
  # effect cmd_run has — the shim is regenerated on every run by design.
  local phpdir shim
  phpdir="$(cli_php_pathdir "$ver" "$name")"
  shim="$phpdir/php"
  _DSC_PROBE="$(_dsc_php_probe "$shim")"
  [ -n "$_DSC_PROBE" ] || warn "could not run $shim — runtime values below may be blank"

  # --- context ---------------------------------------------------------------
  if [ -n "$name" ]; then
    local framework; framework="$(manifest_get "$mf" framework "$(link_detect_framework "$dir")")"
    _dsc_section "Project"
    _dsc_row "name" "$name"
    _dsc_row "dir" "$dir"
    _dsc_row "framework" "$framework"
    _dsc_row "docroot" "$(link_docroot "$name" "$framework" "$dir")"
    _dsc_row "url" "https://$name.$HARBOR_TLD"
  else
    _dsc_section "Project"
    _dsc_row "name" "(none — cwd isn't under $HARBOR_PROJECTS)"
    _dsc_note "cd into a project, or: harbor describe php <name>"
  fi

  # --- the binaries ----------------------------------------------------------
  _dsc_section "PHP"
  _dsc_row "version" "$(_dsc_probe_get version)"
  _dsc_row "pinned" "$ver  ${_c_dim}from $src${_c_reset}"
  _dsc_row "cli" "$cli"
  _dsc_row "shim" "$shim  ${_c_dim}what harbor run/composer/magento exec${_c_reset}"
  _dsc_pathrow "php-fpm" "$fpm"
  _dsc_row "extensions" "$(_dsc_probe_get extensions) loaded  ${_c_dim}(harbor doctor${name:+ $name} checks the baseline)${_c_reset}"

  local linked lver tag
  linked="$(_php_current_formula 2>/dev/null || true)"
  lver="$("$BREW_PREFIX/bin/php" -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)"
  # the unversioned `php` formula says nothing about which version it is, so name
  # it — but don't print "php@8.4 (8.4)" when the formula already carries it.
  tag="${linked:-none}"
  [ -n "$lver" ] && [ "$linked" != "php@$lver" ] && tag="$tag ($lver)"
  if [ -x "$BREW_PREFIX/bin/php" ]; then
    _dsc_row "brew-linked" "$BREW_PREFIX/bin/php  ${_c_dim}$tag${_c_reset}"
  else
    # No linked php at all — a real state (a half-finished `brew unlink`), and one
    # Harbor would otherwise never notice, since it uses the versioned kegs.
    _dsc_row "brew-linked" "${_c_ylw}none${_c_reset}  ${_c_dim}nothing linked — bare \`php\` in a terminal won't run${_c_reset}"
    _dsc_note "Harbor is unaffected. To get one back: harbor php use $ver"
  fi
  if [ -n "$lver" ] && [ "$lver" != "$ver" ]; then
    _dsc_note "your plain terminal \`php\` is $lver — Harbor runs ${name:-new sites} on $ver"
    _dsc_note "to move the terminal too: harbor php use $ver"
  fi

  # --- ini -------------------------------------------------------------------
  _dsc_section "Config (Harbor never edits these — it passes -d flags instead)"
  _dsc_row "php.ini" "$(_dsc_probe_get ini_loaded)"
  _dsc_row "scan dir" "$(_dsc_probe_get ini_scandir)"
  _dsc_row "scanned" "$(_dsc_probe_get ini_scanned)"
  _dsc_row "extension_dir" "$(_dsc_probe_get extension_dir)"

  local k
  for k in memory_limit max_execution_time upload_max_filesize post_max_size date.timezone opcache.enable_cli; do
    _dsc_row "$k" "$(_dsc_probe_get "$k")"
  done

  if [ -n "$name" ]; then
    local pairs; pairs="$(manifest_pairs "$mf" php_ini)"
    _dsc_section "Manifest php_ini (applied to BOTH surfaces)"
    if [ -n "$pairs" ]; then
      printf '%s\n' "$pairs" | sed 's/^/  /'
      _dsc_note "web: fastcgi_param PHP_VALUE in the vhost · cli: -d flags in the shim"
    else
      _dsc_row "(none)" "add e.g.  php_ini: { memory_limit: 2G }  to $mf"
    fi
  fi

  # --- the FPM side ----------------------------------------------------------
  _dsc_section "FPM pool (the web surface)"
  _dsc_pathrow "pool conf" "$(php_fpm_conf "$ver")"
  _dsc_pathrow "socket" "$(php_sock "$ver")"
  local label; label="$(php_ld_label "$ver")"
  if launchd_agent_loaded "$label"; then _dsc_row "launchd" "$label  ${_c_grn}loaded${_c_reset}"
  else _dsc_row "launchd" "$label  ${_c_ylw}not loaded${_c_reset}  → harbor start"; fi
  _dsc_pathrow "log" "$HARBOR_LOG_DIR/php-$ver.log"
  if [ -n "$name" ]; then
    _dsc_pathrow "vhost" "$HARBOR_NGINX_SITES/$name.$HARBOR_TLD.conf"
  fi

  # --- xdebug ----------------------------------------------------------------
  _dsc_section "Xdebug"
  local state so dflags
  state="$(xdebug_state)"
  if [ "$state" = on ]; then _dsc_row "toggle" "${_c_grn}on${_c_reset}  ${_c_dim}(global — harbor xdebug off)${_c_reset}"
  else _dsc_row "toggle" "off  ${_c_dim}(harbor xdebug on)${_c_reset}"; fi
  if xdebug_cli_trigger; then
    _dsc_row "cli trigger" "automatic  ${_c_dim}(the shim exports XDEBUG_TRIGGER=1 — no prefix needed)${_c_reset}"
  else
    _dsc_row "cli trigger" "manual  ${_c_dim}(prefix runs with XDEBUG_TRIGGER=1)${_c_reset}"
  fi
  if so="$(xdebug_so_for "$ver")"; then _dsc_row "extension" "$so"
  else _dsc_row "extension" "${_c_ylw}not built for php $ver${_c_reset}  → pecl install xdebug"; fi
  if php_ext_loaded "$cli" xdebug; then
    _dsc_row "auto-loaded" "yes  ${_c_dim}(by brew's ini — Harbor only sets xdebug.mode)${_c_reset}"
  else
    _dsc_row "auto-loaded" "no  ${_c_dim}(Harbor adds -d zend_extension when on)${_c_reset}"
  fi
  _dsc_row "mode" "$(_dsc_probe_get xdebug.mode)"
  _dsc_row "start" "$(_dsc_probe_get xdebug.start_with_request)"
  _dsc_row "client" "$(_dsc_probe_get xdebug.client_host):$(_dsc_probe_get xdebug.client_port)"
  # xdebug_dflags leads with a space when there's no zend_extension to add.
  dflags="$(xdebug_dflags "$ver" | sed 's/^ *//')"
  _dsc_row "flags" "${dflags:-(none)}"
  if [ "$state" = on ]; then
    if xdebug_cli_trigger; then _dsc_note "CLI runs are already triggered; in the browser add ?XDEBUG_TRIGGER=1"
    else _dsc_note "trigger it: ?XDEBUG_TRIGGER=1 in the browser, or XDEBUG_TRIGGER=1 harbor magento …"; fi
  fi
  printf '\n'
}

cmd_describe() {
  local topic="${1-}"; shift || true
  case "$topic" in
    php) describe_php "$@" ;;
    *)   usage_die describe "harbor describe php [<name>]" ;;
  esac
}
