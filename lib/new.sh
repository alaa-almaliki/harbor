#!/usr/bin/env bash
# new.sh — one-shot greenfield: scaffold -> init -> up -> wire -> install -> link -> open.

_scaffold() {
  local name="$1" framework="$2" dir; dir="$(project_dir "$name")"
  case "$framework" in
    laravel)     cmd_composer "$name" create-project laravel/laravel . ;;
    symfony)     cmd_composer "$name" create-project symfony/skeleton . ;;
    codeigniter) cmd_composer "$name" create-project codeigniter4/appstarter . ;;
    magento)
      warn "Magento scaffold needs your Marketplace auth keys (~/.composer/auth.json)."
      cmd_composer "$name" create-project --repository-url=https://repo.magento.com/ magento/project-community-edition . || \
        die "Magento create-project failed (auth keys?) — scaffold manually then: harbor init $name magento"
      ;;
    plain)
      [ -f "$dir/index.php" ] || printf '<?php phpinfo();\n' > "$dir/index.php" ;;
  esac
}

cmd_new() {
  require_name "${1-}"; local name="$1" framework="${2:-plain}"
  local dir; dir="$(project_dir "$name")"
  [ -e "$dir" ] && [ -n "$(ls -A "$dir" 2>/dev/null)" ] && die "$dir exists and is not empty — use: harbor init $name"
  mkdir -p "$dir"

  log "1/6 init ($framework)";         cmd_init "$name" "$framework" >/dev/null
  log "2/6 up (start stack)";          cmd_up "$name" >/dev/null
  log "3/6 scaffold app";              _scaffold "$name" "$framework"
  # wire/install are best-effort steps: harbor new should finish the chain even
  # if they fail. They must run in a SUBSHELL — a bare `cmd_wire … || warn`
  # can't make them non-fatal, because a `die` deeper in their call graph calls
  # `exit`, which blows past `||` and kills harbor new mid-chain with no
  # diagnostic. The subshell contains the `exit` so `|| warn` actually fires;
  # stdout (verbose detail) is hidden but stderr (the failure reason) is shown.
  log "4/6 wire config";              ( cmd_wire "$name" )    >/dev/null || warn "wire step skipped"
  log "5/6 install";                   ( cmd_install "$name" ) >/dev/null || warn "install step skipped"
  log "6/6 link (https)";              cmd_link "$name"
  cmd_open "$name" >/dev/null 2>&1 || true
  ok "new project ready -> https://$name.$HARBOR_TLD"
}
