#!/usr/bin/env bash
# install.sh — framework-aware installer + seeder (Phase 7).

_install_framework() {
  local name="$1" dir mf f
  dir="$(project_dir "$name")"; mf="$(manifest_path "$name")"
  f="$(manifest_get "$mf" framework "")"; [ -n "$f" ] || f="$(link_detect_framework "$dir")"
  printf '%s' "$f"
}

cmd_install() {
  require_name "${1-}"; local name="$1"; local framework; framework="$(_install_framework "$name")"
  local dir; dir="$(project_dir "$name")"
  case "$framework" in
    magento)
      _db_up_check "$name" || die "start the stack first: harbor up $name"
      local script; script="$(magento_write_install "$name")"
      log "running Magento setup:install (generated: $script)"
      ( cd "$dir" && bash "$script" )
      magento_localize "$name"
      ;;
    laravel)
      [ -f "$dir/.env" ] || cmd_wire "$name" >/dev/null 2>&1 || true
      cmd_run "$name" php artisan key:generate --force || true
      cmd_run "$name" php artisan migrate --force
      ;;
    symfony)
      cmd_run "$name" php bin/console doctrine:migrations:migrate --no-interaction || warn "no migrations to run"
      ;;
    codeigniter)
      if [ -f "$dir/spark" ]; then cmd_run "$name" php spark migrate; else warn "CI3/no spark: no migrate step"; fi
      ;;
    *) log "plain PHP: no installer step" ;;
  esac
  ok "install done ($framework)"
}

cmd_seed() {
  require_name "${1-}"; local name="$1"; local framework; framework="$(_install_framework "$name")"
  local dir; dir="$(project_dir "$name")"
  case "$framework" in
    laravel) cmd_run "$name" php artisan db:seed --force ;;
    symfony) cmd_run "$name" php bin/console doctrine:fixtures:load --no-interaction || warn "no fixtures bundle" ;;
    magento) cmd_magento "$name" setup:upgrade ;;
    codeigniter) if [ -f "$dir/spark" ]; then cmd_run "$name" php spark db:seed; else warn "no spark db:seed"; fi ;;
    *) warn "no seeder for plain PHP" ;;
  esac
  ok "seed done ($framework)"
}
