#!/usr/bin/env bash
# init.sh — provision a project's Harbor state: manifest, port/redis allocation,
# rendered compose, connection files. Does NOT scaffold app code (that's `new`).

# default services line for the manifest, by framework (comma-separated — the
# manifest `services:` list, once written, is the source of truth thereafter)
_init_services() {
  case "$1" in
    magento) echo "mysql, opensearch, rabbitmq" ;;
    *)       echo "mysql" ;;
  esac
}

# the stack's services (space-separated). The manifest is authoritative when the
# `services:` key is PRESENT — including when it is empty, which means "no
# containers". Only an ABSENT key falls back to the framework default, so
# manifests written before `services:` existed keep working.
_project_services() {
  local name="$1" framework="$2" mf
  mf="$(manifest_path "$name")"
  if [ -f "$mf" ] && manifest_has "$mf" services; then
    manifest_map_keys "$mf" services
    return 0
  fi
  _init_services "$framework" | tr -s ', ' ' '
}

# the db server command line — engine-aware. MariaDB rejects MySQL 8's
# `--default-authentication-plugin` flag (and defaults to native auth anyway).
_db_command() {
  local image="$1" pool="$2"
  case "$image" in
    *mariadb*) printf '["--performance-schema=OFF", "--innodb-buffer-pool-size=%s"]' "$pool" ;;
    *)         printf '["--performance-schema=OFF", "--innodb-buffer-pool-size=%s", "--default-authentication-plugin=mysql_native_password"]' "$pool" ;;
  esac
}

# baked-in default image (pinned version) for a bundled service.
_service_image_default() {
  case "$1" in
    mysql)         echo "mysql:8.0" ;;
    opensearch)    echo "opensearchproject/opensearch:2.19.0" ;;
    elasticsearch) echo "docker.elastic.co/elasticsearch/elasticsearch:8.15.3" ;;
    rabbitmq)      echo "rabbitmq:3.13-management-alpine" ;;
    meilisearch)   echo "getmeili/meilisearch:v1.12" ;;
    *)             echo "" ;;
  esac
}

# is the manifest `services:` a flow map ({svc: image}) rather than a list ([svc])?
_services_is_map() {
  local raw; raw="$(manifest_get "$(manifest_path "$1")" services "")"
  case "$(_mf_trim "$raw")" in \{*) return 0 ;; *) return 1 ;; esac
}

# resolve a service's image: manifest `services.<svc>` (the map value) -> for the
# db, the legacy `db.image` -> global config `<SVC>_IMAGE` -> baked-in default.
_service_image() {
  local name="$1" svc="$2" v="" ckey
  ckey="$(printf '%s_IMAGE' "$svc" | tr '[:lower:]' '[:upper:]')"
  _services_is_map "$name" && v="$(manifest_get "$(manifest_path "$name")" "services.$svc" "")"
  [ -z "$v" ] && [ "$svc" = mysql ] && v="$(manifest_get "$(manifest_path "$name")" db.image "")"
  [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  config_get "$ckey" "$(_service_image_default "$svc")"
}

# build the "svc: \"image\", ..." body for services: { ... }, resolving each
# service's image at its current precedence. Args after <name> are service names.
_services_map_body() {
  local name="$1" svc out="" img; shift
  for svc in "$@"; do
    img="$(_service_image "$name" "$svc")"
    if [ -z "$out" ]; then out="$svc: \"$img\""; else out="$out, $svc: \"$img\""; fi
  done
  printf '%s' "$out"
}

# migrate a legacy list-format `services:` (or `db.image`) into the explicit
# `services: { svc: image, ... }` map, in place, preserving the rest of the
# manifest. No-op once already a map. Lets `harbor render` upgrade old projects.
_materialize_services() {
  local name="$1" mf names body tmp
  mf="$(manifest_path "$name")"
  [ -f "$mf" ] || return 0
  _services_is_map "$name" && return 0
  names="$(manifest_map_keys "$mf" services)"
  [ -n "$names" ] || return 0
  # shellcheck disable=SC2086  # word-split the service names
  body="$(_services_map_body "$name" $names)"
  [ -n "$body" ] || return 0
  manifest_set_line "$mf" services "{ $body }"
  # drop the now-redundant db.image field left by the legacy format
  tmp="$mf.tmp.$$"
  awk '/^db:/ { sub(/,[[:space:]]*image:[[:space:]]*[^},[:space:]]*/, ""); print; next } { print }' \
    "$mf" > "$tmp" && mv "$tmp" "$mf"
  step "materialized explicit service versions in $mf"
}

# render the per-project compose file from the manifest + allocation, assembling
# one fragment per service in `services:`.
init_render_compose() {
  local name="$1" framework="$2" services svc
  ports_load "$name" || die "ports not allocated for $name"
  # shellcheck disable=SC2046  # word-split the service list into positionals
  set -- $(_project_services "$name" "$framework")
  local cf; cf="$(project_harbor_dir "$name")/docker-compose.yml"
  if [ "$#" -eq 0 ]; then
    # No services is a valid choice, not an error. Emit no compose file at all
    # rather than one with a dangling `services:` key (which docker rejects).
    #
    # Stop the stack BEFORE deleting the file: the compose file is the only
    # handle Harbor (and docker compose) has on those containers. Delete it
    # while they're running and they keep running, unmanageable by `harbor
    # down`/`destroy` — the user's app still talks to a database Harbor no
    # longer knows about. Down-then-delete keeps the "everything reversible"
    # rule (CLAUDE.md §1.6) true. `down` (not `down -v`) so volumes survive:
    # dropping data is `harbor destroy`'s job, never render's.
    if [ -f "$cf" ]; then
      log "no services for '$name' — stopping its stack before removing the compose file"
      if ! project_compose "$name" down; then
        # Do NOT delete the compose file here: it's the only handle Harbor has
        # on that stack. Deleting it now would make project_has_stack report
        # false, stranding the containers exactly as described above — a
        # render that "succeeded" but left an unreachable stack running is
        # worse than one that visibly failed. Keep the file, fail loudly, and
        # tell the user the retry path.
        warn "could not stop '$name' cleanly — kept $cf so 'harbor down $name' can retry; check: docker ps; then re-run 'harbor render $name' to finish"
        return 1
      fi
    fi
    rm -f "$cf"
    return 0
  fi
  # validate every service has a fragment BEFORE truncating the output file
  for svc in "$@"; do
    [ -f "$HARBOR_TEMPLATES/compose/services/$svc.yml.tmpl" ] || \
      die "unknown service '$svc' in $name → add templates/compose/services/$svc.yml.tmpl"
  done
  local ident image pool
  ident="$(db_ident "$name")"
  image="$(_service_image "$name" mysql)"
  pool="$(config_get MYSQL_BUFFER_POOL 256M)"
  NAME="$name" \
  DB_IMAGE="$image" \
  DB_COMMAND="$(_db_command "$image" "$pool")" \
  DB_NAME="$ident" DB_USER="$ident" DB_PASS="$ident" \
  DB_ROOT_PASS="$(config_get MYSQL_ROOT_PASSWORD root)" \
  DB_PORT="$DB_PORT" \
  OPENSEARCH_IMAGE="$(_service_image "$name" opensearch)" \
  OS_HEAP="$(config_get OPENSEARCH_HEAP 512m)" \
  OPENSEARCH_PORT="$OPENSEARCH_PORT" \
  ELASTICSEARCH_IMAGE="$(_service_image "$name" elasticsearch)" \
  ELASTIC_PORT="$ELASTIC_PORT" \
  ES_HEAP="$(config_get ELASTICSEARCH_HEAP 512m)" \
  RABBITMQ_IMAGE="$(_service_image "$name" rabbitmq)" \
  RABBITMQ_PORT="$RABBITMQ_PORT" RABBITMQ_UI_PORT="$RABBITMQ_UI_PORT" \
  MEILISEARCH_IMAGE="$(_service_image "$name" meilisearch)" \
  MEILI_PORT="$MEILI_PORT" \
  MEILI_MASTER_KEY="$(config_get MEILI_MASTER_KEY harbor-local-meili-master)" \
  MEILI_MEMORY="$(config_get MEILI_INDEXING_MEMORY 512Mb)" \
  _compose_assemble "$@" > "$cf"
}

# harbor render <name> — regenerate derived stack files (docker-compose.yml +
# connection.env) from the manifest, WITHOUT touching the manifest itself. Run
# after editing `services:`, then `harbor up <name>` to apply.
cmd_render() {
  require_name "${1-}"; local name="$1"
  local mf; mf="$(manifest_path "$name")"
  [ -f "$mf" ] || die "not initialized: $name → harbor init $name"
  ports_ensure "$name" || die "ports not allocated for $name → harbor init $name"
  ports_load "$name"
  _materialize_services "$name"   # upgrade a legacy list-format services: in place
  local framework; framework="$(manifest_get "$mf" framework "")"

  # A hand-edited manifest that drops a service must not silently detach its
  # data. One gate, one place: services rm (phase 2) routes through here too, so
  # a user is never asked twice for one action.
  local newlist oldlist=""
  newlist="$(_project_services "$name" "$framework")"
  if [ -f "$(project_compose_file "$name")" ]; then
    # Only the keys under `services:` — a generated compose also has a top-level
    # `volumes:` block whose entries sit at the SAME two-space indent, so a bare
    # /^  [a-z]+:$/ picks up `dbdata` and reports it as a dropped "service".
    # (Verified against a real generated file: it matched `mysql` AND `dbdata`.)
    oldlist="$(awk '
      /^services:/ { in_s = 1; next }
      /^[a-z]/     { in_s = 0 }
      in_s && /^  [a-z][a-z0-9_-]*:$/ { gsub(/[ :]/, ""); print }
    ' "$(project_compose_file "$name")" | tr '\n' ' ')"
  fi
  services_confirm_shrink "$name" "$oldlist" "$newlist" || { warn "aborted — manifest unchanged"; return 1; }

  init_render_compose "$name" "$framework"
  init_write_connection "$name"
  init_write_agent_skills "$name"    # seed existing projects too (non-clobbering)
  init_write_import_samples "$name"  # ditto: import-rules + hook samples
  ok "rendered $name stack: $(_project_services "$name" "$framework") — harbor up $name to apply"
}

# Harbor-owned connection files (source of truth for `wire`, Phase 6)
init_write_connection() {
  local name="$1" hdir; hdir="$(project_harbor_dir "$name")"
  ports_load "$name"
  local ident; ident="$(db_ident "$name")"
  local root; root="$(config_get MYSQL_ROOT_PASSWORD root)"
  local ce="$hdir/connection.env" ct="$hdir/connection.txt"
  # Resolve the service list ONCE — five project_has_service calls would re-parse
  # the manifest ten times. Padded with spaces so `case` can match whole words.
  local framework svcs
  framework="$(manifest_get "$(manifest_path "$name")" framework "")"
  svcs=" $(_project_services "$name" "$framework") "

  # Redis and mail are shared, always-on Harbor services — never per-project.
  cat > "$ce" <<EOF
REDIS_HOST=127.0.0.1
REDIS_PORT=6379
REDIS_DB=$REDIS_DB_CACHE
REDIS_CACHE_DB=$REDIS_DB_CACHE
REDIS_PAGE_DB=$REDIS_DB_PAGE
REDIS_SESSION_DB=$REDIS_DB_SESSION
REDIS_PREFIX=${ident}_
MAIL_HOST=127.0.0.1
MAIL_PORT=1025
EOF
  cat > "$ct" <<EOF
Harbor connection info for "$name"
  URL        https://$name.$HARBOR_TLD
  Redis      127.0.0.1:6379  db: $REDIS_DB_CACHE (cache) $REDIS_DB_PAGE (page) $REDIS_DB_SESSION (session)  prefix: ${ident}_
  Mailpit    smtp 127.0.0.1:1025   ui http://localhost:8025
EOF

  case "$svcs" in *" mysql "*)
    cat >> "$ce" <<EOF
DB_HOST=127.0.0.1
DB_PORT=$DB_PORT
DB_DATABASE=$ident
DB_USERNAME=$ident
DB_PASSWORD=$ident
DB_ROOT_PASSWORD=$root
EOF
    printf '  MySQL      127.0.0.1:%s  db/user/pass: %s / %s / %s  (root: %s)\n' \
      "$DB_PORT" "$ident" "$ident" "$ident" "$root" >> "$ct"
  ;; esac
  case "$svcs" in *" opensearch "*)
    printf 'OPENSEARCH_HOST=127.0.0.1\nOPENSEARCH_PORT=%s\n' "$OPENSEARCH_PORT" >> "$ce"
    printf '  OpenSearch 127.0.0.1:%s\n' "$OPENSEARCH_PORT" >> "$ct"
  ;; esac
  case "$svcs" in *" rabbitmq "*)
    printf 'RABBITMQ_HOST=127.0.0.1\nRABBITMQ_PORT=%s\n' "$RABBITMQ_PORT" >> "$ce"
    printf '  RabbitMQ   amqp 127.0.0.1:%s   ui http://localhost:%s\n' \
      "$RABBITMQ_PORT" "$RABBITMQ_UI_PORT" >> "$ct"
  ;; esac
  case "$svcs" in *" meilisearch "*)
    local mkey; mkey="$(config_get MEILI_MASTER_KEY harbor-local-meili-master)"
    printf 'MEILISEARCH_HOST=http://127.0.0.1:%s\nMEILISEARCH_KEY=%s\n' "$MEILI_PORT" "$mkey" >> "$ce"
    printf '  Meilisearch http://127.0.0.1:%s   key: %s\n' "$MEILI_PORT" "$mkey" >> "$ct"
  ;; esac
  case "$svcs" in *" elasticsearch "*)
    printf 'ELASTICSEARCH_HOST=127.0.0.1\nELASTICSEARCH_PORT=%s\n' "$ELASTIC_PORT" >> "$ce"
    printf '  Elasticsearch http://127.0.0.1:%s   (security disabled for local dev)\n' "$ELASTIC_PORT" >> "$ct"
  ;; esac
}

init_write_gitignore() {
  cat > "$(project_harbor_dir "$1")/.gitignore" <<'EOF'
# Harbor runtime (generated) — do not commit
connection.env
compose.env
docker-compose.yml
install.sh
bin/
# committable: harbor.yml, import-rules, hooks/, scripts/
EOF
}

# Scaffold a committable per-project scripts dir. Anything executable here is on
# PATH for `harbor run <name> ...` / `harbor shell <name>`, run under the
# project's pinned PHP — e.g. .harbor/scripts/invoice -> `harbor run <name> invoice`.
init_write_scripts() {
  local d; d="$(project_harbor_dir "$1")/scripts"
  mkdir -p "$d"
  [ -f "$d/README.md" ] && return 0
  cat > "$d/README.md" <<'EOF'
# Project scripts

Drop executable scripts here (`chmod +x`). They are on PATH — under this
project's pinned PHP — for:

    harbor run <name> <script> [args...]
    harbor shell <name>          # then just: <script>

Example — `invoice` (any language; PHP shown):

    #!/usr/bin/env php
    <?php // .harbor/scripts/invoice — chmod +x me
    fwrite(STDERR, "generating invoice…\n");

Then: `harbor run <name> invoice`. This dir is committable (unlike the generated
`.harbor/bin/` tool shims), so scripts travel with the project.
EOF
}

# Seed committable, self-documenting samples for the import pipeline: a
# commented-out import-rules and one sample hook per phase. Everything is INERT
# until the user edits it — comments are stripped from import-rules, and the
# hook samples carry a .sample suffix (not *.sql, not executable), which the
# runner ignores. Non-clobbering, so project-side edits survive re-init/render.
# The project's real domain is baked into the examples so they're one
# uncomment-and-edit away from working.
init_write_import_samples() {
  local name="$1" hd; hd="$(project_harbor_dir "$name")"
  if [ ! -f "$hd/import-rules" ]; then
    cat > "$hd/import-rules" <<EOF
# import-rules — search/replace applied on every \`harbor db import\` / \`db pull\`.
# One rule per line:   old => new     (# lines are ignored — this file is inert
# until you uncomment/edit). \`--replace OLD=NEW\` on the command line adds to it.
#
# Replacements run AFTER load as a serialized-safe pass: lengths inside PHP
# serialized/JSON values are fixed up, so they're safe for Magento
# core_config_data, CMS content, WordPress options, … Prefix the left side with
# \`re:\` for a regex.
#
# Rules rewrite DATA, not SQL — dump-text tricks like
# \`INSERT INTO => INSERT IGNORE INTO\` don't belong here (they'd corrupt any
# stored content containing those words). Also beware bare-domain rules that
# map several source domains onto one target: values under a unique key (e.g.
# customer emails) can collide — colliding rows are skipped with a warning.
#
# https://staging.example.com => https://$name.test
# re:https?://cdn[0-9]*\\.example\\.com => https://$name.test
EOF
  fi
  mkdir -p "$hd/hooks/pre-import.d" "$hd/hooks/post-import.d"
  if [ ! -f "$hd/hooks/README.md" ]; then
    cat > "$hd/hooks/README.md" <<'EOF'
# Import hooks

Run on every `harbor db import` / `harbor db pull` (skip once with `--no-hooks`).
Global hooks in Harbor's `etc/hooks/<phase>.d/` run first, then these. Files run
in name order — prefix with a number. The `.sample` files are ignored until you
rename the suffix away.

## pre-import.d/ — before the dump loads

Executables only (`chmod +x`). `$HARBOR_DUMP` is the decompressed .sql — edit it
in place to trim what shouldn't load locally. Env: `HARBOR_DUMP`,
`HARBOR_PROJECT`, `HARBOR_PROJECT_DIR`, `HARBOR_FRAMEWORK`, `HARBOR_DB`,
`HARBOR_PHP`.

## post-import.d/ — after load + search/replace

The place to force table records to local values on every import.

- `*.sql` files are piped straight into the imported DB (as root).
- Executables run with `$HARBOR_MYSQL` (a ready-to-use mysql wrapper into the
  DB) plus `HARBOR_DB_HOST/PORT/USER/PASS`, `HARBOR_DB`, `HARBOR_PROJECT`.
EOF
  fi
  if [ ! -f "$hd/hooks/post-import.d/10-local-overrides.sql.sample" ]; then
    cat > "$hd/hooks/post-import.d/10-local-overrides.sql.sample" <<EOF
-- 10-local-overrides.sql.sample — rename away the .sample suffix to activate.
-- Runs against the freshly imported DB on every \`harbor db import\`/\`db pull\`,
-- AFTER the serialized-safe search/replace. Use it to pin records to local
-- values so a fresh import never points at production services.

-- Magento: base URLs -> the local site (harbor db import --reconfigure also
-- does this, plus the search engine; keep it here if you want it unconditional)
-- UPDATE core_config_data SET value = 'https://$name.test/'
--   WHERE path IN ('web/unsecure/base_url', 'web/secure/base_url');

-- Magento: never let an imported config email real customers / hit real APIs
-- UPDATE core_config_data SET value = '0' WHERE path = 'system/smtp/disable';
-- DELETE FROM core_config_data WHERE path LIKE 'payment/%/api_key';

-- Laravel/generic: point every user at a known dev password ("password")
-- UPDATE users SET password = '\$2y\$10\$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi';
EOF
  fi
  if [ ! -f "$hd/hooks/pre-import.d/10-trim-dump.sh.sample" ]; then
    cat > "$hd/hooks/pre-import.d/10-trim-dump.sh.sample" <<'EOF'
#!/usr/bin/env bash
# 10-trim-dump.sh.sample — rename away the .sample suffix AND `chmod +x` to
# activate. Runs before the dump loads; edit $HARBOR_DUMP in place.
set -euo pipefail

# Example: drop bulky log/report rows so local imports stay fast (Magento names)
# LC_ALL=C sed -i '' '/^INSERT INTO `report_event`/d;/^INSERT INTO `customer_log`/d' "$HARBOR_DUMP"

echo "pre-import hook: $HARBOR_PROJECT ($HARBOR_FRAMEWORK) -> $HARBOR_DB"
EOF
  fi
}

# Seed the project with Harbor's agent skill so any coding agent working in
# projects/<name>/ knows how to drive Harbor for this app without re-reading the
# whole tool. Copied from ai/skills/harbor -> <project>/.claude/skills/harbor.
# Committable (travels with the app). Default is non-clobbering, so a re-init
# never overwrites project-side edits — delete the dir to pull a fresh copy.
# With force=1 (used by `harbor update`) it overwrites the managed skill files
# in place, propagating skill improvements while preserving any extra files.
init_write_agent_skills() {
  local name="$1" force="${2:-0}" src dest
  src="$HARBOR_ROOT/ai/skills/harbor"
  [ -d "$src" ] || return 0
  dest="$(project_dir "$name")/.claude/skills/harbor"
  [ "$force" != 1 ] && [ -e "$dest" ] && return 0
  mkdir -p "$dest"
  cp -R "$src/." "$dest/"
}

cmd_init() {
  require_name "${1-}"; local name="$1"; shift || true
  local framework="" phpopt="" msopt="" existing=0
  local svcopt="" svcopt_set=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --php) phpopt="${2-}"; shift 2 ;;
      --multistore) msopt="${2-}"; shift 2 ;;
      --existing) existing=1; shift ;;
      --services)
        [ "$#" -ge 2 ] || usage_die init "--services needs a value (use --services \"\" for none)"
        svcopt="$2"; svcopt_set=1; shift 2 ;;
      --*) die "unknown option: $1" ;;
      *) framework="$1"; shift ;;
    esac
  done

  local dir; dir="$(project_dir "$name")"
  mkdir -p "$dir" "$(project_harbor_dir "$name")"
  if [ "$existing" = 1 ]; then
    local f empty=1
    for f in "$dir"/* "$dir"/.[!.]*; do
      [ -e "$f" ] || continue
      case "$f" in */.harbor) ;; *) empty=0; break ;; esac
    done
    [ "$empty" = 1 ] && warn "--existing but $dir has no app code yet"
  fi

  [ -n "$framework" ] || framework="$(link_detect_framework "$dir")"
  local phpver="$phpopt"
  [ -z "$phpver" ] && [ -f "$dir/.php-version" ] && phpver="$(tr -d ' \n\r' < "$dir/.php-version")"
  [ -z "$phpver" ] && phpver="$(default_php)"
  valid_php_version "$phpver" || die "unsupported php '$phpver'"

  ports_allocate "$name" >/dev/null

  # manifest — services written as an explicit { svc: "image", ... } map so every
  # version is visible and editable in place
  local ident; ident="$(db_ident "$name")"
  local svcnames
  if [ "$svcopt_set" = 1 ]; then
    svcnames="$(services_parse_arg "$svcopt")"
  else
    svcnames="$(services_select "$name" "$framework")"
  fi
  # shellcheck disable=SC2086  # word-split the service names
  FRAMEWORK="$framework" PHP_VER="$phpver" \
  SERVICES_MAP="$(_services_map_body "$name" $svcnames)" \
  DB_BLOCK="$(case " $svcnames " in
                (*" mysql "*) printf 'db: { name: %s, user: %s, password: %s }' "$ident" "$ident" "$ident" ;;
              esac)" \
  render "$HARBOR_TEMPLATES/manifest/harbor.yml.tmpl" "$(manifest_path "$name")"
  [ -n "$msopt" ] && warn "multistore '$msopt' requested — add 'multistore: { mode: $msopt, stores: {} }' to the manifest"

  init_render_compose "$name" "$framework"
  init_write_connection "$name"
  init_write_gitignore "$name"
  init_write_scripts "$name"
  init_write_import_samples "$name"
  init_write_agent_skills "$name"

  ok "init $name ($framework, php $phpver) — db port $(ports_load "$name"; echo "$DB_PORT")"
  step "next: harbor up $name  &&  harbor link $name"
}
