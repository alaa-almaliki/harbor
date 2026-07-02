# Changelog

All notable changes to Harbor are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Per-project **scripts** dir: `projects/<name>/.harbor/scripts/`. Executables
  dropped there are on `PATH` — under the project's pinned PHP — for
  `harbor run <name> <script>` and `harbor shell <name>`, so a `scripts/invoice`
  becomes `harbor run <name> invoice`. It's committable (unlike the generated
  `.harbor/bin/` tool shims), so project-specific commands travel with the app;
  `harbor init` scaffolds it with a README. *(Host footprint: none — inside the
  project's `.harbor/`.)*
- `harbor php exec [<ver>] [--xdebug|--profile] <args...>`: run the PHP CLI at a
  chosen version without typing its full brew path. Version resolves from a
  leading bare `<ver>` (or `--php <ver>`) → a `.php-version` in the cwd → the
  Harbor default. `--xdebug` attaches the debugger (`127.0.0.1:9003`, connects
  immediately via `start_with_request=yes`); `--profile` enables the profiler and
  writes cachegrind files to `var/log/xdebug/`. Both apply to that single call
  only — no FPM pool needed, and brew's php ini is never touched. *(Host
  footprint: none; profiler output stays under `var/`.)*
- `harbor stop` / `harbor start`: pause/resume Harbor (bootout/bootstrap the
  nginx daemon + dnsmasq/php agents, stop/start the shared stack) so its ports
  (`:80 :443 :6379 :1025 :8025`) can be handed to another Docker stack during
  migration. Keeps plists, resolver, and certs; `status` reports `STOPPED` and
  skips self-heal while paused. *(Host footprint: no new files; a `var/stopped`
  flag only.)*
- `.shellcheckrc` (sourced-library false positives) — codebase is now
  shellcheck-clean.

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
