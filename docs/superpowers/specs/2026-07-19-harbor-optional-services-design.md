# Optional services (incl. no database)

**Date:** 2026-07-19
**Status:** approved, not yet implemented

## Problem

A Harbor project cannot opt out of MySQL. `_init_services` (`lib/init.sh:7-12`)
returns `mysql` for every framework, and `_project_services` (`lib/init.sh:16-21`)
backfills the framework default whenever the manifest's resolved list is empty —
so `services: {}`, `services: []`, and an omitted key all collapse back to
`mysql`. `cmd_init` parses only `--php`, `--multistore`, `--existing`
(`lib/init.sh:346-354`); there is no way to say "no database".

The assumption reaches past the service list into every derived artifact: the
manifest's `db:` block, the port slate, `connection.env`/`connection.txt`, every
`wire` branch, and doctor's PHP extension baseline. There is also a latent bug —
`_compose_assemble` (`lib/compose.sh:36-56`) with zero services would emit a
dangling `services:` key with no children, an invalid compose file. It is
currently unreachable only because `init_render_compose:103` dies first.

This spec covers **optional services in general** (mysql becomes one optional
service among several), of which "no database" is the motivating case. SQLite
support is explicitly **out of scope** and depends on this landing first.

## Phases

- **Phase 1** — optional services: selection at `init`, absent-vs-empty manifest
  semantics, conditional derived artifacts, DB-less behavior rules. Sections A–F.
- **Phase 2** — `harbor services list|add|rm` for changing a project's stack after
  init. Section E. Rides on phase 1's manifest write helper; phase 1 ships
  standalone if phase 2 is deferred.

## Goals

- A project can declare any subset of the service catalog, including none.
- Selection is discoverable — you should not need to know service names up front.
- Existing projects and existing scripted `harbor init` calls keep working
  unchanged.
- Every DB-dependent code path either degrades cleanly or fails with a fix hint.

## Non-goals

- SQLite (its own spec; needs a `db.driver` manifest key and `wire` branches).
- Renumbering the port allocator.
- Changing how services other than mysql are configured or imaged.

## Design

### A. Selection surface

`_init_services` stops being the answer and becomes the **preselection**. The
catalog is derived at runtime from `templates/compose/services/*.yml.tmpl`
(currently mysql, opensearch, rabbitmq, meilisearch, elasticsearch), so adding a
service template makes it selectable with no second list to maintain.

Resolution order in `cmd_init`:

1. `--services "a,b"` flag — always wins, never prompts. `--services ""` means
   none.
2. Interactive picker — when stdin is a TTY and `HARBOR_YES` is unset.
3. Framework default — non-TTY, or `HARBOR_YES=1`.

An unknown service name is a hard `die` listing the catalog.

Picker (bash 3.2, no TUI — a numbered list and one `read`):

```
Services for 'api'  (framework: plain)
  1) mysql          *default
  2) opensearch
  3) rabbitmq
  4) meilisearch
  5) elasticsearch
Select [Enter = defaults · numbers e.g. "1 3" · "none"]:
```

Input parsing lives in a **pure function** — `(input, catalog, defaults) →
resolved list` — so it is unit-testable without a TTY. Empty input yields the
defaults, `none` yields the empty list, numbers yield those entries. Invalid
input re-prompts.

`harbor new` prompts too (decided): it calls `cmd_init`, and the rule stays
identical everywhere rather than having `--services` behave differently
depending on the entry point.

### B. Resolution and legacy compatibility

`_project_services` becomes:

- manifest **has** a `services:` key → use it verbatim, **including empty**.
- manifest **lacks** the key → framework default (today's backfill).

`manifest_has` already distinguishes these — `manifest_get` returns the literal
`{}` for an empty flow map and empty string for an absent key (verified against
`lib/manifest.sh:120-165`). **No parser change is required.**

`harbor render` materializes the resolved list back into the manifest, so an
absent key stops being load-bearing after the first re-render.

**This requires the manifest to become writable, which it is not today** — it is
rendered once from a template (`lib/init.sh:383`) and only ever read thereafter;
no `manifest_set` exists. Phase 1 adds `_manifest_set_line <file> <key> <value>`:
replace the one line whose top-level key matches, append the key if absent, leave
every other byte of the file untouched.

A single-line replace is sufficient **because CLAUDE.md requires manifest nesting
to use flow style** — `services: { mysql: "mysql:8.0", … }` is always exactly one
line. No YAML round-trip, so user comments and formatting survive. The helper is
pure logic and unit-tests without a project (CLAUDE.md §6.5 names serialized
replace as exactly this kind of seam).

### C. Compose assembly

When the resolved list is empty, **no `docker-compose.yml` is written**, and an
existing one is removed on re-render. The `init_render_compose:103` guard die is
removed. `_compose_assemble` is never called with zero services, so the invalid
dangling-`services:` output becomes unreachable by construction rather than by
accident.

Stack lifecycle commands degrade to explicit no-ops:

```
$ harbor up api
  -  nothing to start for 'api' (no services)
```

`up`, `down`, `restart <name>`, `logs <name>` and `destroy` all guard on the
compose file's existence (`destroy` already does, `lib/compose.sh:138`).

**The no-op vs refuse rule** (decided; must be stated in the docs so it does not
read as inconsistency): *lifecycle commands that get run in bulk across every
project degrade to a no-op; commands that are a direct request for a specific
missing thing refuse with a fix hint.* `harbor up` in a loop must not exit
nonzero because one project is service-less; `harbor mysql api` must not exit 0
pretending it worked.

#### Confirming a shrinking selection

Removing a service whose named volume still exists **must confirm before
proceeding**, not warn afterwards. Per CLAUDE.md §3 this uses `confirm()`, which
is bypassed by `HARBOR_YES=1` only — there is no `--yes` flag.

The volumes are **named and scoped to the `harbor-<name>` compose project**
(`templates/compose/volumes/mysql.yml.tmpl`, `header.yml.tmpl:3`), so removing a
service does **not** destroy its data: the volume is left in place and re-adding
the service reattaches it intact. Only `harbor destroy` drops volumes. The prompt
must say this plainly — an alarmist prompt for a reversible action trains people
to hit `y` without reading, which is exactly what makes the genuinely destructive
prompts dangerous.

```
$ harbor services rm api mysql
warn removing mysql from 'api' stops its container and unmounts its data
     the volume harbor-api_dbdata is KEPT — re-adding mysql reattaches it intact
     only 'harbor destroy api' drops it
Remove mysql from 'api'? [y/N]
```

The confirm is triggered by the **volume existing**, not by the service being
mysql — the same applies to opensearch, meilisearch and elasticsearch data. If
the volume was never created (service declared but never brought up), there is
nothing at risk and no prompt.

**One gate, one place.** The check lives in a single helper called wherever a
resolved list shrinks — `render` (including after a hand-edited manifest),
`services rm`, and the `init`/`services` picker when it deselects a service that
already has a volume. `services rm` does not add its own prompt on top of
`render`'s; a user must never be asked twice for one action. At `init` on a fresh
project no volume exists, so the picker never prompts there.

### D. Derived artifacts

All become conditional on the resolved list.

| Artifact | Change |
|---|---|
| manifest (`templates/manifest/harbor.yml.tmpl:7`) | `db: { … }` block only when mysql is selected — new `{{DB_BLOCK}}` render var, empty otherwise |
| `connection.env` / `.txt` (`lib/init.sh:153-194`) | only the selected services' vars |
| ports (`lib/ports.sh:28-47`) | **unchanged** — fixed slate, `DB_PORT` simply unused |
| `harbor ps` (`lib/ergo.sh:63,67`) | prints `db:-` when there is no mysql |
| doctor (`lib/doctor.sh:88-90`) | `pdo_mysql` drops out of the baseline when there is no mysql |
| `db`/`mysql` (`lib/db.sh:16-18`) | new `_db_require` predicate; refuses with the fix hint below |
| `wire` (`lib/wire.sh`) | skips DB keys, still injects Redis/mail |

The `connection.env` change also fixes an existing wart: today every project is
written `OPENSEARCH_*`, `RABBITMQ_*`, `MEILISEARCH_*` and `ELASTICSEARCH_*`
regardless of which services exist (`lib/init.sh:174-181`).

Refusal message:

```
$ harbor mysql api
err  no database service for 'api'
     add one to projects/api/.harbor/harbor.yml services:, then:
     harbor render api && harbor up api
```

`_db_up_check`'s current behavior for this case is a misleading "stack not
running" (`lib/db.sh:16-18`); the new predicate runs before it.

**Magento is the exception in `wire`**: it refuses outright for a DB-less
project, because `harbor install` cannot run `setup:install` without a database
(`lib/magento.sh:20`).

### E. `harbor services` (phase 2)

Changing a project's stack after init. A thin command over phase 1 — the catalog,
the picker, the render path, the orphaned-volume warning and the DB-less refusal
rules are all already built by then.

```
harbor services <name>                 # picker, preselected = current selection
harbor services list <name>            # catalog with the project's picks marked
harbor services add <name> <svc>...    # add, then re-render
harbor services rm  <name> <svc>...    # remove, then re-render
```

`add`/`rm` resolve the new list, write it with `_manifest_set_line`, re-render
compose + `connection.env`, and hint at the next step rather than acting:

```
$ harbor services rm api mysql
warn removing mysql from 'api' stops its container and unmounts its data
     the volume harbor-api_dbdata is KEPT — re-adding mysql reattaches it intact
     only 'harbor destroy api' drops it
Remove mysql from 'api'? [y/N] y
  -  rendered: projects/api/.harbor/docker-compose.yml
  -  next: harbor up api
```

The confirm is the shared gate from section C, not a second prompt. Declining
leaves the manifest untouched and exits nonzero — nothing is half-applied.

It does **not** run `up` itself — re-rendering is safe and idempotent, restarting
containers is not, and the user may be making several changes in a row.

`rm` of a service the project does not have is a no-op with a `warn`, not an
error (idempotence, CLAUDE.md §1.7). `add` of an unknown service dies listing the
catalog, same validation as `--services`.

Per CLAUDE.md §6, a new command also needs: a dispatch case in `bin/harbor`, a
`services` entry in `_HARBOR_CMDS` (`lib/completion.sh`), a help topic
(`test/test_help.sh` fails the build without one), and rows in the README and
`plan.md` command tables.

### F. Tests

Pure-logic only, per CLAUDE.md §6.5 — no Docker, no host state:

- `_project_services` resolution: absent key → default; `services: {}` → empty;
  `services: { mysql: … }` → as written; legacy list form → as written.
- `--services` parsing and validation, including `--services ""` and an unknown
  name.
- The picker's pure parse function: empty input, `none`, `1 3`, out-of-range,
  garbage.
- `_compose_assemble` with a one-service and multi-service list still matches
  today's output (regression guard, since its call sites move).
- `_manifest_set_line`: replaces an existing key, appends an absent one, leaves
  comments and unrelated lines byte-identical, and does not match a key appearing
  mid-line or inside a nested flow map.

- the shrink-detection predicate: which services are being dropped given an old
  and new list. (The `confirm()` call itself and the docker volume probe are not
  unit-tested — tests never touch the host, CLAUDE.md §6.5.)

Phase 2 adds: `services add`/`rm` list resolution (add existing → no change, rm
absent → no change), and unknown-service validation.

### G. Docs

- `lib/help.sh` — `init` topic must document `--services` (CLAUDE.md §6 makes
  this non-optional; `test/test_help.sh` enforces topic existence but not flag
  coverage, so this is on us). The `new`, `up`, `render` and `db` topics need the
  no-op/refuse rule and the prompting behavior. `render` and `services` are
  confirm-gated when the selection shrinks, so their topics get the `[confirms]`
  marker and must state that `HARBOR_YES=1` is the only bypass — CLAUDE.md is
  explicit that no `--yes` flag may be documented for them.
- `README.md` + `plan.md` — a services section covering the catalog, the picker,
  and the DB-less case.
- `CHANGELOG.md` — under `## [Unreleased]` → Added and Fixed (the unconditional
  `connection.env` vars are a fix).
- `ai/skills/harbor/` — this is project-facing, so the skill copy seeded into
  every project must cover `--services`, `harbor services`, and what a DB-less
  project can't do.

## Risks

- **Unintended data detachment** if a user deselects mysql on an existing project.
  Mitigated by the confirm gate in section C: the prompt fires whenever a
  resolved list shrinks past an existing volume, and the volume itself is never
  dropped by `render` or `services rm` — only by `harbor destroy`. The failure
  mode is therefore "my app lost its database until I re-add the service", not
  "my data is gone".
- **Prompt in an unexpected place** — a TTY-attached script calling `harbor init`
  now blocks on the picker. Mitigated by the `HARBOR_YES=1` escape, which already
  means "don't ask me" everywhere else in Harbor.
- **Combinatorial surface** — every service subset is now reachable. The tests
  cover resolution rather than every combination; the compose fragments are
  already independent of one another.
- **Manifest corruption** (phase 1's write helper, inherited by phase 2) — a bad
  single-line replace damages a user-authored, hand-editable file. Mitigated by
  keeping the helper pure and testing the byte-identical-elsewhere property
  directly, and by flow style guaranteeing the target is one line. If a manifest
  ever needs block-style nesting, this helper's assumption breaks — that would be
  a CLAUDE.md-level change, not a local one.
