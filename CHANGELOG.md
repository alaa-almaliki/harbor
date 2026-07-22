# Changelog

All notable changes to Harbor are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **`harbor xdebug on` now triggers CLI runs for you.** While the toggle is on,
  the project's PHP shim exports `XDEBUG_TRIGGER=1`, so `harbor run`, `harbor
  php`, `harbor magento`, `harbor artisan` and friends are debuggable with no
  prefix — and stop being so the moment you run `harbor xdebug off`. Prefixing
  every single command with `XDEBUG_TRIGGER=1` was the step everyone forgets, and
  out on the CLI there's no browser extension to flip, so "Xdebug on" can only
  mean "debug my commands". The **web** surface deliberately still needs its own
  trigger (extension or `?XDEBUG_TRIGGER=1`) — an implicit one there would open a
  session for every asset request and ajax poll. An explicit `XDEBUG_TRIGGER` in
  your environment is never overwritten, and `XDEBUG_CLI_TRIGGER=0` in
  `~/.config/harbor/config` restores the manual behavior. `harbor xdebug status`
  reports which mode you're in.
- **`harbor php <script|flag>…` runs this project's PHP.** Anything that isn't a
  bare `X.Y` version, `sync` or `use` is now passed to PHP itself, so
  `harbor php -v`, `harbor php -m` and `harbor php index.php cron/queue process`
  all work. They used to die with `unsupported version '-v'` /
  `unsupported version 'index.php'` — a dead end, since neither a flag nor a
  script name can be a version. It runs the cwd project's pinned PHP (the global
  default outside a project) through the same shim `harbor run` uses, so the
  Xdebug toggle and the manifest's `php_ini` apply, and it runs in **your** cwd
  rather than the project root (use `harbor run php …` for that). `--help`/`-h`
  stay Harbor's; php's own long help is `harbor php -help`.
- **`harbor describe [<name>]`** — everything Harbor knows about one project, in
  one read-only report: dir/manifest/framework/docroot, the URL **and whether
  it's actually linked**; the PHP version **and which of the three sources pinned
  it** (manifest `php:` → `.php-version` → global default) with its ini, shim and
  FPM pool; the Xdebug picture; every service's **resolved image**, published
  port, running state and data volume, plus the shared Redis indices and Mailpit;
  the database DSN and credentials; multi-store mode/scope and every route; and
  extras (node, containerized tools, import hooks, scripts, remote). It reports
  *effective* values rather than echoing the manifest — the PHP is probed through
  the same shim `harbor run` uses, and each image is resolved at its real
  precedence. Sections with nothing to say are omitted, and an unreachable Docker
  degrades the service states instead of the whole report. `<name>` is optional
  inside a project.
- **`<name>` is now optional for every project command when you're inside a
  project** — anywhere under `projects/<name>/`, or in a `harbor shell`. This
  used to work only for the passthrough/console commands (`run`, `composer`,
  `magento`, `mysql`, `shell`, …); `harbor db backup` and its neighbours failed
  with `project name required` even when the cwd made the project obvious. Now
  covered: `up`, `down`, `destroy`, `render`, `services`, `link`, `unlink`,
  `wire`, `logs`, `open`, `install`, `seed`, `tool`, `tools sync`,
  `db create|drop|backup|import|pull`, `media pull`, and `store add|list|rm`.
  A leading argument is still taken as the project **only when a project by that
  name exists**, so `harbor db backup reporting` inside a project dumps the
  `reporting` database instead of shifting the remaining arguments. `new` and
  `init` keep requiring a name (they create the directory), as does a project
  `restart` (bare `harbor restart` restarts Harbor itself).
- **Rendered compose files now pin `platform:` to the host architecture**, so
  Docker pulls a native image instead of silently reusing a cached foreign-arch
  one. A stale amd64 image kept running under emulation on Apple Silicon —
  correct but far slower (most visibly on database imports), with no symptom
  beyond a one-line warning at `up`. Applies to every per-project service and to
  both singleton stacks (shared mailpit/redis, db sandbox). Override per service
  with `<SVC>_PLATFORM` or globally with `DOCKER_PLATFORM` in
  `~/.config/harbor/config`; set either to `none` to disable the pin for an image
  that has no host-arch build (`mysql:5.7` and other legacy tags are amd64-only,
  and emulation is better than a pull that fails outright). Run
  `harbor render <name> && harbor up <name>` to apply. No host-footprint change.

### Fixed
- **A flaky "Xdebug isn't loaded" probe could double-load the extension.**
  `php -m | grep -q '^xdebug$'` is a scheduling race under `set -o pipefail`:
  `grep -q` exits at the first match, PHP's next write lands on a closed pipe and
  takes SIGPIPE (141), and `pipefail` returns that as the pipeline's status — so
  a match intermittently read as "not found" (~3 in 400 measured) and Harbor
  added a second `-d zend_extension=` on top of the one brew's ini already loads.
  Replaced by `php_ext_loaded`, which reads the whole of `php -m` into a variable.
  Pinned by a regression test whose fake PHP keeps writing after the match, so the
  old form fails every time rather than one run in a hundred.
- **`harbor php use <ver>` could leave the host with no `php` at all.** brew has
  no atomic "relink as", so the old formula is unlinked before the new one can
  claim the symlinks — and a failure in that window left `$(brew --prefix)/bin/php`
  missing, breaking the plain terminal, the IDE and global composer from a command
  meant only to switch versions. Harbor never noticed, because it runs the
  versioned kegs directly. Now: re-running for the version that's already linked
  doesn't unlink at all, the formula is resolved up front (the newest PHP ships as
  the *unversioned* `php` formula), and every failure path re-links what was there
  and says so. `harbor describe` also reports `brew-linked: none` when nothing
  is linked.
- **Path multi-store served the homepage for every non-homepage URL, on every
  store.** The `REQUEST_URI` override was built from `$uri`, but `try_files
  $uri $uri/ /index.php`'s fallback is an internal redirect that reassigns
  `$uri` to `/index.php`, and `fastcgi_param` is evaluated after it — so Magento
  received `REQUEST_URI=/index.php` for every request and rendered the homepage
  with a 200, on unprefixed URLs as well as prefixed ones. `REQUEST_URI` is now
  built from `$harbor_request_uri`, a new `map` that strips the prefix from
  `$request_uri` — the one URI variable nginx never rewrites. Pinned by
  `test/test_store.sh`, which also asserts the override is never derived from
  `$uri` again.
- **Magento path multi-store now actually routes — `harbor store add --path`
  used to write the manifest and render no nginx at all.** Both vhost-emitting
  helpers returned early unless `multistore.mode` was `domain`, so a project
  with `mode: path` got a vhost with no trace of its prefixes: every prefixed
  URL fell through to `index.php`, Magento tried to route the prefix as a
  controller, and returned a bare 404 with nothing in any log. Path mode now
  renders three coordinated pieces, all keyed on `$request_uri` (never `$uri`,
  which both the rewrite and `try_files` change): a `map` selecting
  `MAGE_RUN_CODE`, a prefix-stripping `rewrite` at server scope, and a
  `REQUEST_URI` override taken from a second, prefix-stripping `map`. The
  override is the part that matters — Magento derives its path-info from
  `REQUEST_URI`, so without it the prefix reappears and the 404 persists.

### Added
- **Multi-store routing by website code as well as store view code.** The
  manifest gains a `multistore.websites:` map alongside `stores:`; entries in it
  render `MAGE_RUN_TYPE=website`, entries in `stores:` render
  `MAGE_RUN_TYPE=store`. Pick with `harbor store add … --website` / `--store`;
  store view stays the default, so manifests written before this keep their
  meaning. A project uses **one** scope, exactly as it uses one mode — setting
  both keys is rejected on render with a fix hint rather than silently merged,
  and the scope is locked once set (edit the manifest to switch). Route by
  website when the app's base URLs are set at website scope — the usual Magento
  multi-website layout — and by store view when they're per store view.
  `MAGE_RUN_TYPE` is emitted **singular** (`website`/`store`, matching
  `ScopeInterface::SCOPE_WEBSITE`); the plural `websites` seen in some
  hand-written Magento vhosts is the config-scope constant, not a run type.
- **A path store's prefix no longer has to equal its store code.** Harbor owns
  the prefix, so `multistore: { mode: path, stores: { default: /, de_de: de } }`
  serves store view `de_de` at `/de`. An entry whose value is `/` is the
  prefix-less default and becomes the `map` default. Path values are validated
  ([a-z0-9_-]) and rejected when they would shadow a Magento path (`static`,
  `media`, `setup`, `admin`, `rest`, `graphql`, `index.php`, …), which would
  otherwise rewrite every asset on the site into a store prefix.

### Changed
- **Path multi-store requires `web/url/redirect_to_base=0`.** Because nginx
  strips the prefix before Magento sees it, Magento finds itself at path `/`
  while the store's base URL is `/<seg>/`, concludes the URL is wrong, and 301s
  to `/<seg>/` — which nginx strips again, looping forever. Documented in `harbor
  store --help` and the README; Harbor does not write it for you. Note this is
  a *global* setting, so Magento stops auto-correcting to the base URL for all
  requests — harmless locally, but it travels with a database dump.
- **Path multi-store routes by store view and bypasses native per-website
  bootstraps.** Magento's own multi-website layout (`pub/<seg>/index.php`
  setting `MAGE_RUN_TYPE=website`) needs no map, no rewrite and no
  `redirect_to_base` change, because the prefix stays in `REQUEST_URI` and
  matches the base URL. Harbor's rewrite sends those requests to the root
  `pub/index.php` instead, so such bootstraps become dead code. Harbor does not
  currently render the native layout — noted in `harbor store --help`.
- **`harbor store add --path` no longer sets `web/url/use_store=1`.** It was
  wrong for Harbor's prefix scheme — Magento would prepend the store code on
  top of the prefix (`/<seg>/<code>/…`). The command now prints the
  `config:set … web/secure/base_url https://<name>.test/<seg>/` needed to make
  Magento emit the prefix, rather than writing Magento config itself: the store
  view may not exist when the store is registered.

### Added
- **Optional backing services — a project can now run with no database at
  all.** `harbor init` asks which backing services a project needs: an
  interactive picker (numbered, alphabetical — the catalog derived from
  `templates/compose/services/*.yml.tmpl`: `elasticsearch`, `meilisearch`,
  `mysql`, `opensearch`, `rabbitmq`) when stdin is a terminal and `HARBOR_YES`
  is unset, or `--services "mysql,opensearch"` directly. `--services ""` /
  `--services none` (or typing `none` at the prompt) selects no containers —
  the manifest gets an explicit `services: {}` and the project has no
  `docker-compose.yml`. A non-interactive caller (script, CI, `HARBOR_YES=1`)
  silently gets the framework default, so existing scripted `harbor init`
  calls behave exactly as before. The manifest's `services:` key is
  authoritative whenever present — including an explicit empty map — and only
  an absent key falls back to the framework default, so manifests written
  before this feature keep working unchanged.
- **`harbor services` — change a project's backing services after `init`.**
  `harbor services <name>` opens the same interactive picker as `init`, with
  the project's current services preselected (pressing Enter keeps what's
  there, not the framework default). `harbor services list <name>` shows
  what's on/off with resolved images; `harbor services add|rm <name>
  <svc>...` changes the list directly — adding a service already present, or
  removing one that isn't, is a no-op, not an error. Writes the manifest and
  re-renders, but deliberately does **not** run `harbor up` (rendering is
  idempotent, restarting containers isn't). `HARBOR_YES=1` is the only
  bypass — there is no `--yes` flag.
- **`harbor render` now confirms before a manifest edit drops a service whose
  data volume still exists** — shrinking `services:` (by hand, or via
  `harbor services rm`, which routes through the same gate) used to silently
  stop the container and detach its volume. Removing a service does **not**
  destroy data: the volume stays (scoped to `name: harbor-<name>`) and
  re-adding the service reattaches it intact — only `harbor destroy` drops
  volumes, and the prompt says so plainly. Only prompts when the dropped
  service's Docker volume actually exists — growing the list, or shrinking a
  service that was never `up`ed, never prompts; if Docker is unreachable the
  check assumes the data is at risk and prompts anyway. Declining leaves the
  manifest, compose file, and running containers untouched. `HARBOR_YES=1` is
  the only bypass, same as every other destructive-op confirm.
- **Magento now names every missing required service in one shot**, instead
  of crashing or reporting only the first — `harbor install`/`harbor render`
  on a Magento project missing `mysql` or `opensearch` (its required services;
  RabbitMQ is optional) says exactly which ones, with a `magento needs:
  <missing services>` fix hint.

### Changed
- **Lifecycle commands no-op instead of erroring on a service-less project.**
  `harbor up`/`down`/`restart <name>`/`logs <name>` print "nothing to
  start/stop/restart" (or "no container logs") and exit 0 for a project with
  no services, rather than dying on a missing compose file — a bulk/scripted
  run over every project shouldn't fail just because one of them has no
  database.
- **`harbor init`'s manifest and connection files are now conditional on the
  resolved service list**, not written unconditionally for every project. The
  manifest `db:` block is only emitted when `mysql` is selected;
  `connection.env`/`connection.txt` only get `DB_*` when `mysql` is selected,
  and `OPENSEARCH_*`/`RABBITMQ_*`/`MEILISEARCH_*`/`ELASTICSEARCH_*` only when
  their service is selected — Redis and Mailpit stay unconditional since
  they're shared, always-on Harbor services.
- **`harbor doctor` no longer requires the `pdo_mysql` PHP extension** for a
  project with no database service (an explicit `extensions:` entry still
  wins).
- **`harbor ps` shows a distinct `db:-` marker** for a project with no
  `mysql` service, instead of a stale or blank port.

### Fixed
- **`connection.env`/`connection.txt` no longer advertise services a project
  never runs.** Both files were written unconditionally for every project
  regardless of which services were actually configured — a plain Laravel
  project (mysql only) got live-looking `OPENSEARCH_HOST`/`RABBITMQ_HOST`/
  `MEILISEARCH_HOST`/`ELASTICSEARCH_HOST` entries for containers that were
  never part of its stack. Both files now only include entries for services
  the project actually has.
- **`harbor mysql`/`harbor db backup`/etc. now refuse up front with a fix
  hint, instead of crashing or misreporting "stack not running,"** when a
  project has no database configured. `harbor wire` skips the `DB_*` lines
  for Laravel/CodeIgniter/Symfony/plain projects (still wires Redis + mail)
  and refuses early, with a fix hint, for a DB-less Magento project (which
  requires a database).
- **`harbor destroy` no longer leaks a project's Docker volume when the
  project has no services.** `destroy` now also removes any volume named
  `harbor-<name>_*` directly, whether or not a compose file is present; the
  match is anchored so a project whose name is a prefix of another's (`shop`
  vs `shop2`) can never catch the wrong one.
- **`harbor ps` no longer conflates "no database service" with "has `mysql`
  but a missing/broken port allocation."** `db:-` used to mean both — the
  same marker for two very different states. `ps` now checks whether the
  project has a `mysql` service before loading its ports, rendering a
  distinct `db:?` for "has `mysql` but no allocated ports," separate from
  `db:-` for "no `mysql` service."
- **A hand-edited bare `services:` (the obvious YAML way to write "none") no
  longer gets a project silently stuck on the framework default.** Presence
  of the `services:` key is now tested with a real presence check
  (`manifest_key_present`, `lib/manifest.sh`), not `manifest_has` (a VALUE
  test that reads an empty value the same as an absent key) — before this,
  a bare `services:` line resolved back to e.g. `mysql`, and `harbor services
  add <name> mysql` then reported "no change" with no way to actually add it.
  `manifest_has` itself is unchanged (still used elsewhere for its existing
  value semantics); the new helper is additive.
- **`harbor services rm`/`add` declining its confirm gate now restores the
  manifest's previous `services:` line byte-for-byte, comment included** —
  it used to rebuild the line from the resolved value (`manifest_get`, which
  strips trailing comments) and could also mis-detect a bare `services:` as
  "key was absent," restoring by deleting the line instead of putting the
  bare line back. Restoration now snapshots and replays the raw line
  (`manifest_raw_line`/`manifest_set_raw_line`).
- **A partial `harbor services rm` (the project still has other services
  left) now actually stops the dropped service's container**, instead of
  only rewriting `docker-compose.yml` and leaving it running until an
  unrelated `harbor down` — `docker compose up -d` merely warns about
  "orphans" and Harbor never passed `--remove-orphans`. `harbor render`
  now stops (and removes, without `-v`) just the dropped service(s) before
  rewriting the compose file; the rest of the stack, and all volumes, are
  left untouched.
- **`harbor destroy` no longer reports success while leaking every volume
  when Docker is unreachable.** Its volume sweep (`docker volume ls -q |
  grep ... || true`) used to turn a failed listing into the same empty
  result as "no matching volumes," so `destroy` would unlink, release ports,
  and print "destroyed" while the project's volumes stayed on disk with no
  Harbor command left able to reach them. `destroy` now distinguishes the
  two, still unlinks/releases ports (those don't need Docker), and reports
  the volume sweep as failed with a fix hint instead of claiming full
  success.
- **`harbor init --services none` (or any DB-less selection) no longer
  reports a `db port` in its summary line** — the port belongs to a `mysql`
  service that was never provisioned.

### Added
- **`harbor restart` with no project name restarts Harbor itself** — equivalent
  to `harbor stop && harbor start` (shared stack, php pools, dnsmasq, nginx).
  Running project stacks are left alone; `harbor restart <name>` still restarts
  just that project's containers. nginx is a LaunchDaemon, so the bare form asks
  for sudo (the same touchpoint `stop`/`start` already use — no new one).
- **`harbor init`/`new`/`render` seed self-documenting import-pipeline samples**
  into `.harbor/`: a commented-out `import-rules` (with the project's real
  domain baked into the examples) and one sample hook per phase —
  `hooks/post-import.d/10-local-overrides.sql.sample` for pinning table records
  to local values on every import (base URLs, dev passwords, clearing live API
  keys) and `hooks/pre-import.d/10-trim-dump.sh.sample` for trimming the dump
  before load — plus a `hooks/README.md` documenting each phase's contract and
  env vars. Everything is inert until edited (`#` rules are ignored, `.sample`
  hooks are skipped), non-clobbering, and existing projects pick it up on their
  next `harbor render <name>`.
- **Per-command help: `harbor <cmd> --help` and `harbor help <cmd>`.** Every
  command now has a topic covering its purpose, exact usage, **every flag it
  parses**, real examples, and the gotchas that cost you an hour — `harbor down`
  also flushes the project's Redis; `harbor composer` bypasses the PHP shim so
  `php_ini`/Xdebug don't reach Composer itself; `harbor media pull` is
  `rsync --delete` and isn't confirm-gated; `harbor tool` won't infer the project
  from your cwd. Ask however you like — `harbor php --help`, `harbor php use
  --help` and `harbor help php` all land on the same topic. Subcommands can have
  their own topic, keyed `<cmd>-<sub>` and reached with no extra wiring — so far
  `harbor db sandbox --help`. Help prints
  to **stdout and exits 0** (so it pipes), unlike the terse `usage:` one-liners on
  misuse, which stay on stderr and now point at `--help`. Commands that wrap
  another tool (`run`, `composer`, `artisan`, `console`, `spark`, `magento`,
  `node`, `npm`) pass `--help` **through** to that tool; their Harbor docs are at
  `harbor help <cmd>`. `harbor help <topic>` completes in bash/zsh.
- **`harbor update [--check] [--stash] [--yes]`: self-update.** Fetches `origin`
  and **fast-forwards** the checkout to `origin/main` (ff-only — never a merge
  commit or history rewrite), then **force-reseeds** the agent skill into every
  project so improvements propagate (overwrites the managed skill files in place,
  preserving any extra files you added). `--check` reports pending commits without
  applying (read-only); `--stash` auto-stashes/restores a dirty tree (otherwise a
  dirty tree aborts with a hint). After updating it prints the version/commit
  delta and the changelog range, then gives **targeted next steps** based on what
  changed — platform templates → `harbor setup`; compose templates →
  `harbor render/up`; libs → effective next command — and runs `doctor`. *Host
  footprint:* none of its own — it updates the git checkout and writes each app's
  `.claude/skills/harbor/` (already committable, in the app's repo, git-ignored by
  Harbor); it may *recommend* `harbor setup`, but never runs sudo itself.
- **Unit test suite** (`test/`): a zero-dependency, pure-bash harness
  (`test/run.sh` + `test/lib.sh`) that runs on macOS system bash 3.2 like Harbor
  itself — no `bats`, no installs. Covers the pure-logic units:
  `manifest.sh` (the constrained-YAML parser — flow maps/lists, nesting, quoted
  commas, comments), `ports.sh` (index → port/Redis-index math, allocation,
  idempotency, backfill), `common.sh` (`valid_name`, `db_ident`, `render_str`
  templating, `config_get`, `resolve_project`), and `search-replace.php`'s
  serialized-length recompute. Run with `harbor test` (or `./test/run.sh`);
  pass a name filter to scope it: `harbor test manifest`. No host mutation —
  tests use throwaway temp dirs and never touch Docker, launchd, or the sandbox.
- **`harbor test [filter]`**: run Harbor's own unit suite from the CLI (thin
  wrapper over `test/run.sh`; exits nonzero on any failure).
- **MIT license** (`LICENSE`) and a License section in the README.
- **Projects are seeded with an agent skill.** `harbor init` (and therefore
  `harbor new`), plus `harbor render` for already-existing projects, copies
  `ai/skills/harbor/` into the project at
  `projects/<name>/.claude/skills/harbor/` (`SKILL.md` + `reference.md`), so any
  coding agent working in that project knows how to drive Harbor for the app —
  run commands under the pinned PHP, DB import/backup/sandbox, logs, Xdebug,
  manifest config, containerized tools — without re-reading Harbor each time.
  Committable (travels with the app) and non-clobbering, so a re-init never
  overwrites project-side edits (delete the dir to pull a fresh copy). The
  canonical source lives in `ai/skills/harbor/`.
- **`harbor db sandbox <sub>`: a project-independent scratch MySQL** on
  `127.0.0.1:3306` for testing and checking things out, with its own lifecycle so
  you can create and destroy throwaway databases without attaching them to a
  project. Subcommands: `create <db> [user] [pass]`, `drop <db> [user]`, `list`,
  `backup <db> [file]`, `restore <db> <file>`, `console [db]`, `up`, `down`,
  `destroy`, `status`. A Harbor-owned singleton stack (`docker/sandbox.yml`, from
  `templates/compose/sandbox.yml.tmpl`) — loopback-only, RAM-capped, lazily started
  on first use. Reversible: `harbor teardown` stops it, `--purge` drops its data
  volume. Port/image overridable via `SANDBOX_MYSQL_PORT` / `SANDBOX_MYSQL_IMAGE`
  (a `mariadb:*` image runs MariaDB). *Host footprint:* one Docker container +
  named volume (`harbor-sandbox`) bound to `127.0.0.1:3306` while running.
- `harbor logs clear [all|nginx|php|dnsmasq|<name>]`: truncate Harbor's log files
  under `var/log/` in place (default `all`; `<name>` = that site's nginx logs).
  Truncates rather than deletes, so daemons keep their open handles (no orphaned
  inode, effective immediately).
- **nginx logs are user-owned.** Harbor pre-creates the global and per-site nginx
  log files before its root master opens them (`open()` with `O_CREAT` never
  chowns an existing file), so they're born user-owned — root still writes, but you
  can `harbor logs clear` them without sudo. Applied on `setup` and every `nginx`
  reload/`link`.
- **Optional backing services via compose-fragment assembly.** The per-project
  `docker-compose.yml` is now assembled from one fragment per service
  (`templates/compose/services/<svc>.yml.tmpl` + optional `volumes/<svc>…`) driven
  by the manifest `services:`, instead of two fixed whole-stack templates.
  Bundled: `mysql`, `opensearch`, `elasticsearch`, `rabbitmq`, `meilisearch`. Add a
  service by dropping a fragment + a `ports.sh` slot — no new template per combination.
- **`services:` is an explicit `{ name: "image:tag" }` map** written by `harbor
  init` with pinned versions, so every service's version is visible and editable in
  place — change a value and `harbor render`, no separate key to add. The DB image
  lives in `services.mysql` (the `db:` map is just credentials); resolution is
  `services.<svc>` → config `<SVC>_IMAGE` → baked-in default. Legacy list-format
  manifests (`services: [ … ]` + `db.image`) are migrated in place on the next
  `harbor render`.
- **Elasticsearch** opt-in service: single node, `xpack.security` disabled for
  local dev, loopback `127.0.0.1:<base+5>`, heap-capped (`ELASTICSEARCH_HEAP`),
  healthcheck; host/port in `connection.txt`.
- **Meilisearch** opt-in service: loopback `127.0.0.1:<base+4>`, healthcheck,
  indexing-memory cap; host + master key written to `connection.txt`/`connection.env`
  for Laravel Scout. `ports_ensure` backfills new port slots so existing projects
  can adopt a service via `harbor render` without re-allocating.
- `harbor render <name>`: regenerate a project's `docker-compose.yml` +
  `connection.env` from the manifest — the missing "edit the manifest, re-run the
  command" path for `services:` version changes (also materializes a legacy
  list-format `services:` into the map).
- **MariaDB support** as a MySQL-compatible image swap on the `mysql` entry (e.g.
  `services: { mysql: "mariadb:11.4" }`). The compose service stays named `mysql`
  (so `harbor mysql`/`db` keep working) and Harbor emits an engine-aware server
  command — MariaDB drops MySQL 8's `--default-authentication-plugin` flag, which
  it rejects.
- Per-project **scripts** dir: `projects/<name>/.harbor/scripts/`. Executables
  dropped there are on `PATH` — under the project's pinned PHP — for
  `harbor run <name> <script>` and `harbor shell <name>`, so a `scripts/invoice`
  becomes `harbor run <name> invoice`. It's committable (unlike the generated
  `.harbor/bin/` tool shims), so project-specific commands travel with the app;
  `harbor init` scaffolds it with a README. *(Host footprint: none — inside the
  project's `.harbor/`.)*
- `harbor stop` / `harbor start`: pause/resume Harbor (bootout/bootstrap the
  nginx daemon + dnsmasq/php agents, stop/start the shared stack) so its ports
  (`:80 :443 :6379 :1025 :8025`) can be handed to another Docker stack during
  migration. Keeps plists, resolver, and certs; `status` reports `STOPPED` and
  skips self-heal while paused. *(Host footprint: no new files; a `var/stopped`
  flag only.)*
- `.shellcheckrc` (sourced-library false positives) — codebase is now
  shellcheck-clean.

### Changed
- **`db import` is much faster on real-world dumps.** Two fixes to where the
  time actually went: (1) the load runs with `innodb_flush_log_at_trx_commit=2`
  (fsync per second instead of per commit — the classic dump-replay killer;
  restored to its previous value after) and `UNIQUE_CHECKS=0`, the same flag
  mysqldump puts in its own headers; (2) decompress + DEFINER-strip run as one
  streaming pass instead of copy-then-rewrite-in-place — half the disk IO.
  Each heavy phase now prints its own duration (`prepared in 2m 1s`,
  `loaded in 9m 40s`, …) so a slow import says where the time went. (A
  server-side `LIKE` pre-filter for the search/replace pass was prototyped and
  measured 2.5× *slower* than streaming rows into PHP — not shipped.)
- **`db import` ends with a summary: dump size, elapsed time, status.**
  `ok import complete -> shop (4.5G dump in 12m 4s)` — and a load that came
  from a truncated dump repeats its loud warning right above the summary, so
  the partial status can't scroll out of sight.
- **`harbor status`/`ps` color running projects green.** A project whose stack is
  `up` is printed as a green row so the running projects stand out at a glance;
  down projects stay uncolored. Color is TTY-gated (no escape codes when the output
  is piped or redirected).
- **README** now states up front that Harbor is **macOS-only** and **unstable /
  under active development**, that **code contributions are not accepted** (issues
  welcome), and documents the per-project **Claude Code agent skill** (new "For AI
  coding agents" section).
- **Optional `<name>` for the in-project commands.** `run`, `composer`, `artisan`,
  `console`, `spark`, `magento`, `node`, `npm`, `shell`, `mysql`, and `redis` now
  infer the project when you omit the name — from `$HARBOR_PROJECT` (set by
  `harbor shell`) or from the cwd being under `projects/<name>/` (symlinked projects
  resolved). So `harbor run invoice` / `harbor artisan migrate` / `harbor mysql`
  work from a project dir; an explicit existing-project arg still wins. (Reusable
  `resolve_project`/`cwd_project` helpers in `common.sh`.)
- Templating: added `render_str` (renders a template to stdout) so compose
  fragments can be concatenated; `render` now wraps it. Existing `render` calls
  are unchanged.

### Added
- **`db import` validates rules and hooks before doing any work.** A malformed
  rule (missing `=>`, empty FROM, invalid `re:` regex — each named with its
  line number) or a shell hook with a syntax error aborts in milliseconds
  instead of after the backup/load; a hook that would be silently skipped (not
  executable, or a `*.sql` misplaced in `pre-import.d/`) warns with the fix.
  `--replace` args are checked for `OLD=NEW` shape at parse time.
- **`db import` refuses a truncated dump up front.** A dump whose last line ends
  mid-statement (interrupted download/export) used to "succeed" partially:
  every table after the cut was silently missing — a Magento dump cut in the
  s's loads with no `store` or `url_rewrite` and nothing tells you. The import
  now dies before load with a re-download hint; `--force` keeps its best-effort
  meaning and loads the partial dump anyway (with a warning).

### Fixed
- **Four more silent-death guards squashed** — the `[ cond ] && …`-as-last-statement
  bug that once killed `db import` (CLAUDE.md §3). In each case a false guard
  became the function's return value, so a plain caller under `set -e` died with
  no error output at all:
  - **`harbor setup` on a vhost with no log directives.** `nginx_ensure_logs_all`
    returned nonzero when a site conf's `access_log`/`error_log` lines couldn't
    be parsed — which is exactly what a stale/hand-edited vhost looks like.
  - **`harbor render`/`init` for a service with no volume fragment.**
    `_compose_assemble` is called plainly as `… > docker-compose.yml`, so adding
    a volume-less service (the documented optional case) would have silently
    aborted stack generation.
  - **`installed_php_versions` when the last listed version isn't installed** —
    `setup`/`start`/`stop` all iterate it, so a missing newest PHP could have
    taken them down.
  - **`link_php_value_block` for a project with no `php_ini:` keys** — the
    default for a fresh `harbor init`; harmless at today's call site, but a trap
    for the next plain caller.

  Pinned by new `test/test_nginx.sh`, `test/test_compose.sh`, `test/test_link.sh`
  and added `installed_php_versions` coverage in `test/test_common.sh`.
- **`re:` regex rules actually work now — and can no longer blank data.** The
  documented bare-pattern form (`re:UA-\d+-\d+ =>`) was passed to
  `preg_replace()` without delimiters, which always fails — and the failure
  returned `null`, so a doc-following regex rule could overwrite matched
  columns with empty values. Bare patterns are now wrapped in delimiters
  automatically, compile-checked up front, and a regex that fails at runtime
  leaves the original value untouched.
- **The serialized-safe search/replace survives unique-key collisions and
  vanishing tables.** A rewrite that collapses two values onto one (staging +
  prod emails both mapped to `.test` colliding on `customer_entity`'s unique
  email index) used to abort the whole pass with a raw stack trace, as did a
  table dropped mid-scan (e.g. a concurrent import reloading the DB). Colliding
  rows and vanished tables are now skipped with a warning and a summary count;
  everything else still gets rewritten.
- **The serialized-safe search/replace no longer OOMs on large databases.** It
  read each table with a *buffered* `SELECT *` — the whole table in PHP memory —
  and died at the 128M CLI default on any real Magento DB. Reads now stream
  row-by-row (unbuffered, with a second connection for the UPDATEs), and the
  pass runs with `memory_limit=512M` headroom for large serialized blobs.
- **A non-executable file in a hooks dir no longer kills `db import` silently.**
  The hook runner's `[ -x "$f" ] && {…}` made the function return nonzero when
  the last entry wasn't executable, and `set -e` aborted the whole import with
  **no error output** — right after "stripping DEFINER clauses". The seeded
  `.sample` hooks triggered this on every project. Non-executable files are now
  skipped cleanly, and a hook that genuinely fails now aborts loudly with
  `hook failed: <file> (<phase>)` instead of a silent exit.
- **An import-rules file that strips to nothing no longer triggers the
  search/replace pass.** Blank lines survived the comment filter, so a
  fully-commented rules file (exactly what init now seeds) would have run the
  full serialized-replace table scan with zero rules on every import.
- **Asking for help never runs anything.** `--help`/`-h` used to be data to most
  commands, with real consequences: `harbor logs nginx --help` **hung** (any extra
  arg means "follow", so it started `tail -F`), `harbor xdebug on --help`
  **enabled Xdebug and restarted every PHP-FPM pool**, `harbor secure host --help`
  added `--help` as a certificate SAN, and `harbor php --help` reported
  `unsupported version '--help'`. Harbor now answers the flag wherever *it* is the
  one parsing — `harbor php use --help`, `harbor db sandbox create --help` and
  `harbor update --check --help` all print help — while still handing it over once
  argv belongs to a tool, so `harbor composer --help` reaches Composer and
  `harbor tool shop wkhtmltopdf --help` reaches wkhtmltopdf.
- **Docs: removed two flags that never existed.** `harbor link --wildcard` and
  `harbor redis flush` were documented in `README.md`, `plan.md` and the
  per-project **agent skill** but are absent from the code — so an agent following
  the skill would run a command that fails. The `*.<name>.test` SAN is added
  automatically for a Magento project with `multistore.mode: domain` (no flag);
  to flush, use `harbor redis <name> FLUSHDB` or `harbor down <name>` (which
  flushes all four of the project's indices).
- **Xdebug on the project CLI now connects like it does on the web.** With
  `harbor xdebug on`, the CLI shim set `xdebug.mode`/`start_with_request` but not
  the connection settings FPM gets, so it fell back to xdebug's `localhost`
  default — which resolves to `::1` first on macOS. An IDE listening on IPv4
  `127.0.0.1:9003` therefore never saw a session: breakpoints hit on a web request
  but silently did nothing on `XDEBUG_TRIGGER=1 harbor magento …`/`artisan`/
  `composer`. Both surfaces now build their flags from one `xdebug_dflags` helper
  (`client_host=127.0.0.1`, `client_port=9003`, `discover_client_host=false`), so
  web and CLI debugging can't drift apart again. Still trigger-based, so leaving
  Xdebug on stays cheap and unrelated CLI commands don't pay for it. (No action
  needed; the shim is regenerated on the next `harbor run`/`magento`/etc.)
- **Manifest `php_ini:` now applies to the project CLI, not just web.** The
  per-project php shim (`cli_php_pathdir`) previously injected only Xdebug flags,
  so `harbor magento`/`run`/`composer`/`artisan` ran at the host brew CLI's default
  `memory_limit` (typically 128M) — a Magento `setup:di:compile`/`indexer:reindex`
  would OOM despite `php_ini: { memory_limit: 2G }` in the manifest (that only
  reached web requests via FPM's `PHP_VALUE`). Harbor now emits the manifest
  `php_ini` block as `-d key=value` flags into the CLI shim too, mirroring the FPM
  path, so the manifest is the single source of truth for web **and** CLI ini. The
  shim is now keyed per project so two projects sharing a PHP version but pinning
  different ini don't clobber each other. (No manifest change needed; regenerated
  on the next `harbor run`/`magento`/etc.)
- **Containerized tool shims now work with entrypoint-based images.** The generated
  `.harbor/bin/<bin>` shim appended the binary name as a command argument, which
  double-invoked images that set the binary as their `ENTRYPOINT` (wkhtmltopdf,
  pandoc, ffmpeg, ghostscript) — e.g. `wkhtmltopdf wkhtmltopdf …`, misparsing the
  first real argument as an input URL. Shims now default to
  `docker run --entrypoint <bin>` so the binary runs once. Images whose entrypoint
  does required init (s6-overlay wrappers like `linuxserver/libreoffice`) instead
  use `mode: command` — the binary runs as the container CMD *through* the image's
  `/init`, so it isn't bypassed. The catalog carries the mode; override per tool
  with manifest `tools.<name>.mode: entrypoint|command`. Re-run
  `harbor tools sync <name>` to regenerate existing shims.
- **`wkhtmltopdf` catalog image tag corrected** to `surnet/alpine-wkhtmltopdf:3.23.4-0.12.6-full`;
  the previous `3.0.1-0.12.6-full` tag does not exist on Docker Hub (pull 404'd).

### Added
- `harbor php use <ver>`: switch the **brew-linked** CLI `php` (what a plain
  terminal / IDE / global composer resolves) — unlinks the currently-linked
  version and `brew link --overwrite --force`s the requested one, verifying `php
  -v` afterwards. Separate from Harbor's per-project pinning: `harbor run`/nginx
  always use each project's own version regardless of what's linked here. (Touches
  brew's own link symlinks only — reversible via another `use`; no config-dir
  writes.)
- `harbor db import --force` (also honored by `db pull`): pass `--force` to
  `mysql` so it skips statements the server rejects and continues, instead of
  aborting the whole load. Unblocks prod dumps that `INSERT` explicit values into
  a **generated column** (e.g. Laravel Pulse's `pulse_aggregates.key_hash` →
  `ERROR 3105`); the offending rows are skipped (those tables land empty).

### Fixed
- `harbor db import`/`db pull`: DEFINER stripping no longer dies with
  `sed: RE error: illegal byte sequence` on dumps containing non-UTF-8 bytes
  (latin1/binary column data). The DEFINER `sed` now runs under `LC_ALL=C` so BSD
  sed processes the dump byte-wise (matching the serialized-safe replace step,
  which already did).
- Per-project `php_ini:` resource limits now actually apply. The FPM pool set
  `memory_limit` / `upload_max_filesize` / `post_max_size` / `max_execution_time`
  as `php_admin_value`, which PHP-FPM does not let a site's `PHP_VALUE` (how the
  manifest `php_ini:` is injected) or `ini_set()` override — so those keys were
  silently clamped to the pool default. They are now `php_value`, keeping the
  pool value (e.g. `PHP_MEMORY_LIMIT`, default 2G) as the default a project can
  raise/lower. `error_log` and the CA-bundle paths stay `php_admin_value`
  (Harbor-owned/security). Run `harbor php sync` to apply to running pools.
- **Magento on-demand static assets now materialize in developer mode.** The
  Magento vhost body (`templates/nginx/body/magento.conf.tmpl`) routed missing
  static files to `static.php?resource=$1`, but inside the file-extension
  `location ~* \.(js|css|woff|ttf|…)$` block `$1` is the matched *extension*, so
  `static.php` received `resource=ttf` (→ "Requested path 'ttf' is wrong", 404).
  Assets already on disk (e.g. merged CSS) were served by `try_files`, but every
  file generated on first request (fonts, images, individual JS/CSS) 404'd and
  `pub/static/<area>/` never populated. Now uses Magento's canonical
  `if (!-f $request_filename) { rewrite ^/static/?(.*)$ /static.php?resource=$1 last; }`,
  whose own capture is the full resource path. Re-run `harbor link <name>` to
  regenerate the vhost (affects every Magento project).

### Added
- Committed Claude Code **Agent Skills** (`.claude/skills/`): `harbor-new-project`,
  `harbor-migrate-project` (existing-app onboarding + legacy gotchas), and
  `harbor-contributing` (rules + after-every-change checklist for modifying Harbor)
  — so developers/agents follow the same path.
- README **How-to (recipes)** section: new project, migrating an existing app,
  EOL PHP via the shivammathur tap, Xdebug on EOL PHP (prebuilt, not pecl), the
  MySQL 8 `caching_sha2_password` fix, changing a project's PHP version, and
  switching between Harbor and another Docker stack.
- Supported PHP set widened to `7.2 7.3 7.4 8.0 8.1 8.2 8.3 8.4 8.5` (EOL versions
  installable via the `shivammathur/php` tap). A version only gets a pool once its
  `php-fpm` exists; `harbor php sync` picks up a newly-installed version.

### Fixed
- Launcher resolves `HARBOR_ROOT` robustly: honors an explicit `HARBOR_ROOT` env
  override, else follows symlinks to the repo, and fails with a clear, actionable
  message (symlink don't copy / set `HARBOR_ROOT`) instead of a cryptic
  "lib/common.sh: No such file" when the script was *copied* onto PATH.
- CLI Xdebug injection (`harbor run`/`composer`/…) now detects whether the PHP
  version's own config already loads Xdebug and only adds `-d zend_extension`
  when it doesn't — mirrors `fpm-exec.sh`, avoiding a double-load error when a
  `pecl`/tap install enabled Xdebug in brew's php.ini. Harbor now controls Xdebug
  correctly with or without that ini line, so **no manual edit of brew's php.ini
  is needed**.
- MySQL compose defaults to `--default-authentication-plugin=mysql_native_password`
  so older PHP (7.2/7.3) mysqli clients can connect over TCP.
- Framework auto-detection now recognizes **CodeIgniter 3**: check
  `system/core/CodeIgniter.php` (not `system/CodeIgniter.php`) and match the
  `codeigniter/framework` composer package (not only `codeigniter4/framework`).
  CI3 projects were mis-detected as `plain`.

### Fixed (code review)
- **search-replace.php**: collect ALL primary-key columns and build a
  multi-column `WHERE` — composite-PK tables (e.g. Magento `catalog_category_product`,
  Laravel pivots) were matched by only the last PK column, updating multiple rows
  to one row's value (data corruption).
- **db import**: all temp files now live under one `mktemp -d` dir removed by an
  `EXIT` trap, so a mid-pipeline failure no longer leaks temp files / the mysql
  wrapper.
- **db create**: `db_ident` centralized in `common.sh` and now *validates*
  identifiers (rejects non `[A-Za-z0-9_]`), and the password is escaped for its
  SQL literal — explicit `db`/`user`/`password` args can no longer break or
  inject the root SQL.
- **db import `--stream-replace`**: `sed` now uses a `\001` delimiter and escapes
  regex metacharacters, and reports (not silently swallows) a failed rule — rules
  containing `|`, `&`, `.`, etc. work.
- **nginx**: `nginx_reload`/`nginx_test` announce their `sudo` (per CLAUDE.md
  "never sudo silently").
- **store add/rm**: store codes validated (`[A-Za-z0-9_]`) so the anchored `grep`
  can't over-match and drop unrelated stores.
- **manifest parser**: `_mf_split_top` tracks quote state, so a quoted value
  containing a comma (`["a, b", c]`) no longer splits incorrectly.

### Changed
- Cleanup pass (no behavior change): added `manifest_pairs` helper and used it in
  `link_php_value_block`, `link_map_block`, and `_store_pairs` (removes two
  hand-rolled flow-map loops and a per-key manifest re-read); promoted
  `_cli_php_pathdir` → public `cli_php_pathdir`; `_wait_ready` now batches one
  `docker inspect` for all containers; `db_import` caches the project PHP path;
  extracted `_tls_ensure_sans`; added `HARBOR_SHARED_REDIS` constant; completion
  emits `$HARBOR_PHP_VERSIONS`; dropped redundant `+ 0` in port math.
- Project blueprint: `plan.md` (full design + decisions) and `README.md`
  (user-facing docs).
- Agent guide `CLAUDE.md` (critical rules, anti-host-pollution rules, best
  practices, changelog discipline, mandatory after-every-change checklist:
  healthcheck → `.gitignore` → CHANGELOG → CLAUDE.md → security/perf/usability).
- Repo `.gitignore` (ignores rendered `etc/`, runtime `var/`, `certs/`, backups,
  project source; keeps platform dirs via `.gitkeep`).
- **Phase 1 (Foundation):** `bin/harbor` dispatcher (`help`/`version`/`doctor`,
  planned-command stubs); `lib/common.sh` (paths, logging, templating, php +
  lock + config helpers); `lib/manifest.sh` (constrained-YAML manifest parser,
  no yq); `lib/ports.sh` (per-project port + shared-Redis DB-index allocator,
  lock-guarded); `lib/doctor.sh` (report-only host + per-project checks);
  `lib/launchd.sh` (com.harbor.* unit helpers).

### Changed
- Reconciled the early scaffolding to the final design: bash **3.2-safe**
  (no associative arrays / no `flock` → mkdir-based locking), per-version FPM
  sockets under `var/run/`, shared-Redis DB-index allocation (Redis/Mailpit port
  slots removed).

### Removed
- **In-repo clone-traffic workflow and its daily commit.** The
  `traffic-clones` GitHub Action, `record-clones.sh`, and the `.github/traffic/`
  store are gone — clone-traffic tracking moved to a central, external collector
  that snapshots this repo (and others) and serves one Shields badge per repo
  from GitHub Pages, so Harbor's history no longer takes a daily
  `chore(traffic)` commit. The README **Downloads** badge now reads from that
  Pages endpoint (a CDN — reliable, no origin 524) instead of a count baked into
  the repo.
- `lib/php.sh` switcher-era scaffold (superseded by concurrent ondemand pools,
  to be implemented in Phase 3).

### Fixed
- Harbor's dnsmasq port changed **5353 → 5354**: 5353 is the reserved mDNS/Bonjour
  port and conflicts with system multicast DNS. Overridable via config `DNS_PORT`.
- TLS now relies on **exact per-site SANs** (added at `harbor link`), not a bare
  `*.test` wildcard — Secure Transport/browsers reject wildcards directly under
  the reserved `.test` public suffix. One-level `*.<name>.test` (subdomain stores)
  is still honored. (Verified on macOS during Phase 2.)
- `nginx -t` runs under `sudo` during setup: this nginx binds listen sockets on
  `:80/:443` during config test, which a non-root user can't do.

### Phase 8 (Lifecycle, ergonomics, safety) — added
- `harbor new` (one-shot scaffold→init→up→wire→install→link→open); `status`
  (health + **self-heal** of dead `com.harbor.*` units, sudo-free port probes),
  `ps`/`list` (project table), consoles `mysql`/`redis`/`shell`, `open`, `secure`
  (reissue cert), `mail [up|down]`, `completion bash|zsh` (commands + project
  names). Full `harbor.md` runbook.
- **End-to-end verified live:** two projects on different PHP versions (8.3 + 8.4)
  served concurrently over trusted HTTPS; **provider→consumer HTTPS call verified
  via the CA bundle** (no `verify=false`); exact per-site SANs; no port collision;
  clean `destroy`.

### Phase 7 (Installers, DB lifecycle & data) — added
- `harbor db create|drop|backup|import` against the project's MySQL (root via
  `MYSQL_PWD`); credential convention db=user=pass=project. `import` is the full
  hookable pipeline: decompress → strip DEFINER → pre-import hooks → load
  (FK off) → **serialized-safe search/replace** (`lib/search-replace.php`,
  recomputes `s:N:` lengths) → post-import hooks (`*.sql` piped, scripts run) →
  optional Magento `--reconfigure`; auto-backup first; `--replace`, `--no-backup`,
  `--keep-definers`, `--no-hooks`, `--no-rules`, `--stream-replace` flags;
  `import-rules` file support.
- `harbor install|seed` (framework dispatch); Magento generates a wired,
  re-runnable `setup:install` script + local-DX pack (developer mode, disable 2FA,
  reindex) + `--reconfigure`. `harbor db pull` / `harbor media pull` over ssh
  (manifest `remote:`). `harbor store add|list|rm` (one mode per project;
  domain → nginx MAGE_RUN map + SAN, path → `web/url/use_store`).
- Verified live: create/backup/drop; full import pipeline incl. DEFINER strip,
  pre/post hooks, and serialized `s:8:"live.com"`→`s:10:"local.test"` with correct
  length recomputation; Magento install-script wiring; multistore map generation.

### Phase 6 (Config injection & tooling) — added
- `harbor wire`: surgical, allowlist-only, idempotent config injection with
  `.harbor-bak` backup — Laravel/CI4 `.env` per-key upsert, Symfony `.env.local`
  only, plain/CI3 `.harbor/connection.php`, Magento deferred to `install`.
- `harbor run` (any cmd under the project's pinned PHP, in its dir) + `composer`
  (pinned) + `artisan`/`console`/`spark`/`magento` passthroughs + `node`/`npm`
  via nvm (`.nvmrc`/manifest, prompts to install). **Xdebug-on-CLI**: a generated
  `php` shim adds Xdebug `-d` flags on demand when `xdebug on`.
- `harbor tool` / `harbor tools sync`: containerized CLI tools via shims in
  `.harbor/bin/` (project dir + `$TMPDIR` mounted at identical paths); built-in
  catalog + manifest override. No host installs. Verified: wire idempotency +
  backup, composer/run pinning, live Xdebug-on-CLI, tool shim + container run.

### Phase 5 (Per-project Docker stacks) — added
- `harbor init` (write manifest, allocate ports + Redis indices, render compose +
  connection files + `.harbor/.gitignore`); compose templates default (MySQL) and
  magento (MySQL + OpenSearch + RabbitMQ), loopback-bound, RAM-capped, with
  healthchecks; `harbor up` (with readiness wait) / `down` (Redis flush, keeps
  MySQL volume) / `restart` / `destroy` (drop volumes + ports + vhost) / `logs`.
  Compose files are fully rendered by Harbor (no `--env-file`). Verified: host PHP
  connects to the project's MySQL on its allocated port, Redis flush-on-down,
  volume persistence, and clean destroy.

### Phase 4 (Site provisioning) — added
- `harbor link <name>` / `harbor unlink <name>`: render a Harbor-owned nginx vhost
  (`etc/nginx/sites/<name>.test.conf`), add the site's **exact** cert SAN, reissue
  the shared cert, reload nginx. Framework auto-detection + manifest override;
  docroot detection (Magento `pub/`, Laravel/CI4/Symfony `public/`, Symfony legacy
  `web/`, CI3/plain root); per-site PHP routing; `fastcgi_param HTTPS on`,
  `client_max_body_size 128M`, `fastcgi_read_timeout`; per-site `PHP_VALUE` from
  manifest `php_ini`; custom `.harbor/nginx.conf` include; Magento domain-multistore
  `MAGE_RUN_CODE/TYPE` map. Verified: `https://hello.test` serves with a trusted
  cert (exact SAN), HTTP→HTTPS redirect, `https=on`, correct PHP version.

### Fixed
- Xdebug toggle now controls **`xdebug.mode`** (off vs debug,develop) rather than
  loading the extension — the host's brew PHP already loads Xdebug (and defaults
  `xdebug.mode=develop`, which has overhead). `harbor xdebug off` now genuinely
  makes it inert; still no brew config edits. `fpm-exec.sh` only adds
  `zend_extension` when the version doesn't already load it. (Host cleanup: the
  user's manually-added `zend_extension=xdebug.so` lines were removed from
  `php.ini` 8.1–8.5 — backed up to `php.ini.harbor-bak` — so the default baseline
  has no Xdebug and Harbor loads it on demand; off = fully unloaded.)

### Phase 3 (PHP control & Xdebug) — added
- `harbor php` (pool status with default marker / loaded / socket), `harbor php
  <ver>` (set default for new sites), `harbor php sync` (re-create pools for
  installed versions, drop uninstalled). `harbor xdebug on|off|status` toggles
  Xdebug across pools by rewriting `var/xdebug` and restarting pools (fpm-exec
  layers `-d` flags; no brew php config touched). Verified: status/set/sync work,
  toggle restarts pools, `xdebug.so` loads.

### Phase 2 (Host setup & teardown) — added
- `harbor setup` / `harbor teardown`; Harbor-owned dnsmasq (`:5354`) + resolver,
  wildcard cert + CA bundle, per-version ondemand FPM pools (LaunchAgents),
  own nginx (LaunchDaemon `:80/:443`), shared Mailpit+Redis stack; global config
  at `~/.config/harbor/config`. Verified end-to-end: DNS, pools, sockets, nginx,
  shared stack all up; brew nginx/php/dnsmasq config dirs untouched.

<!--
Categories (Keep a Changelog): Added · Changed · Deprecated · Removed · Fixed · Security
Add every behavior/command/config/host-footprint change here, in the same commit.
Flag host-footprint changes (files outside the repo, sudo, launchd units) explicitly.
On release, move these under: ## [x.y.z] - YYYY-MM-DD
-->
