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
  `client_host` and CLI debugging broke while web worked).
  **The one sanctioned exception to both-surfaces is the trigger itself**
  (`xdebug_cli_trigger`): the CLI shim exports `XDEBUG_TRIGGER=1` while the
  toggle is on, the web surface does not. It is not an oversight to fix — out on
  the CLI there is no browser extension to flip, so "xdebug on" can only mean
  "debug my commands", whereas an implicit web trigger would open a session for
  every asset request and ajax poll. `XDEBUG_CLI_TRIGGER=0` opts out; an explicit
  `XDEBUG_TRIGGER` in the environment is never overwritten. Every *other* xdebug
  setting still has to reach both surfaces. Xdebug
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
- **Never end a function or loop body with `[ cond ] && {…}`** — when the guard
  is false it becomes the return value, and under `set -e` a *plain caller dies
  silently with no error output*. Use `if [ cond ]; then …; fi` for optional
  work. This exact shape made `db import` abort with zero output the moment a
  non-executable `.sample` landed in a hooks dir (see `_run_hooks`, and
  `test/test_db.sh` which pins the fix).
- `shellcheck`-clean. Quote **all** expansions (`"$var"`, `"${arr[@]}"`).
- **Target macOS system bash 3.2.** No associative arrays (`declare -A`), no
  `flock`, no `mapfile`/`readarray`, no `${var^^}`. Use indexed arrays +
  `KEY=VALUE` files; serialize with the mkdir-based `harbor_with_lock`. Manifest
  **nesting must use flow style** (`{…}`/`[…]`) — the parser doesn't do block
  sequences/maps.
- **A `case` inside `$(...)` needs a leading `(` on every pattern** —
  `*" mysql "*)` inside a command substitution is a hard syntax error on this
  bash 3.2 (`command substitution: … syntax error near unexpected token
  'newline'`), because its parser loses track of which `)` closes the case arm
  vs. the substitution. Write `(*" mysql "*)` instead; identical behavior,
  parses everywhere. Only bites `case` used as an expression (e.g.
  `X="$(case … esac)"` to build a manifest fragment) — a `case` used as a plain
  statement is unaffected. Test any new `$(case …)` with a real `bash
  <path-to-script>` run, not just `shellcheck` (which doesn't catch this).
- **A function invoked as an `if`/`&&`/`||` condition runs its whole call graph
  with `set -e` disabled** — not just the top-level command, every callee
  beneath it, transitively. A callee that relies on a bare failing statement to
  trigger `set -e`'s abort (rather than an explicit `|| return 1`/`|| die`)
  will instead silently continue and can report false success. This first bit
  `cmd_render` (`lib/init.sh`) the first time it was called under a condition
  (`cmd_services`' `if ! cmd_render "$name"; then …restore…; fi`):
  `init_render_compose`'s failed-`docker-compose-down` path is a bare
  `return 1`, and `cmd_render` called it as a bare statement — fine everywhere
  else `cmd_render` was a plain dispatch statement, but under `if !` the abort
  never fired, so `cmd_render` fell through to `ok "rendered …"` and returned 0
  while the manifest and the actual compose file disagreed. **Fix: propagate
  every callee's failure explicitly** (`callee "$@" || return 1`) in any
  function that might ever be called as a condition — don't assume a bare
  statement's `set -e` reliance is safe just because it works today; the
  function's *caller* determines that, and a caller can change. This is a
  real platform-level trap, not specific to this one bug, and will recur.
- **An empty value is not the same as "absent," and a failed command is not
  the same as "empty" — don't let one get read as the other.** This class of
  bug has recurred multiple times: `manifest_has` (`[ -n "$(manifest_get …)"
  ]`) is a VALUE test, so a hand-edited bare `services:` (present, no value —
  the obvious way to write "none") read identically to the key being absent,
  silently falling back to a framework default with no way to undo it
  through the tool (fixed by adding `manifest_key_present`, a true presence
  test, rather than changing `manifest_has`'s long-standing value semantics
  globally). Separately, `docker volume ls -q 2>/dev/null | grep … || true`
  turned "the daemon is unreachable" into the same empty string as
  "genuinely no matching volumes," letting `harbor destroy` report success
  while leaking every volume it couldn't even enumerate. When a helper
  collapses "absent"/"empty"/"failed" into the same falsy/empty result,
  check whether a caller needs to tell them apart — if so, give it a
  distinct, explicitly-named test (`_key_present`, checking a command's own
  exit status) rather than reusing a value-shaped one. Two rules of thumb the
  optional-services work paid for (~6 instances total):
  - **Test presence, not emptiness.** Use a real presence check —
    `manifest_key_present`, or `[ "$#" -ge N ]` for "was the arg supplied"
    (an arg *count*, since `[ -n "$3" ]` can't tell an empty arg from an unset
    one — this is what made `services_select` re-add a database on a project
    that had none). Emptiness of a value answers a different question.
  - **When the ambiguity is a SAFETY decision, resolve the unknown toward the
    risky side — prompt or refuse, never skip.** A `docker info`/`volume
    inspect` that fails, whitespace-only picker input, a missing
    `var/ports/<name>` — each returns the same empty/falsy as "all clear," and
    reading it that way silently skips a data-loss confirm or picks the
    destructive branch. A spurious prompt is a mild annoyance; a safety gate
    that never fired because a probe came back empty loses someone's data.
- Functions over inline blocks; prefix internal helpers with `_`. Keep each `lib/*.sh`
  focused on one area (see `plan.md` layout).
- **Never probe a command's output with `… | grep -q` under `pipefail`.** `grep
  -q` exits at the first match, the writer's next write hits a closed pipe and
  dies of SIGPIPE (141), and `pipefail` returns that 141 as the *pipeline's*
  status — so a successful match intermittently reads as a failure, at a rate
  low enough (~3 in 400 measured) to be dismissed as a fluke. `php -m | grep -qi
  '^xdebug$'` did exactly this, and a false "xdebug isn't loaded" makes
  `xdebug_dflags` add a **second** `-d zend_extension=` on top of brew's. Read
  the whole stream into a variable and match on that (`php_ext_loaded`,
  `lib/common.sh`) — a command substitution consumes everything, so nothing
  closes early. When testing such a probe, make the fake writer emit the match
  first and keep writing after a `sleep`: that turns the race into a guaranteed
  failure of the wrong implementation instead of a test that passes on a lucky
  schedule (`test/test_xdebug.sh`).
- **No heavy runtime deps.** No `jq`, no `yq` as hard requirements. Persist state
  as `KEY=VALUE` files. Parse the YAML manifest with a constrained parser (pure
  awk/bash) or the always-present PHP CLI — never assume `yq`.
- Use the logging helpers (`log`/`ok`/`warn`/`die`/`step`) for consistent output.
- **Fail fast with a fix hint**, not a stack trace: `die "php@8.6 not installed →
  brew install php@8.6"`. Validate inputs (`require_name`, `valid_php_version`).
- Serialize port/SAN allocation and cert regeneration with `harbor_with_lock`
  (mkdir-based; macOS has no `flock`).

**Design**
- **Templates, not heredocs in logic.** All emitted **config files** come from `templates/`
  via `render`. Adding output means adding/editing a template. This is about
  artifacts written to disk — human-facing terminal text (`usage()`, `lib/help.sh`
  topics, emitted completion scripts) stays a heredoc where it's readable in
  source.
- **Read the manifest, generate the rest.** New per-project behavior = a manifest
  key + generation logic, not a side file.
- **Doctor before mutate.** `setup` gates on required checks; `init/up/link` run a
  targeted subset and fail fast.
- **Self-heal.** `status`/`doctor` should detect and reload dead `com.harbor.*`
  units.
- **launchd correctness.** php-fpm runs `-F` (no daemonize); set `KeepAlive` and
  raised `RLIMIT_NOFILE`/`worker_rlimit_nofile`.

**Safety**
- Destructive ops (`drop`, `destroy`, `down -v`, `teardown`) **confirm
  interactively** via `confirm()`, which is bypassed by **`HARBOR_YES=1` only**.
  There is **no `--yes` flag** except on `harbor update` — don't document one, and
  if you add a flag, add it to the command's help topic in the same commit.
- `db import`/`db pull` take an **auto-backup first** (`--no-backup` to skip).
- **A host mutation with no atomic swap must restore what it replaced when it
  fails, and must not start at all when it's a no-op.** `php_use` is the case
  that proves it: brew has no "relink as", so the old formula is unlinked before
  the new one can claim the symlinks, and a failure in that window left the host
  with **no `php` at all** — a broken terminal, IDE and global composer, from a
  command meant only to switch versions. Harbor couldn't even notice, because it
  runs the versioned kegs directly and never reads the linked one. So: check for
  the no-op first (`want = current` → return, don't unlink), resolve the
  replacement *before* removing the original (the newest PHP ships as the
  *unversioned* `php` formula, so `php@<newest>` may not link), and re-link the
  original on every failure path — saying which state you left behind. Applies to
  anything that removes-then-installs outside Harbor's repo.
- Config injection (`wire`) is **allowlist-only, idempotent, with a
  `.harbor-bak`** (written once, not refreshed on re-wire) —
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
- **Magento multi-store:** one mode per project. **Domain** → `map $http_host`.
  **Path** → three pieces that only work *together*, all in `lib/link.sh`; adding
  one without the others silently 404s every prefixed URL:
  1. `link_map_block` maps **`$request_uri`** → `MAGE_RUN_CODE`. It must NOT key
     on `$uri` — nginx rewrites `$uri`, so by the time the map is evaluated the
     prefix is gone and every request resolves to the default store. `$request_uri`
     is the untouched original.
  2. `link_store_path_block` strips the prefix with a server-scope `rewrite … last`,
     so the existing locations (and the `deny all` block) still match.
  3. `link_mage_params` re-sends **`fastcgi_param REQUEST_URI $harbor_request_uri;`**,
     the prefix-stripped URI computed by a third `map` in `link_map_block`. This
     is the one that actually fixes the 404: Magento derives its path-info from
     `REQUEST_URI`, and brew's `fastcgi.conf` already passed the *original*
     prefixed URI, so a rewrite alone changes nothing Magento can see. It relies
     on last-wins for a repeated `fastcgi_param`, so it must stay **after** the
     `fastcgi.conf` include in `templates/nginx/body/magento.conf.tmpl`.
     **Never build it from `$uri`.** `try_files $uri $uri/ /index.php`'s fallback
     is an *internal redirect* that reassigns `$uri` to `/index.php`, and
     `fastcgi_param` is evaluated after it — so `$uri$is_args$args` sends
     `REQUEST_URI=/index.php` for every deep URL and the **entire site, every
     store**, renders the homepage with a 200. Only `$request_uri` survives both
     the rewrite and the internal redirect, which is why all three maps key on it.
     This shipped once and was missed by verification: HTTP status codes and
     per-store markers (currency, titles) all stay healthy while it is broken,
     because the homepage *is* a valid page of the correct store. **Verify route
     changes on page identity — a `<title>` or route-specific element that differs
     between the homepage and the target — never on status code alone.**
  Stripping the prefix has **two consequences you must document, not discover**:
  Magento's base-URL self-check compares the (stripped) request against the
  store's `/<seg>/` base URL, disagrees, and 301s into an **infinite redirect loop**
  unless `web/url/redirect_to_base` is `0`; and any app shipping Magento's native
  per-website bootstraps (`pub/<seg>/index.php` setting `MAGE_RUN_TYPE=website`)
  has them **bypassed** by the rewrite. That native layout is the simpler design —
  no map, no rewrite, no `redirect_to_base` change, because the prefix stays in
  `REQUEST_URI` and matches the base URL — so **check `pub/<seg>/index.php` and
  any pre-existing `default.conf` before assuming the synthetic approach**; if the
  app already routes by website code, Harbor's store-view map is the wrong shape.
  **Routing scope is one per project — websites XOR store views — and picking it
  wrong resolves the wrong scope or none at all.** `multistore.websites:` renders
  `MAGE_RUN_TYPE=website`, `multistore.stores:` renders `store`; the manifest key
  *is* the scope, so the two can't disagree. Both feed one `link_store_entries`
  helper so the three renderers can't drift, and `link_store_assert_scope` rejects
  a manifest setting both. That gate **must be called as a plain statement** — it
  lives in `_link_build` for exactly this reason: inside `$(...)` its `die` would
  kill only the substitution subshell and the caller would render on regardless
  (the same trap as §3's `set -e`-under-condition rule). Emit the
  **singular** run type (`ScopeInterface::SCOPE_WEBSITE`/`SCOPE_STORE`) — the
  plural `websites` that appears in hand-written Magento vhosts is the
  *config-scope* constant and is not a valid run type. Decide by where the app
  sets its base URLs: **website scope → route by website code**, per-store-view
  scope → route by store view code.
  The prefix is **Harbor's, not Magento's** — it need not equal the code it maps
  to, an entry whose value is `/` is the prefix-less default and
  becomes the map default, and `web/url/use_store` must stay **0** (at `1` Magento
  prepends the code on top of the prefix). Validate path segments against a
  reserved list — a store at `static` or `media` would rewrite every asset on the
  site. Harbor routes the prefix; only Magento can *emit* it, so `store add`
  prints the `base_url` `config:set` rather than writing Magento config itself.
  Pinned by `test/test_store.sh`.

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
  (`HARBOR_PORTS_DIR`, `HARBOR_CONFIG`, …); clean up on `EXIT`.
- **Never put an assertion inside a `( … )` subshell.** `PASS`/`FAIL` are plain
  variables, so a subshell's increments never reach `report` — the file tallies
  only its top-level assertions and `run.sh` **exits 0 even when an assertion
  inside the subshell failed**, which is worse than no test at all. Scope a
  global with a **per-call env prefix** instead
  (`"$(HARBOR_CONFIG="$cfg" config_get PORT)"`, `test_common.sh`), or assign it
  at top level between assertions. When a case genuinely needs a child shell
  (checking a function's exit status under `set -e`), wrap it in a helper that
  *returns* a status and assert on that with `assert_ok`/`assert_fail` — never
  assert inside the child.
- **Set `HARBOR_CONFIG` *after* sourcing the lib, never as an env prefix on a
  `bash -c`.** `lib/common.sh` assigns it unconditionally, so a prefix is
  overwritten at source time and the test silently exercises the default config
  instead of the fixture — it still passes, while testing nothing it claims to.
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
