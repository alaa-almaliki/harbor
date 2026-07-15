# Harbor — Agent Guide

Instructions for any AI agent building or modifying Harbor. **These rules
override default behavior. Follow them exactly.**

Harbor is a **hybrid local PHP dev platform** for macOS: PHP-FPM/nginx/Xdebug/
dnsmasq/TLS run natively (as Harbor-owned launchd units), while databases/search/
queues run in Docker. The goal is **low RAM, low clutter, zero pollution of the
host**. Read `plan.md` (full design + decisions) and `README.md` (user-facing
docs) before changing anything. The plan and README are the source of truth — if
your change contradicts them, update them in the same commit.

Implementation is **bash** (no runtime language deps). Target macOS + Apple
Silicon + Homebrew.

---

## 1. Critical rules (non-negotiable)

1. **Never pollute the host.** Do not write into Homebrew's config dirs
   (`$(brew --prefix)/etc/nginx`, `…/etc/php/*`, `…/etc/dnsmasq*`). See §4.
2. **Harbor owns its config.** Every nginx/php-fpm/dnsmasq config is rendered
   from `templates/` into Harbor's `etc/`, and Harbor runs its **own** instances.
3. **Loopback only.** Every published port and service UI binds `127.0.0.1`,
   never `0.0.0.0`. No LAN exposure, ever.
4. **Code stays on the host.** Containers mount **only their own data volumes** —
   never project source. PHP reads code natively.
5. **The manifest is the source of truth.** `projects/<name>/.harbor/harbor.yml`
   drives everything; commands *read* it and *generate* derived files. Never make
   a derived file (compose, vhost, connection.env) authoritative.
6. **Everything reversible.** Every install/link/allocate has a matching
   uninstall/unlink/release. `harbor teardown` must restore the host to its
   pre-Harbor state. If you add something that touches the system, add its undo.
7. **Idempotent.** Every command is safe to re-run. Setup, sync, render, allocate
   must converge, not duplicate.
8. **Surface sudo.** The only allowed sudo touchpoints are the nginx
   LaunchDaemon and `/etc/resolver/test`. Never run `sudo` silently — announce it
   and explain why. Add no new sudo without explicit human sign-off.
9. **No host installs for app dependencies.** External binaries (wkhtmltopdf,
   ghostscript, soffice, ffmpeg…) are containerized via shims (manifest `tools:`),
   never `brew install`ed for a project.
10. **Never commit secrets or runtime state.** `connection.env`, `compose.env`,
    generated compose/vhost/shims, `var/` are gitignored. Only the manifest,
    `import-rules`, `hooks/`, and `scripts/` (per-project scripts, on PATH for
    `run`/`shell`) are committable.

---

## 2. Anti-host-pollution rules

This is the project's defining constraint. Concretely:

- **nginx** — render `etc/nginx/nginx.conf` + `etc/nginx/sites/*.conf`; run via the
  `com.harbor.nginx` LaunchDaemon (`nginx -c etc/nginx/nginx.conf`). Do **not**
  drop files in brew's `servers/`, do **not** edit brew's `nginx.conf`. Reference
  brew's `mime.types` by absolute path (read-only) only.
- **php-fpm** — render `etc/php/<ver>/fpm.conf`; launch with `--fpm-config`. Do
  **not** edit brew's `php-fpm.d/` or pool defaults.
- **php / xdebug** — configure via `-d` flags at launch (and per-site
  `fastcgi_param PHP_VALUE`). Do **not** write into `…/etc/php/*/conf.d/`. Manifest
  `php_ini:` is applied to **both** surfaces from the same source: FPM via
  `link_php_value_block` (`PHP_VALUE`) and the project CLI via `cli_php_pathdir`
  (`-d` flags in the per-project php shim). Keep the two in sync — a php_ini change
  that only reaches one surface (e.g. `memory_limit` on web but not
  `harbor magento`) is a bug. **Xdebug obeys the same both-surfaces rule, via one
  helper:** `xdebug_dflags <ver>` (`lib/common.sh`) is the *only* place the flags
  are built, and both `lib/fpm-exec.sh` and `cli_php_pathdir` call it — never
  hand-roll the flag string in either (that's exactly how the CLI silently lost
  `client_host` and CLI debugging broke while web worked). Xdebug
  is toggled via **`xdebug.mode`** (`off` vs `debug,develop`), NOT by loading the
  extension — the host's brew PHP may already load Xdebug (and default
  `xdebug.mode=develop`). Only add `-d zend_extension=…` when the version doesn't
  already load it. Pin `xdebug.client_host=127.0.0.1` — the `localhost` default
  resolves to `::1` first on macOS, so an IDE on IPv4 never sees the session.
  Never edit brew ini files.
- **dnsmasq** — run Harbor's own instance (`dnsmasq -C etc/dnsmasq/harbor.conf`,
  port 5354) via `com.harbor.dnsmasq`. Do **not** edit brew's `dnsmasq.conf` or
  drop files in `dnsmasq.d/`.
- **TLS** — certs live in `certs/`; build `harbor-ca-bundle.pem` there. Don't touch
  system cert stores beyond mkcert's own `-install` (user-run, not us).
- **The ONLY files Harbor may place outside its repo:**
  `~/Library/LaunchAgents/com.harbor.*.plist`,
  `/Library/LaunchDaemons/com.harbor.nginx.plist`, `/etc/resolver/test`,
  and `~/.config/harbor/config`. Every one is removed/cleaned by `harbor teardown`.
- **Before adding any file-writing path**, ask: does this write into a tool's
  config dir? If yes, redesign so Harbor owns the file and runs its own instance.

---

## 3. Best practices

**Bash**
- Start every script with `set -euo pipefail`. Source `lib/common.sh` for paths,
  logging, templating, and helpers — don't reinvent them.
- `shellcheck`-clean. Quote **all** expansions (`"$var"`, `"${arr[@]}"`).
- **Target macOS system bash 3.2.** No associative arrays (`declare -A`), no
  `flock`, no `mapfile`/`readarray`, no `${var^^}`. Use indexed arrays +
  `KEY=VALUE` files; serialize with the mkdir-based `harbor_with_lock`. Manifest
  **nesting must use flow style** (`{…}`/`[…]`) — the parser doesn't do block
  sequences/maps.
- Functions over inline blocks; prefix internal helpers with `_`. Keep each `lib/*.sh`
  focused on one area (see `plan.md` layout).
- **No heavy runtime deps.** No `jq`, no `yq` as hard requirements. Persist state
  as `KEY=VALUE` files. Parse the YAML manifest with a constrained parser (pure
  awk/bash) or the always-present PHP CLI — never assume `yq`.
- Use the logging helpers (`log`/`ok`/`warn`/`die`/`step`) for consistent output.
- **Fail fast with a fix hint**, not a stack trace: `die "php@8.6 not installed →
  brew install php@8.6"`. Validate inputs (`require_name`, `valid_php_version`).
- Serialize port/SAN allocation and cert regeneration with `harbor_with_lock`
  (mkdir-based; macOS has no `flock`).

**Design**
- **Templates, not heredocs in logic.** All emitted config comes from `templates/`
  via `render`. Adding output means adding/editing a template.
- **Read the manifest, generate the rest.** New per-project behavior = a manifest
  key + generation logic, not a side file.
- **Doctor before mutate.** `setup` gates on required checks; `init/up/link` run a
  targeted subset and fail fast.
- **Self-heal.** `status`/`doctor` should detect and reload dead `com.harbor.*`
  units.
- **launchd correctness.** php-fpm runs `-F` (no daemonize); set `KeepAlive` and
  raised `RLIMIT_NOFILE`/`worker_rlimit_nofile`.

**Safety**
- Destructive ops (`drop`, `destroy`, `down -v`, `teardown`, `redis flush`)
  **confirm interactively**; honor `--yes` for scripting.
- `db import`/`db pull` take an **auto-backup first** (`--no-backup` to skip).
- Config injection (`wire`) is **allowlist-only, idempotent, with a `.bak`** —
  never blanket-rewrite an app's `.env`. Symfony → `.env.local` only; Magento →
  its own CLI, never hand-edit `env.php`.

---

## 4. CHANGELOG discipline

Harbor keeps a `CHANGELOG.md` following **[Keep a Changelog](https://keepachangelog.com)**
and **[SemVer](https://semver.org)**.

- **Every change that affects behavior, commands, config, or the host footprint
  updates `CHANGELOG.md` in the same commit** — under the `## [Unreleased]`
  section, in the right category: **Added / Changed / Deprecated / Removed /
  Fixed / Security**.
- Write entries for users, imperative and concise: *"Add `harbor tool` for
  containerized CLI binaries"*, not *"refactored db.sh"*.
- **Flag host-footprint changes explicitly.** Anything that adds/removes a file
  outside the repo, a sudo touchpoint, or a launchd unit gets a line and, if
  user-visible, a note in `README.md` + `plan.md`.
- On release, move `Unreleased` items under a new `## [x.y.z] - YYYY-MM-DD`
  heading and bump per SemVer (breaking → major, feature → minor, fix → patch).
- Don't invent dates — if you need today's date, ask or leave `Unreleased`.

---

## 5. Conventions

- **Paths/naming:** launchd units are `com.harbor.<svc>`; sockets/pids in
  `var/run/`; logs in `var/log/`; per-project state in `var/ports/<name>` and
  `projects/<name>/.harbor/`.
- **Ports:** `base = 20000 + N*20`; offsets per `lib/ports.sh`. Redis is shared —
  projects get a DB-index block, not a port.
- **Credential convention:** db → project name; user → db; password → db.
- **Domains:** `<name>.test` (+ `*.<name>.test` for subdomain stores); resolved by
  Harbor's dnsmasq on 5354. One shared cert with **exact per-site SANs** added at
  `link` — a bare `*.test` is NOT trusted (Secure Transport/browsers reject
  wildcards under the reserved `.test` TLD).
- **PHP:** concurrent ondemand pools, one socket per version; site pins via
  `.php-version`; xdebug global toggle, trigger-based, port 9003.

## 6. Extension points (how to add things)

- **Agent skill for projects** → the canonical guidance a coding agent needs to
  *use* Harbor on an app lives in `ai/skills/harbor/` (`SKILL.md` + `reference.md`).
  `cmd_init` (`init_write_agent_skills`) copies it into every project at
  `projects/<name>/.claude/skills/harbor/`, non-clobbering. `harbor update`
  (`init_write_agent_skills … 1`) **force-reseeds** it — overwriting the managed
  files in place so skill improvements reach every project — so improvements you
  make here ship to users on their next `harbor update`. When you add/change a
  **project-facing** command, flag, or workflow, update `ai/skills/harbor/` too (it's
  the source of truth for that copy) alongside `README.md`/`plan.md`/`CHANGELOG.md`.
  (The repo-level `.claude/skills/harbor-*` skills are for building/adopting Harbor
  — a different audience; keep the two in sync but don't conflate them.)
- **Self-update** → `harbor update` (`lib/update.sh`) fast-forwards the checkout
  to `origin/main` (ff-only) and force-reseeds skills. If a change needs a
  post-update host action, wire the hint into `cmd_update`'s `changed`-path
  `case` (platform templates → `harbor setup`; compose → `harbor render/up`) —
  don't make `update` mutate host state itself (no sudo, no launchd reload).
- **New command** → add a dispatch case in `bin/harbor`, implement in the relevant
  `lib/*.sh`, add completion, update the command tables in `README.md` + `plan.md`
  + `CHANGELOG.md`.
- **New framework** → add nginx + compose + env templates, docroot detection,
  installer/seed/wire branches. Keep auto-detection but allow manifest override.
- **New backing service** → per-project, via **compose fragment assembly**: add
  `templates/compose/services/<svc>.yml.tmpl` (the `services:` block) and, if it
  needs a named volume, `templates/compose/volumes/<svc>.yml.tmpl`; claim the next
  free port offset in `ports.sh` (`_ports_write`) and render `{{<SVC>_PORT}}`; add
  its host/port to `connection.env` (`init_write_connection`). Make the image a
  `{{<SVC>_IMAGE}}` var fed by `_service_image` (add a `_service_image_default`
  case) so the version is overridable — the manifest `services:` is a
  `{ svc: "image" }` map, so `services.<svc>` is the pin (→ config `<SVC>_IMAGE`
  → default). Users opt in by adding a `services:` entry; `harbor render <name>`
  regenerates the stack (and migrates legacy list-format manifests). Bind
  `127.0.0.1`, add a healthcheck, add RAM caps. (MySQL-compatible engines like
  **MariaDB** are not a new service — they're a `services.mysql: "mariadb:…"`
  image swap; keep the compose service named `mysql` so `harbor mysql`/`db` keep
  working, and make engine-specific server flags conditional in `_db_command`.)
- **New CLI tool** → add to the `tools:` catalog (name→image); never a host install.
- **Singleton (non-project) stack** → for something Harbor owns but no project owns
  (the shared mailpit+redis stack; the `db sandbox` MySQL), render a standalone
  compose from a `templates/compose/<name>.yml.tmpl` to `docker/<name>.yml` with its
  own `name:` and volumes — do **not** put it under `projects/` or give it a
  port-allocator slot. Still bind `127.0.0.1`, healthcheck, RAM-cap. Prefer **lazy
  start** (bring it up on first use) over always-on to keep RAM low. It must be
  reversible from `teardown` (stop it) and `teardown --purge` (drop its volume),
  and its generated `docker/<name>.yml` must be gitignored. The sandbox may bind a
  standard port (`:3306`) rather than the `20000+` range precisely because it's the
  obvious "just give me one" server — make the port config-overridable and fail
  fast with a fix hint when it's already in use.

## 6.5 Tests

Harbor has a **zero-dependency, pure-bash** unit suite in `test/` — no `bats`, no
installs; it runs on macOS system bash 3.2 like Harbor itself. Layout: `run.sh`
(discovers `test_*.sh`, runs each in its own process, sums the `__TALLY__` line,
exits nonzero on any failure) + `lib.sh` (assert helpers: `assert_eq`,
`assert_ok`/`assert_fail` — which subshell the command so a `die`/`exit` can't
kill the run — `assert_contains`, and `harbor_load` to source the units under
test). Run it with `harbor test` or `./test/run.sh` (filter: `harbor test manifest`).

- **Scope is pure logic only** — parsing, allocation, validation, templating,
  serialized-replace. Tests **never touch the host**: no Docker, launchd, nginx,
  certs, or the sandbox. Use throwaway `mktemp -d` dirs and override globals
  (`HARBOR_PORTS_DIR`, `HARBOR_CONFIG`, …) inside a subshell; clean up on `EXIT`.
- **When you add or change a pure-logic function** (`lib/manifest.sh`,
  `lib/ports.sh`, `lib/common.sh` helpers, `lib/search-replace.php`'s `rr()`), add
  or adjust its test in the same commit. Keep `test/` shellcheck-clean.
- **Testability seams stay behavior-neutral.** `search-replace.php` returns early
  when `HARBOR_SR_LIB_ONLY=1` so `rr()` can be included and tested without a DB;
  real CLI runs leave it unset and behave identically. Prefer this pattern over
  refactoring production logic for tests.

## 7. After every change — required checklist

Run this **every time you finish a unit of work**, in order. Do not claim done
until all five pass.

1. **Harbor healthcheck.** Run `harbor doctor` (and `harbor status`) — all required
   checks green, every `com.harbor.*` unit loaded, nothing broken. For a touched
   command, do a real run (see `plan.md` → Verification), not just dry logic.
   `shellcheck` passes on touched scripts; the command is **idempotent** and has a
   working **undo** (teardown still fully cleans the host). If you touched a
   pure-logic function, run `./test/run.sh` and keep it green (see §6.5).
2. **Check `.gitignore`.** Any new generated/runtime/secret output (`etc/`, `var/`,
   `certs/`, `backups/`, project `.harbor/` runtime, tool shims) must be ignored;
   confirm nothing sensitive is staged and any newly-tracked file is intended
   (`git status` + `git check-ignore <path>`). Update `.gitignore` if needed.
3. **Update `CHANGELOG.md`.** Add an entry under `## [Unreleased]` in the right
   category; flag any host-footprint change explicitly (see §4).
4. **Update `CLAUDE.md`.** If the change established or altered a convention, rule,
   or pattern, persist it here (and in `plan.md`/`README.md` if user-visible) so it
   carries forward — never rely on memory alone.
5. **Sanity check — security, performance, usability.**
   - *Security:* loopback-only; no secrets committed; **no host pollution**
     (nothing written into brew config dirs); no new/unannounced sudo; destructive
     ops gated.
   - *Performance:* RAM stays low (ondemand pools, no needless resident
     containers, service heap caps); no per-request work that should be cached.
   - *Usability:* errors fail fast with a fix hint; confirms on destructive ops;
     help/completion and docs reflect the change.

## 8. Don't

- Don't add files to brew's nginx/php/dnsmasq config dirs.
- Don't bind `0.0.0.0`. Don't mount project source into a container.
- Don't `brew install` an app's binary dependency — containerize it.
- Don't hand-edit Magento `env.php` or blanket-rewrite an app's `.env`.
- Don't require `jq`/`yq`. Don't add a runtime language dependency.
- Don't run destructive ops without a confirm/`--yes`. Don't `sudo` silently.
- Don't let a derived/generated file become the source of truth — the manifest is.
