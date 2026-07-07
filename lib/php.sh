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

# harbor php [<ver>|sync]
# brew formula currently providing `$(brew --prefix)/bin/php` (php@8.4 or php),
# by resolving the symlink into the Cellar. Empty if nothing is linked.
_php_current_formula() {
  local t; t="$(readlink "$BREW_PREFIX/bin/php" 2>/dev/null)" || return 1
  case "$t" in
    */Cellar/*) t="${t#*/Cellar/}"; printf '%s' "${t%%/*}" ;;   # php@8.4  |  php
    *) return 1 ;;
  esac
}

# harbor php use <ver> — switch the brew-linked CLI `php` (what you get in a plain
# terminal / IDE / global composer). Unlinks the current version and links <ver>.
# Note: this is separate from Harbor's per-project pinning — `harbor run`/nginx
# always use each project's own version regardless of what's linked here.
php_use() {
  local ver="${1-}"
  [ -n "$ver" ] || die "usage: harbor php use <ver>"
  valid_php_version "$ver" || die "unsupported version '$ver' (have: $HARBOR_PHP_VERSIONS)"
  [ -x "$(php_cli_bin "$ver")" ] || die "php@$ver not installed → brew install php@$ver"
  need_cmd brew

  local cur; cur="$(_php_current_formula || true)"
  if [ -n "$cur" ]; then step "unlink $cur"; brew unlink "$cur" >/dev/null 2>&1 || true; fi

  step "link php@$ver"
  if ! brew link --overwrite --force "php@$ver" >/dev/null 2>&1; then
    # the newest version may only exist as the unversioned `php` formula
    case " $(brew list --versions php 2>/dev/null) " in
      *" php $ver."*|*" php $ver "*) brew link --overwrite --force php >/dev/null 2>&1 || true ;;
    esac
  fi

  local now; now="$("$BREW_PREFIX/bin/php" -v 2>/dev/null | head -1)"
  case "$now" in
    "PHP $ver."*) ok "linked php CLI -> $now" ;;
    *) die "link didn't take (php -v: ${now:-none}) — try: brew link --overwrite --force php@$ver" ;;
  esac
  step "open a new terminal (or run 'hash -r') if your shell still resolves the old php"
}

cmd_php() {
  local arg="${1-}"
  case "$arg" in
    "")   php_status ;;
    sync) php_sync ;;
    use)  shift; php_use "${1-}" ;;
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
