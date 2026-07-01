#!/usr/bin/env bash
# launchd.sh — generate/load/unload/kickstart Harbor's com.harbor.* units.
#
# Agents (user domain, gui/<uid>): php-fpm pools, dnsmasq.
# Daemon (system domain): nginx (needs root for :443) — install/remove via sudo.

agent_plist()  { printf '%s' "$HARBOR_LAUNCHAGENTS/$1.plist"; }
daemon_plist() { printf '%s' "$HARBOR_LAUNCHDAEMONS/$1.plist"; }

_gui_domain() { printf 'gui/%s' "$(id -u)"; }

# --- user LaunchAgents -------------------------------------------------------
# launchd_agent_install <label> <plist-src>  — copy into ~/Library/LaunchAgents and load
launchd_agent_install() {
  local label="$1" src="$2" dst
  dst="$(agent_plist "$label")"
  mkdir -p "$HARBOR_LAUNCHAGENTS"
  cp "$src" "$dst"
  launchd_agent_load "$label"
}

launchd_agent_load() {
  local label="$1" dst; dst="$(agent_plist "$label")"
  [ -f "$dst" ] || return 1
  launchctl bootout "$(_gui_domain)/$label" >/dev/null 2>&1 || true
  launchctl bootstrap "$(_gui_domain)" "$dst" 2>/dev/null \
    || launchctl load -w "$dst" 2>/dev/null || true
}

launchd_agent_unload() {
  local label="$1" dst; dst="$(agent_plist "$label")"
  launchctl bootout "$(_gui_domain)/$label" >/dev/null 2>&1 \
    || { [ -f "$dst" ] && launchctl unload -w "$dst" 2>/dev/null; } || true
}

launchd_agent_remove() {
  local label="$1"
  launchd_agent_unload "$label"
  rm -f "$(agent_plist "$label")"
}

# restart a running agent in place (e.g. after xdebug toggle)
launchd_kickstart() {
  local label="$1"
  launchctl kickstart -k "$(_gui_domain)/$label" >/dev/null 2>&1 \
    || launchd_agent_load "$label"
}

launchd_agent_loaded() {
  launchctl print "$(_gui_domain)/$1" >/dev/null 2>&1
}

# --- system LaunchDaemon (sudo) ---------------------------------------------
launchd_daemon_install() {
  local label="$1" src="$2" dst
  dst="$(daemon_plist "$label")"
  log "installing LaunchDaemon $label (requires sudo for :443)"
  sudo cp "$src" "$dst"
  sudo chown root:wheel "$dst"
  sudo launchctl bootout "system/$label" >/dev/null 2>&1 || true
  sudo launchctl bootstrap system "$dst" 2>/dev/null \
    || sudo launchctl load -w "$dst" 2>/dev/null || true
}

launchd_daemon_remove() {
  local label="$1" dst; dst="$(daemon_plist "$label")"
  sudo launchctl bootout "system/$label" >/dev/null 2>&1 \
    || { [ -f "$dst" ] && sudo launchctl unload -w "$dst" 2>/dev/null; } || true
  sudo rm -f "$dst" 2>/dev/null || true
}

launchd_daemon_loaded() {
  sudo launchctl print "system/$1" >/dev/null 2>&1
}

# stop/start a daemon WITHOUT removing its plist (for pause/resume)
launchd_daemon_stop() {
  sudo launchctl bootout "system/$1" >/dev/null 2>&1 || true
}
launchd_daemon_start() {
  local dst; dst="$(daemon_plist "$1")"
  [ -f "$dst" ] || return 1
  sudo launchctl bootstrap system "$dst" 2>/dev/null || sudo launchctl load -w "$dst" 2>/dev/null || true
}
