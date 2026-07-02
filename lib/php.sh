#!/usr/bin/env bash
# php.sh — provision concurrent ondemand FPM pools (one per installed version),
# each on its own socket, run by a com.harbor.php-<ver> LaunchAgent via fpm-exec.sh.
# (Command surface — cmd_php / cmd_xdebug — arrives in Phase 3.)

php_render_pool() {
  local ver="$1"
  VER="$ver" \
  PID="$(php_pid "$ver")" \
  ERRLOG="$HARBOR_LOG_DIR/php-$ver.log" \
  USER="$HARBOR_USER" \
  GROUP="$HARBOR_GROUP" \
  SOCK="$(php_sock "$ver")" \
  MEMORY_LIMIT="$(config_get PHP_MEMORY_LIMIT 2G)" \
  CA_BUNDLE="$HARBOR_CA_BUNDLE" \
  render "$HARBOR_TEMPLATES/php/fpm.conf.tmpl" "$(php_fpm_conf "$ver")"
}

php_install_pool() {
  local ver="$1" label tmp
  label="$(php_ld_label "$ver")"
  tmp="$HARBOR_RUN/$label.plist"
  LABEL="$label" \
  FPM_EXEC="$HARBOR_LIB/fpm-exec.sh" \
  VER="$ver" \
  HARBOR_ROOT="$HARBOR_ROOT" \
  LOG="$HARBOR_LOG_DIR/php-$ver.launchd.log" \
  render "$HARBOR_TEMPLATES/launchd/php.plist.tmpl" "$tmp"
  launchd_agent_install "$label" "$tmp"
  rm -f "$tmp"
}

php_setup_pools() {
  ensure_dirs
  chmod +x "$HARBOR_LIB/fpm-exec.sh" 2>/dev/null || true
  local v count=0
  for v in $(installed_php_versions); do
    php_render_pool "$v"
    php_install_pool "$v"
    step "php $v pool -> $(php_sock "$v")"
    count=$((count + 1))
  done
  [ "$count" -gt 0 ] || die "no php@x with php-fpm found (brew install php)"
  [ -s "$HARBOR_DEFAULT_PHP_FILE" ] || default_php > "$HARBOR_DEFAULT_PHP_FILE"
}

php_remove_pools() {
  local v
  for v in $HARBOR_PHP_VERSIONS; do
    launchd_agent_remove "$(php_ld_label "$v")"
  done
  rm -rf "$HARBOR_ETC/php"
}

php_reload_all() {
  local v
  for v in $(installed_php_versions); do
    launchd_kickstart "$(php_ld_label "$v")"
  done
}

# re-create pools for installed versions; drop pools for uninstalled ones
php_sync() {
  ensure_dirs
  local installed; installed="$(installed_php_versions | tr '\n' ' ')"
  php_setup_pools
  local v
  for v in $HARBOR_PHP_VERSIONS; do
    case " $installed " in
      *" $v "*) : ;;
      *) launchd_agent_remove "$(php_ld_label "$v")"; rm -rf "$HARBOR_ETC/php/$v" ;;
    esac
  done
  local d; d="$(default_php)"
  case " $installed " in
    *" $d "*) : ;;
    *) echo "${installed%% *}" > "$HARBOR_DEFAULT_PHP_FILE"
       warn "default php $d not installed; reset to ${installed%% *}" ;;
  esac
  ok "php pools synced:$( [ -n "$installed" ] && echo " $installed" )"
}

php_status() {
  local d v mark loaded sock
  d="$(default_php)"
  printf 'default php : %s\n' "$d"
  printf 'xdebug     : %s\n' "$(xdebug_state)"
  printf 'pools:\n'
  for v in $(installed_php_versions); do
    [ "$v" = "$d" ] && mark='*' || mark=' '
    if launchd_agent_loaded "$(php_ld_label "$v")"; then loaded='loaded '; else loaded='STOPPED'; fi
    if [ -S "$(php_sock "$v")" ]; then sock='sock'; else sock='no-sock'; fi
    printf '  %s php %-4s  %s  %s\n' "$mark" "$v" "$loaded" "$sock"
  done
}

# harbor php exec [<ver>|--php <ver>] [--xdebug] [--profile] [--] <args...>
# Run the PHP CLI at a chosen version WITHOUT typing its full brew path, with
# Xdebug (debugger) or the profiler enabled for just this one invocation. This is
# pure CLI — it needs no FPM pool and never touches brew ini / running pools.
#
# Version precedence: a leading bare version (or --php <ver>) -> a `.php-version`
# in the cwd -> the Harbor default. Xdebug precedence: an explicit --xdebug/
# --profile flag (start immediately, start_with_request=yes) -> otherwise the
# global `harbor xdebug` toggle (trigger-based, matching FPM/`harbor run`).
php_exec() {
  local ver="" want_xdebug=0 want_profile=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --) shift; break ;;
      -x|--xdebug|--debug) want_xdebug=1; shift ;;
      --profile|--profiler) want_profile=1; shift ;;
      --php|-p)
        shift; [ $# -gt 0 ] || die "harbor php exec: --php needs a version"
        valid_php_version "$1" || die "unsupported version '$1' (have: $HARBOR_PHP_VERSIONS)"
        ver="$1"; shift ;;
      *)
        # a bare leading version is a convenience selector; anything else starts
        # the php command line (use --php or -- to disambiguate a literal arg).
        if [ -z "$ver" ] && valid_php_version "$1"; then ver="$1"; shift; continue; fi
        break ;;
    esac
  done

  if [ -z "$ver" ]; then
    [ -f .php-version ] && ver="$(tr -d ' \n\r' < .php-version)"
    [ -z "$ver" ] && ver="$(default_php)"
  fi
  valid_php_version "$ver" || die "unsupported version '$ver' (have: $HARBOR_PHP_VERSIONS)"
  local cli; cli="$(php_cli_bin "$ver")"
  [ -x "$cli" ] || die "php@$ver not installed → brew install php@$ver"
  [ $# -gt 0 ] || die "usage: harbor php exec [<ver>] [--xdebug|--profile] <args...>  (e.g. -r 'echo PHP_VERSION;')"

  # Build Xdebug -d flags for THIS call only (never touches brew ini / pools).
  local dflags="" mode="" swr="yes"
  if [ "$want_xdebug" -eq 1 ] || [ "$want_profile" -eq 1 ]; then
    [ "$want_xdebug" -eq 1 ] && mode="debug,develop"
    [ "$want_profile" -eq 1 ] && mode="${mode:+$mode,}profile"
  elif [ "$(xdebug_state)" = "on" ]; then
    mode="debug,develop"; swr="trigger"
  fi

  if [ -n "$mode" ]; then
    # Add zend_extension only when the version's own config doesn't already load
    # xdebug (a double-load is fatal). The `$cli -m` probe lives here, not on the
    # common no-xdebug path. A missing .so is fatal when explicitly requested,
    # else skipped so the run still proceeds.
    if ! "$cli" -m 2>/dev/null | grep -qi '^xdebug$'; then
      local so
      if so="$(xdebug_so_for "$ver")"; then
        dflags="-d zend_extension=$so"
      elif [ "$want_xdebug" -eq 1 ] || [ "$want_profile" -eq 1 ]; then
        die "xdebug.so not found for php@$ver → pecl install xdebug (or a prebuilt .so for EOL php)"
      else
        warn "xdebug is on but not installed for php@$ver — running without it"; mode=""
      fi
    fi
  fi

  if [ -n "$mode" ]; then
    dflags="$dflags -d xdebug.mode=$mode -d xdebug.start_with_request=$swr"
    dflags="$dflags -d xdebug.client_host=127.0.0.1 -d xdebug.client_port=9003 -d xdebug.discover_client_host=false"
    case "$mode" in
      *profile*)
        local pdir="$HARBOR_LOG_DIR/xdebug"; mkdir -p "$pdir"
        dflags="$dflags -d xdebug.output_dir=$pdir"
        warn "xdebug profiler on — cachegrind.out.* -> $pdir" ;;
    esac
    case "$mode" in
      *debug*) warn "xdebug debugger on (client 127.0.0.1:9003, start_with_request=$swr)" ;;
    esac
  else
    # Nothing requested: neutralize a brew-loaded xdebug so plain CLI stays fast.
    # Harmless (-d on an unloaded extension is a silent no-op), so no probe needed.
    dflags="-d xdebug.mode=off"
  fi

  # shellcheck disable=SC2086
  exec "$cli" $dflags "$@"
}

# harbor php [<ver>|sync|exec ...]
cmd_php() {
  local arg="${1-}"
  case "$arg" in
    "")   php_status ;;
    sync) php_sync ;;
    exec) shift; php_exec "$@" ;;
    *)
      valid_php_version "$arg" || die "unsupported version '$arg' (have: $HARBOR_PHP_VERSIONS)"
      [ -x "$(php_fpm_bin "$arg")" ] || die "php@$arg not installed → brew install php@$arg"
      echo "$arg" > "$HARBOR_DEFAULT_PHP_FILE"
      ok "default PHP for new sites -> $arg"
      ;;
  esac
}

# harbor xdebug on|off|status
cmd_xdebug() {
  local sub="${1:-status}"
  case "$sub" in
    on)
      echo on > "$HARBOR_XDEBUG_STATE"
      log "xdebug -> on (reloading pools)"; php_reload_all
      ok "xdebug on — trigger-based, client 127.0.0.1:9003 (set XDEBUG_TRIGGER / browser ext)"
      ;;
    off)
      echo off > "$HARBOR_XDEBUG_STATE"
      log "xdebug -> off (reloading pools)"; php_reload_all
      ok "xdebug off"
      ;;
    status) printf 'xdebug: %s\n' "$(xdebug_state)" ;;
    *) die "usage: harbor xdebug on|off|status" ;;
  esac
}
