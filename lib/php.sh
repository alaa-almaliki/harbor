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

# Which brew formula provides <ver>? The NEWEST PHP ships as the UNVERSIONED
# `php` formula, so linking by `php@<newest>` can fail even though the version is
# installed. Prints the formula name, or returns 1 if brew has neither.
_php_formula_for() {
  local ver="$1" line
  line="$(brew list --versions "php@$ver" 2>/dev/null || true)"
  [ -n "$line" ] && { printf 'php@%s' "$ver"; return 0; }
  line="$(brew list --versions php 2>/dev/null || true)"
  case "$line" in
    "php $ver."*|"php $ver") printf 'php'; return 0 ;;
  esac
  return 1
}

# Best-effort re-link of a formula we unlinked. Empty formula = nothing to undo,
# which is a FAILED restore (there is no previous link to put back), not a
# success — the caller words its error from this return value.
_php_relink() {
  [ -n "${1-}" ] || return 1
  brew link --overwrite --force "$1" >/dev/null 2>&1
}

# harbor php use <ver> — switch the brew-linked CLI `php` (what you get in a plain
# terminal / IDE / global composer). Note: this is separate from Harbor's
# per-project pinning — `harbor run`/nginx always use each project's own version
# regardless of what's linked here.
#
# brew has no atomic "relink as": the old formula must be unlinked before the new
# one can claim the same symlinks. That window is the hazard — a failure between
# the two leaves the host with NO `php` at all, breaking the plain terminal, the
# IDE and global composer, from a command that was only meant to switch versions
# (and Harbor can't warn you, because it never uses the linked php itself). So
# every failure path restores what was linked before, and a no-op switch never
# unlinks in the first place.
php_use() {
  local ver="${1-}"
  [ -n "$ver" ] || usage_die php "harbor php use <ver>"
  valid_php_version "$ver" || die "unsupported version '$ver' (have: $HARBOR_PHP_VERSIONS)"
  [ -x "$(php_cli_bin "$ver")" ] || die "php@$ver not installed → brew install php@$ver"
  need_cmd brew

  local cur want; cur="$(_php_current_formula || true)"
  want="$(_php_formula_for "$ver")" || die "brew has no formula for php $ver → brew install php@$ver"

  # Already linked: don't unlink just to link the same thing back. Keeps the
  # command idempotent AND removes the failure window for the commonest re-run.
  if [ "$want" = "$cur" ] && [ -x "$BREW_PREFIX/bin/php" ]; then
    ok "php CLI already $want — $("$BREW_PREFIX/bin/php" -v 2>/dev/null | head -1)"
    return 0
  fi

  if [ -n "$cur" ]; then step "unlink $cur"; brew unlink "$cur" >/dev/null 2>&1 || true; fi

  step "link $want"
  if ! brew link --overwrite --force "$want" >/dev/null 2>&1; then
    if _php_relink "$cur"; then die "brew link $want failed — restored $cur"; fi
    die "brew link $want failed and NO php is linked now → run: brew link --overwrite --force $want"
  fi

  local now; now="$("$BREW_PREFIX/bin/php" -v 2>/dev/null | head -1)"
  case "$now" in
    "PHP $ver."*) ok "linked php CLI -> $now" ;;
    *)
      if _php_relink "$cur"; then die "link didn't take (php -v: ${now:-none}) — restored $cur"; fi
      die "link didn't take (php -v: ${now:-none}) and NO php is linked now → run: brew link --overwrite --force $want"
      ;;
  esac
  step "open a new terminal (or run 'hash -r') if your shell still resolves the old php"
}

# --- harbor php switch -------------------------------------------------------

# Is <a> an older PHP than <b>? Numeric per component on purpose: a string
# compare puts 8.10 BELOW 8.9, and these versions stay put for years.
_php_ver_lt() {
  local a="$1" b="$2" amaj amin bmaj bmin
  amaj="${a%%.*}"; amin="${a#*.}"
  bmaj="${b%%.*}"; bmin="${b#*.}"
  if [ "$amaj" -ne "$bmaj" ]; then
    if [ "$amaj" -lt "$bmaj" ]; then return 0; else return 1; fi
  fi
  if [ "$amin" -lt "$bmin" ]; then return 0; fi
  return 1
}

# Undo a switch's writes: the manifest line verbatim (comment and all), plus
# .php-version if the project kept one. One function so the EXIT trap armed
# before the write stays a single expression.
_php_switch_restore() {
  local mf="$1" raw="$2" had="$3" pvfile="$4" pvold="$5"
  manifest_restore_line "$mf" php "$raw" "$had"
  if [ -n "$pvold" ]; then printf '%s\n' "$pvold" > "$pvfile"; fi
}

# harbor php switch [<name>] <ver> — point ONE PROJECT at a PHP version and
# converge everything in the ENVIRONMENT that has to follow, so no second command
# is needed: the FPM pool for that version (created here when `harbor php sync`
# was never run for it), the manifest `php:`, an existing .php-version, and the
# vhost's fastcgi_pass. It stops at the environment by design — vendor/ and
# composer.lock belong to the app, and when to rebuild them is the user's call.
#
# Not to be confused with `harbor php use`, which switches the host-global
# brew-linked `php`. The two never affect each other: switching a project here
# doesn't change what a plain `php` in your shell resolves to, and `use` doesn't
# change what a site or `harbor run` executes.
php_switch() {
  resolve_project "${1-}" "harbor php switch [<name>] <ver>"
  [ "$_RP_SHIFT" = 1 ] && shift
  local name="$_RP_NAME" ver="${1-}"
  [ -n "$ver" ] || usage_die php-switch "harbor php switch [<name>] <ver>"
  valid_php_version "$ver" || die "unsupported php version '$ver' (have: $HARBOR_PHP_VERSIONS)"
  # Harbor never brew-installs on a user's behalf (CLAUDE.md §1.9) — advise, stop.
  [ -x "$(php_fpm_bin "$ver")" ] \
    || die "php@$ver not installed → brew install php@$ver  (then: harbor php switch $name $ver)"

  local dir mf cur; dir="$(project_dir "$name")"; mf="$(manifest_path "$name")"
  cur="$(link_php "$name" "$dir")"

  # Already converged? Every piece has to agree — the pool, the manifest `php:`,
  # and the vhost. The manifest is the source of truth, but the vhost is what
  # actually serves requests, so "the manifest says 8.3" is not done on its own;
  # that gap is the whole reason this command exists, and a `switch` that finds it
  # half-applied (a manifest version whose pool was never created, say) heals it
  # rather than reporting success.
  local vhost sock; sock="$(php_sock "$ver")"
  vhost="$HARBOR_NGINX_SITES/$name.$HARBOR_TLD.conf"
  if [ "$cur" = "$ver" ] && [ "$(manifest_get "$mf" php "")" = "$ver" ] \
     && [ -f "$(php_fpm_conf "$ver")" ] && launchd_agent_loaded "$(php_ld_label "$ver")" \
     && [ -f "$vhost" ] && grep -Fq "unix:$sock;" "$vhost"; then
    ok "$name already on php $ver — nothing to do"
    return 0
  fi

  local move="switch"
  if [ "$cur" != "$ver" ]; then
    if _php_ver_lt "$ver" "$cur"; then move="downgrade"; else move="upgrade"; fi
  fi

  # Confirm a downgrade — asked BEFORE any work, so declining costs nothing.
  # Worded for what actually happens: the switch itself is reversible (re-run
  # with the old version) and touches no data, but code built for the newer PHP
  # is the part that won't come back on its own. Overstating it would just train
  # people to hit `y`, which is what makes the genuinely destructive prompts
  # dangerous. HARBOR_YES=1 bypasses; there is no --yes flag.
  if [ "$move" = downgrade ]; then
    warn "$name: php $cur -> $ver is a DOWNGRADE"
    step "reversible (harbor php switch $name $cur), but vendor/ and any code needing php $cur stay as they are"
    confirm "Move '$name' back to php $ver?" || { warn "aborted — $name stays on php $cur"; return 1; }
  fi
  log "$name: php $cur -> $ver ($move)"

  # Pools are normally created by setup / `harbor php sync`; create just this
  # one here so a freshly brew-installed PHP needs no separate sync step.
  if [ ! -f "$(php_fpm_conf "$ver")" ] || ! launchd_agent_loaded "$(php_ld_label "$ver")"; then
    ensure_dirs
    chmod +x "$HARBOR_LIB/fpm-exec.sh" 2>/dev/null || true
    php_render_pool "$ver"
    php_install_pool "$ver"
    step "php $ver pool -> $(php_sock "$ver")"
  fi

  local raw had=0 pvfile="$dir/.php-version" pvold=""
  raw="$(manifest_raw_line "$mf" php)"
  manifest_key_present "$mf" php && had=1
  [ -f "$pvfile" ] && pvold="$(tr -d ' \n\r' < "$pvfile")"

  # Arm the restore BEFORE the write, for the reason cmd_services documents: a
  # `die` deeper in cmd_link's graph calls exit and would sail straight past an
  # explicit revert branch, leaving the manifest set to a version the vhost
  # never got. No other EXIT trap exists in this call graph (verified).
  trap '_php_switch_restore "$mf" "$raw" "$had" "$pvfile" "$pvold"' EXIT
  manifest_set_line "$mf" php "\"$ver\""
  # .php-version is rewritten only when the project already keeps one: Harbor
  # doesn't invent files, but leaving a stale one beside a changed manifest is a
  # trap — the manifest silently outranks it (link_php_source).
  if [ -n "$pvold" ]; then printf '%s\n' "$ver" > "$pvfile"; fi

  if ! cmd_link "$name"; then
    _php_switch_restore "$mf" "$raw" "$had" "$pvfile" "$pvold"
    trap - EXIT
    die "link failed — reverted $name to php $cur"
  fi
  trap - EXIT

  # Prove it rather than assume it: this shim is exactly what `harbor run` /
  # `composer` / `magento` execute for the project.
  local shim out first
  shim="$(cli_php_pathdir "$ver" "$name")/php"
  out="$("$shim" -v 2>/dev/null || true)"
  first="${out%%$'\n'*}"
  case "$out" in
    "PHP $ver."*) ok "$name is on php $ver — web and CLI" ;;
    *) warn "switched to php $ver but the project's php reports: ${first:-nothing}" ;;
  esac
}

# Only a bare `X.Y` is a version to set as the default. Anything else — a script,
# a flag, `-r '…'` — belongs to php. Deliberately strict: `1.2.php` is a file, and
# `8.9` is a version Harbor should reject by name rather than hand to php as a
# filename ("Could not open input file: 8.9" helps nobody).
_php_looks_like_version() { printf '%s' "$1" | grep -Eq '^[0-9]+\.[0-9]+$'; }

# `harbor php <script|flag> …` — run THIS project's php on it. Neither a script
# name nor a flag can be a version or a subcommand, so there's no ambiguity;
# failing `harbor php -v` with "unsupported version '-v'", or `harbor php
# index.php cron/x` with "unsupported version 'index.php'", was a dead end.
# Runs through the same shim `harbor run` uses, so the xdebug toggle and the
# manifest's php_ini apply — `harbor php -i` reports what the code really gets.
#
# The cwd is NOT changed: `php` runs where you stand, so relative paths mean what
# they look like. Use `harbor run php <script>` when you want the project root.
#
# `-h`/`--help` never reaches here: help_intercept answers those first, and
# `harbor php --help` stays Harbor's own topic (php's is `harbor php -help`).
php_passthrough() {
  local name vs ver shim
  name="$(cwd_project 2>/dev/null || true)"
  vs="$(current_php_source "$name")"; ver="${vs%%|*}"
  [ -x "$(php_cli_bin "$ver")" ] || die "php@$ver not installed → brew install php@$ver"
  shim="$(cli_php_pathdir "$ver" "$name")/php"
  exec "$shim" "$@"
}

cmd_php() {
  local arg="${1-}"
  case "$arg" in
    "")     php_status ;;
    sync)   php_sync ;;
    use)    shift; php_use "${1-}" ;;
    switch) shift; php_switch "$@" ;;
    *)
      if ! _php_looks_like_version "$arg"; then php_passthrough "$@"; return; fi
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
      ok "xdebug on — client 127.0.0.1:9003"
      if xdebug_cli_trigger; then
        step "CLI: triggered automatically — harbor run/magento/php just debug, no XDEBUG_TRIGGER needed"
      else
        step "CLI: XDEBUG_CLI_TRIGGER=0 — prefix runs with XDEBUG_TRIGGER=1 yourself"
      fi
      step "web: use the browser extension or add ?XDEBUG_TRIGGER=1"
      ;;
    off)
      echo off > "$HARBOR_XDEBUG_STATE"
      log "xdebug -> off (reloading pools)"; php_reload_all
      ok "xdebug off — CLI runs stop carrying the trigger too"
      ;;
    status)
      printf 'xdebug: %s\n' "$(xdebug_state)"
      if xdebug_cli_trigger; then printf 'cli trigger: automatic (XDEBUG_TRIGGER exported by the shim)\n'
      else printf 'cli trigger: manual (prefix with XDEBUG_TRIGGER=1)\n'; fi
      ;;
    *) usage_die xdebug "harbor xdebug on|off|status" ;;
  esac
}
