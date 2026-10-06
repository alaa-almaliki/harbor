# Extension points — how to add things

Moved verbatim from Harbor's root `CLAUDE.md`. Authoritative.

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
  to `origin/main` (ff-only) and re-seeds project artifacts via
  `update_reseed_projects`: the agent skill is force-reseeded (overwritten), and
  `remote.env` is create-if-absent (backfilled, never overwritten — it holds
  secrets). A project-side artifact that should reach existing projects goes in
  that loop; force-reseed only managed files, create-if-absent anything holding
  user data. If a change needs a post-update host action, wire the hint into
  `cmd_update`'s `changed`-path `case` (platform templates → `harbor setup`;
  compose → `harbor render/up`) — don't make `update` mutate host state itself
  (no sudo, no launchd reload).
- **New command** → add a dispatch case in `bin/harbor`, implement in the relevant
  `lib/*.sh`, **add a help topic in `lib/help.sh`**, add it to `_HARBOR_CMDS`
  (`lib/completion.sh` — the single list of what commands exist; `help_topics`
  derives from it), update the command tables in `README.md` + `plan.md` +
  `CHANGELOG.md`. The help topic is **not optional** — `test/test_help.sh` fails
  the build if a dispatched command has no topic. A topic is the *contract* for
  the command's flags (the README tables are only a summary), so **every flag the
  command parses must appear there**; a flag that reaches the parser but not the
  help is a bug. Report usage errors with **`usage_die <topic> "<text>"`**, never a
  bare `die "usage: …"` — it renders the `→ harbor <cmd> --help` pointer and picks
  `--help` vs `harbor help <cmd>` for you. Subcommand help is generic: a topic
  keyed `<cmd>-<sub>` is reached by `harbor <cmd> <sub> --help` with no wiring. If
  the command execs another tool and forwards argv, add it to `help_passthrough`
  so its `--help` reaches that tool.
- **A command that acts on an existing project takes its name through
  `resolve_project`, never `require_name`.** `require_name` only validates
  `$1`; `resolve_project` (`lib/common.sh`) adds the cwd/`$HARBOR_PROJECT`
  fallback that makes `<name>` optional inside a project, and it is the *only*
  place that rule lives — a second implementation is how `harbor db backup`
  ended up erroring `project name required` inside the very project it was
  standing in, years after `harbor mysql` learned better. The idiom is fixed:

      resolve_project "${1-}" "harbor <cmd> [<name>] …"
      [ "$_RP_SHIFT" = 1 ] && shift; local name="$_RP_NAME"

  **`_RP_SHIFT` is not optional bookkeeping.** An explicit name is consumed
  (`_RP_SHIFT=1`) and an inferred one is not, so a command with its own
  positional args must shift on the flag and then read them from `$1`, `$2` —
  *not* `$2`, `$3` as it did when the name was mandatory. Forget the shift and
  every later argument silently lands one slot off (`harbor db backup <db>`
  would dump nothing and write the wrong filename). Conversely, resolution keys
  on the project **existing**, which is what keeps a non-project first argument
  as the command's own: `harbor db backup reporting` dumps the `reporting`
  database. A db/store/tool sharing a project's name must be spelled out; say so
  in the help topic where it's plausible.
  Three commands deliberately opt out, and should stay that way: `new` and
  `init` **create** the project directory (nothing to infer, and
  `harbor init magento` would be ambiguous between a name and a framework), and
  bare `harbor restart` already means "restart Harbor itself". `harbor logs
  clear` likewise defaults to every log, not the current project.
  A command with **no positionals of its own** (`harbor describe`) should go
  one step further: an argument naming no project is a typo, so check
  `[ -d "$(project_dir "$1")" ]` up front and `die "no such project '<x>'"`
  rather than letting `resolve_project` report the vaguer "not inside one".
  Commands that DO take their own positionals must NOT do this — leaving a
  non-project argument alone is exactly what makes `harbor db backup reporting`
  dump the `reporting` database. If a *reporting* command has a sensible
  platform-wide answer with no project at all, call `cwd_project` directly and
  treat its nonzero as "no project"; don't reach for `resolve_project` and try
  to catch its `die` — being fatal is `resolve_project`'s job.
- **Never let `-h`/`--help` reach a command as data.** `help_intercept` answers it
  wherever Harbor is still parsing; a command must never treat it as a value. This
  isn't cosmetic — it once made `harbor logs nginx --help` hang on `tail -F` and
  `harbor xdebug on --help` enable Xdebug and restart every pool. If a new command
  parses positional args, give it a topic and let the interceptor do its job;
  don't hand-roll an `-h)` arm (that's how `harbor update`'s help drifted from its
  own topic).
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
  `127.0.0.1`, add a healthcheck, add RAM caps. **Append `{{<SVC>_PLATFORM}}` to
  the `image:` line** and feed it `service_platform_line <svc>` from the renderer
  — Docker silently reuses a cached foreign-arch image, so without a pin a stale
  amd64 image keeps running under emulation on Apple Silicon (correct, far
  slower, and the only symptom is a one-line warning at `up`). The helper emits
  its own leading newline so an unpinned service renders no stray blank line;
  that's why it's appended to `image:` rather than given its own template line.
  Every compose renderer must do this — per-project *and* both singletons. (MySQL-compatible engines like
  **MariaDB** are not a new service — they're a `services.mysql: "mariadb:…"`
  image swap; keep the compose service named `mysql` so `harbor mysql`/`db` keep
  working, and make engine-specific server flags conditional in `_db_command`.)
- **Shrinking a project's `services:` list** → any path that can drop a service
  (hand-edited manifest, a future `harbor services rm`) must route through
  `cmd_render`'s gate (`services_confirm_shrink`, `lib/services.sh`), not
  reimplement its own confirm. One gate, one place — a user is never asked
  twice for one action. The gate only prompts when the dropped service's named
  Docker volume actually exists (`_service_volume` + `docker volume inspect`);
  growing the list, or shrinking one that was never `up`ed, must stay silent.
  If Docker is unreachable, assume the data is at risk and prompt anyway —
  never let a down daemon silently disable the gate. Frame the prompt
  accurately: removing a service does **not** destroy data (the volume is
  scoped to `harbor-<name>` and survives; re-adding the service reattaches it;
  only `harbor destroy` drops it) — an alarmist prompt for a reversible action
  trains people to stop reading prompts, which is what makes the genuinely
  destructive ones dangerous.
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
