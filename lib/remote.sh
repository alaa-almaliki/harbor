#!/usr/bin/env bash
# remote.sh — pull DB / media from a remote host (manifest `remote:` block).

# harbor db pull [<name>] [--reconfigure ...]  (extra opts pass through to import)
db_pull() {
  resolve_project "${1-}" "harbor db pull [<name>] [import opts...]"
  [ "$_RP_SHIFT" = 1 ] && shift; local name="$_RP_NAME"
  local mf host rdb tmp; mf="$(manifest_path "$name")"
  host="$(manifest_get "$mf" remote.host "")"
  rdb="$(manifest_get "$mf" remote.db "")"
  [ -n "$host" ] && [ -n "$rdb" ] || die "set remote: { host: user@host, db: name } in the manifest"
  _db_load "$name"; _db_up_check "$name"
  need_cmd ssh
  tmp="$(mktemp "${TMPDIR:-/tmp}/harbor-pull.XXXXXX.sql.gz")"
  log "pulling '$rdb' from $host (mysqldump over ssh)"
  ssh "$host" "mysqldump --single-transaction --no-tablespaces --routines --triggers $rdb | gzip" > "$tmp" \
    || { rm -f "$tmp"; die "remote dump failed"; }
  db_import "$name" "$tmp" "$(db_ident "$name")" "$@"
  rm -f "$tmp"
  ok "db pull complete for $name"
}

# harbor media pull [<name>]
media_pull() {
  resolve_project "${1-}" "harbor media pull [<name>]"
  [ "$_RP_SHIFT" = 1 ] && shift; local name="$_RP_NAME"
  local mf host media dir framework dest
  mf="$(manifest_path "$name")"
  host="$(manifest_get "$mf" remote.host "")"
  media="$(manifest_get "$mf" remote.media "")"
  [ -n "$host" ] && [ -n "$media" ] || die "set remote: { host, media: /path } in the manifest"
  need_cmd rsync
  dir="$(project_dir "$name")"; framework="$(_install_framework "$name")"
  case "$framework" in
    magento) dest="$dir/pub/media" ;;
    laravel) dest="$dir/storage/app" ;;
    *)       dest="$dir/media" ;;
  esac
  mkdir -p "$dest"
  log "rsync $host:$media/ -> $dest/"
  rsync -az --delete --exclude 'cache/**' --exclude '*/cache/**' "$host:$media/" "$dest/"
  ok "media pull complete for $name"
}

cmd_media() {
  [ "${1-}" = "pull" ] || usage_die media "harbor media pull [<name>]"
  shift; media_pull "$@"
}
