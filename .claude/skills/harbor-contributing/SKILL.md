---
name: harbor-contributing
description: Build or modify Harbor itself (the bash CLI in bin/harbor + lib/*.sh, templates/, and lib/search-replace.php) following the project's rules and conventions. Use when adding/changing a Harbor command, template, or library; adding a framework, backing service, or CLI tool; or fixing a Harbor bug. NOT for using Harbor on an app (see harbor-new-project / harbor-migrate-project).
---

# Contributing to Harbor

Harbor is a **bash** CLI (no runtime language deps) targeting **macOS system bash
3.2** + Apple Silicon + Homebrew. Read `CLAUDE.md` (authoritative rules), `plan.md`
(design + decisions), and `README.md` (user docs) before changing anything. The
plan/README are the source of truth — if a change contradicts them, update them in
the same commit.

## Non-negotiable rules (from CLAUDE.md)
1. **No host pollution.** Never write into brew config dirs (`etc/nginx`, `etc/php/*`,
   `etc/dnsmasq*`). Render config from `templates/` into Harbor's `etc/`; run Harbor's
   own nginx/php-fpm/dnsmasq instances.
2. **Loopback only** — bind `127.0.0.1`, never `0.0.0.0`.
3. **Code on host** — containers mount only their own data volumes, never project source.
4. **Manifest is source of truth** — `projects/<name>/.harbor/harbor.yml`; commands
   read it and *generate* derived files. Never make a generated file authoritative.
5. **Reversible + idempotent** — every install/link/allocate has an undo; re-running
   converges. `harbor teardown` restores the pre-Harbor host.
6. **Surface sudo** — only the nginx LaunchDaemon and `/etc/resolver/test`; announce it.
7. **No host installs for app deps** — containerize via `tools:`; **Xdebug via
   `xdebug.mode` at launch**, never by editing brew ini.

## Bash conventions
- `set -euo pipefail`; source `lib/common.sh` for logging (`log/ok/warn/die/step`),
  `render`, `config_get`, `db_ident`, `harbor_with_lock`, path + php helpers.
- **bash 3.2**: NO associative arrays, NO `flock` (use mkdir-based `harbor_with_lock`),
  NO `mapfile`/`${var^^}`. Manifest nesting uses **flow style** (`{…}`/`[…]`).
- Quote all expansions; **`shellcheck`-clean** (repo has `.shellcheckrc` for the
  sourced-library false positives).
- Reuse helpers: `manifest_get/list/pairs/map_keys`, `ports_*`, `launchd_*`,
  `project_compose`, `link_detect_framework`, `_db_load`, `cli_php_pathdir`.
- Templates, not heredocs, for emitted config. Fail fast with a fix hint.
- Destructive ops confirm interactively + honor `--yes` (`HARBOR_YES=1`).

## Extension points
- **New command** → dispatch case in `bin/harbor`, implement in the right `lib/*.sh`,
  add to `completion.sh`, update the tables in `README.md` + `plan.md` + `CHANGELOG.md`.
- **New framework** → nginx body template (`templates/nginx/body/`), compose services,
  docroot detection + `link_detect_framework`, `wire`/`install`/`seed` branches.
- **New backing service** → prefer per-project (compose template + allocator slot in
  `ports.sh`); bind `127.0.0.1`, add a healthcheck + RAM cap.
- **New CLI tool** → add to the `_tool_catalog` in `toolbox.sh` (name→image); never a host install.

## After every change — required checklist (CLAUDE.md §7)
Run in order; don't claim done until all pass:
1. **Healthcheck** — `shellcheck` + `bash -n` clean on touched scripts; `harbor doctor`
   green; do a real run of the touched command (idempotent, with a working undo).
2. **Check `.gitignore`** — new generated/runtime/secret output stays ignored; nothing
   sensitive staged.
3. **Update `CHANGELOG.md`** — entry under `## [Unreleased]`, right category; flag
   host-footprint changes.
4. **Update `CLAUDE.md`** (and `plan.md`/`README.md` if user-visible) if a
   convention/rule/pattern changed.
5. **Sanity** — security (loopback, no secrets, no host pollution, no silent sudo),
   performance (low RAM, ondemand), usability (fix-hint errors, confirms, docs/completion).

## Verifying without a running app
Many helpers are pure functions — test them by sourcing `lib/*.sh` in a subshell
(`HARBOR_ROOT="$PWD" bash -c '. lib/common.sh; . lib/manifest.sh; …'`) and calling
them with fixtures, rather than requiring a full stack. Prefer this for parser/
allocator/detection logic; reserve live `harbor up`/`import` for end-to-end checks.
