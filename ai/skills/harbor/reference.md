# Harbor reference (for this project)

Full command surface and config schema. `SKILL.md` covers the daily workflow;
this is the lookup table. **Only the passthrough/console commands** — `run`,
`artisan`, `console`, `spark`, `magento`, `composer`, `node`, `npm`, `mysql`,
`redis`, `shell` — **infer the project from your cwd** (shown as `[<name>]`,
optional). **Every other command needs an explicit `<name>`** (shown without
brackets); name-less it errors with `project name required`.

---

## Command reference

### Running code (always the pinned PHP)
| Command | What it does |
|---|---|
| `harbor run [<name>] <cmd…>` | Any command in the project dir under its PHP; `.harbor/scripts/` + tool shims on PATH. |
| `harbor artisan [<name>] …` | Laravel `artisan` passthrough. |
| `harbor console [<name>] …` | Symfony `bin/console` passthrough. |
| `harbor spark [<name>] …` | CodeIgniter 4 `spark` passthrough. |
| `harbor magento [<name>] …` | Magento `bin/magento` (+ local-DX helpers). |
| `harbor composer [<name>] …` | Composer under the pinned PHP. |
| `harbor node\|npm [<name>] …` | Node/npm via nvm + `.nvmrc`. |
| `harbor tool <name> <tool> …` | Run a containerized CLI tool once. |
| `harbor tools sync <name>` | (Re)generate tool shims from the manifest. |
| `harbor install <name>` | Framework installer (Laravel migrate, Magento `setup:install`, …). Magento refuses up front, naming every missing required service, if it lacks `mysql` or `opensearch` (RabbitMQ is optional). |
| `harbor seed <name>` | Framework seeders / migrations. |

### Consoles
| Command | What it does |
|---|---|
| `harbor mysql [<name>]` | MySQL client into the project DB. Requires a `mysql` service — refuses with a fix hint if the project has none. |
| `harbor redis [<name>]` | redis-cli scoped to the project's Redis DB index. |
| `harbor shell [<name>]` | Shell in the project dir with its PHP/Node on PATH. |

### Project stack lifecycle
> `<name>` is optional for every command below — inside `projects/<name>/` (any
> depth) or a `harbor shell`, Harbor resolves it from the cwd. `restart` is the
> exception: bare `harbor restart` restarts Harbor itself, so a project restart
> always names the project. A leading argument counts as the project only when a
> project by that name exists, so `harbor db backup reporting` dumps the
> `reporting` database rather than shifting the remaining arguments.

| Command | What it does |
|---|---|
| `harbor up [<name>]` | Start the project's Docker stack (waits for health). |
| `harbor down [<name>]` | Stop it (keeps MySQL volume; flushes its Redis indices). |
| `harbor restart <name>` | Restart the stack. |
| `harbor render [<name>]` | Regenerate `docker-compose.yml` + `connection.env` from the manifest (after editing `services:`). **Confirms** before dropping a service whose data volume still exists (data kept; `HARBOR_YES=1` skips). |
| `harbor services [<name>]` \| `list\|add\|rm [<name>] [svc...]` | Inspect/change a project's services after init. Bare `<name>` is the picker (current selection preselected); `add`/`rm` are no-ops when already/not present. Writes the manifest + re-renders (does NOT run `up`) — same confirm gate as `render` when a service with data would be dropped. |
| `harbor destroy [<name>] [--files]` | Remove stack + volumes + vhost + ports (confirm-gated; `--files` also deletes the code). |
| `harbor link [<name>]` | Create/refresh the `https://<name>.test` vhost (adds cert SAN, reloads nginx). |
| `harbor unlink [<name>]` | Remove the vhost. |
| `harbor open [<name>]` | Open the site in the browser. |
| `harbor wire [<name>] [--print]` | Inject DB/Redis/mail into the app config (surgical, never clobbers). Skips the DB lines for a project with no `mysql` service (still wires Redis/mail); a DB-less Magento project refuses instead, since Magento requires a database. |

### Databases
| Command | What it does |
|---|---|
| `harbor db create [<name>] [db] [user] [pass]` | Create DB + user (defaults: db=project, user=db, pass=db). |
| `harbor db drop [<name>] [db]` | Drop a database (confirm-gated). |
| `harbor db backup [<name>] [db] [file]` | Dump → `backups/db/<name>/<timestamp>.sql.gz`. |
| `harbor db import [<name>] <file> [db]` | Hookable import pipeline (below). `--force` = best-effort (skip rejected statements, load truncated dumps); `--replace OLD=NEW`; `--no-backup`; `--keep-definers`; Magento `--reconfigure`. |
| `harbor db pull [<name>]` | Pull a remote dump straight into the import pipeline. |
| `harbor media pull [<name>]` | rsync remote media/storage. |
| `harbor redis [<name>] [args…]` | `redis-cli` on this project's **cache** index (args pass through — e.g. `harbor redis FLUSHDB`). There is no `redis flush` subcommand; `harbor down <name>` flushes all four indices. |

### Sandbox — project-independent scratch MySQL (127.0.0.1:3306)
| Command | What it does |
|---|---|
| `harbor db sandbox create <db> [user] [pass]` | Create a throwaway DB (auto-starts the server on first use). |
| `harbor db sandbox list` | List sandbox databases. |
| `harbor db sandbox console [db]` | Interactive mysql shell (root). |
| `harbor db sandbox backup <db> [file]` | Dump → `backups/db/sandbox/`. |
| `harbor db sandbox restore <db> <file>` | Load a dump (`.sql`/`.gz`/`.zip`); auto-creates the DB. |
| `harbor db sandbox drop <db> [user]` | Drop a DB (+ its user), confirm-gated. |
| `harbor db sandbox down` | Stop the server, **keep** data. |
| `harbor db sandbox destroy` | Drop the container **and its data volume** (every sandbox DB). |
| `harbor db sandbox status` | Running state + database list. |

Same credential convention as projects (user/pass default to the db name). Port
and image are overridable in `~/.config/harbor/config` (`SANDBOX_MYSQL_PORT`,
`SANDBOX_MYSQL_IMAGE`; a `mariadb:*` image runs MariaDB). Because it binds the
standard `:3306`, stop any other local MySQL first.

### PHP & Xdebug
| Command | What it does |
|---|---|
| `harbor php [<ver>]` | Show pool status / set the default version for new sites. |
| `harbor php use <ver>` | Switch the brew-linked CLI `php` (terminal/IDE/global composer). Independent of per-project pinning. |
| `harbor xdebug on\|off\|status` | Toggle Xdebug across pools (trigger-based, port 9003). |

### Logs & health
| Command | What it does |
|---|---|
| `harbor logs <name> [service] [-f]` | Tail a project's container logs (name required). |
| `harbor logs nginx\|php\|dnsmasq [-f]` | Tail Harbor's platform-service logs (name-less). |
| `harbor logs clear [all\|nginx\|php\|dnsmasq\|<name>]` | Truncate log files in place. |
| `harbor doctor [<name>]` | Host requirements (+ a project's PHP extensions). Report-only. |
| `harbor status` / `harbor ps` | Pools, linked sites, running stacks, ports. |

### Multi-store (Magento)
| Command | What it does |
|---|---|
| `harbor store add <name> <code> --domain <host>` | Subdomain store (`store.<name>.test`). |
| `harbor store add <name> <code> --path <seg>` | Path store (`<name>.test/<seg>`); `--path /` for the prefix-less default store. |
| `harbor store list\|rm <name> …` | Manage store routing. A project uses one mode (domain *or* path). |

Routing is by website code (`--website`, `MAGE_RUN_TYPE=website`) **or** store
view code (default) — one scope per project, never both. The manifest key is the
scope, and setting both is rejected on render:

```yaml
multistore: { mode: path, websites: { main: /, de: /de, fr: /fr } }
multistore: { mode: path, stores:   { default: /, de_de: /de } }
```

Route by **website** when the app's base URLs are set at website scope (the usual
Magento multi-website layout), by store view when they're per store view.

In path mode the prefix is Harbor's and need not match the code.
Keep `web/url/use_store` at **0**, set `web/url/redirect_to_base` to **0**
(nginx strips the prefix, so Magento otherwise 301s into an infinite loop), and set each prefixed scope's
`web/secure/base_url` to `https://<name>.test/<seg>/` so Magento emits the
prefix — `harbor store add` prints the command.

---

## Manifest schema (`.harbor/harbor.yml`)

The single source of truth. Edit it, then run the matching regenerate command
(see SKILL.md → "Configuration"). **Nesting must be flow style** (`{…}`/`[…]`).

```yaml
framework: magento          # plain | laravel | symfony | codeigniter | magento
php: "8.3"                  # pinned PHP (mirror to .php-version)
node: "20"                  # optional -> .nvmrc
docroot: pub                # web root override (Laravel/Symfony: public, Magento: pub)
domains: [shop.test]        # extra hostnames beyond <name>.test
extensions: [imagick, redis]    # required PHP ext (doctor validates)
php_ini: { memory_limit: 2G, "opcache.validate_timestamps": 1 }   # applied to web + CLI
services: { mysql: "mysql:8.0", opensearch: "opensearchproject/opensearch:2.19.0", rabbitmq: "rabbitmq:3.13-management-alpine" }
db:        { name: shop, user: shop, password: shop }   # image lives in services.mysql
tools:     [wkhtmltopdf, ghostscript]                   # or { wkhtmltopdf: { image: …, bin: …, mode: entrypoint } }
multistore: { mode: domain, stores: { de: de.shop.test, fr: fr.shop.test } }
import:    { strip_definers: true, rules: import-rules }
remote:    { host: user@prod, db: shopdb, media: /var/www/pub/media }
```

### Backing services
Each entry in `services:` is `<name>: "<image:tag>"` — one compose fragment per
service, version explicit. Bundled: `mysql`, `opensearch`, `elasticsearch`,
`rabbitmq`, `meilisearch`. A plain project defaults to just `mysql`; Magento to
`mysql + opensearch + rabbitmq`. To change a version, edit the value; to add or
remove a service, use `harbor services add|rm <name> <svc>...` (or hand-edit
the value/line and run `harbor render <name>`), then `harbor up <name>` —
either path **confirms** before dropping a service whose data volume still
exists (data is kept, not deleted; `HARBOR_YES=1` skips the prompt, there is
no `--yes` flag).

Every rendered service pins `platform:` to the host architecture, so Docker
pulls a native image instead of reusing a cached foreign-arch one (an emulated
amd64 database is correct but much slower). If a pinned image has no build for
your architecture the pull fails — set `<SVC>_PLATFORM` (e.g.
`MYSQL_PLATFORM=linux/amd64`, or `none` to drop the pin and let Docker emulate)
or the stack-wide `DOCKER_PLATFORM` in `~/.config/harbor/config`, then
`harbor render <name>`.

**`services: {}` means no containers — no database at all.** (A bare
`services:` with no value means the same. But *deleting* the whole `services:`
line is different: an absent key falls back to the framework default and may
re-add `mysql` on the next `render` — write `{}` to mean "none," don't remove
the line.) This is a valid, supported state (chosen at `harbor init` time via its interactive picker or
`--services ""`/`--services none`), not a misconfiguration. For a project with
no `mysql` service: `harbor up`/`down`/`restart`/`logs` are no-ops (not
errors); `harbor db …`/`harbor mysql` refuse with a fix hint; `harbor doctor`
doesn't require `pdo_mysql`; a Magento project's `install`/`wire` refuse up
front, naming every missing required service (Magento requires `mysql` +
`opensearch`; RabbitMQ is optional, though selected by default); `harbor ps`
shows `db:-`. Add a database later with
`harbor services add <name> mysql && harbor up <name>` (or hand-edit
`services:` and `harbor render <name> && harbor up <name>`). If a project instead HAS a `mysql` service but its ports
were never allocated (missing `var/ports/<name>`), `harbor ps` shows `db:?`
— that means "needs attention" (e.g. `harbor up <name>`), not "no database".

**MariaDB** is not a separate service — swap the `mysql` image:
`services: { mysql: "mariadb:11.4" }` (keeps `harbor mysql`/`db import`/wiring
working; Harbor emits an engine-aware server command).

### Containerized tools
`tools: [name…]` or a map with a custom `image`/`bin`/`mode`. `mode: entrypoint`
(default) overrides the image ENTRYPOINT to the binary (correct for tool images
where the binary *is* the entrypoint). `mode: command` runs the binary as CMD
through the image's own entrypoint (needed for s6-overlay/init images like
`linuxserver/libreoffice`). `harbor tools sync` writes shims to `.harbor/bin/`.

---

## Database import pipeline (`harbor db import`)

0. **Validate rules + hooks up front** — malformed rules (missing `=>`, invalid
   `re:` regex) abort before any work; hooks that would be silently skipped
   (not executable, `*.sql` in `pre-import.d/`) warn; a shell hook with a
   syntax error aborts.
1. **Decompress** `.sql` / `.sql.gz` / `.zip`, then **refuse a truncated dump**
   (one that ends mid-statement — every table after the cut would be silently
   missing). `--force` loads the partial dump anyway.
2. **Strip DEFINER** clauses (so a missing prod user can't break the import;
   `--keep-definers` to disable).
3. **Pre-import hooks** — every executable in `.harbor/hooks/pre-import.d/` runs
   with `$HARBOR_DUMP` pointing at the SQL file.
4. **Load** into the project's MySQL (FK checks wrapped off for out-of-order dumps;
   `--force` skips server-rejected statements like generated-column inserts).
5. **Serialized-safe search/replace** — rules from `.harbor/import-rules` and
   `--replace OLD=NEW`, recomputing PHP serialized string lengths so blobs stay valid.
6. **Post-import hooks** — `.harbor/hooks/post-import.d/` against the live DB
   (`$HARBOR_MYSQL`); `*.sql` piped in, scripts executed — the place to scrub
   credentials/API keys.
7. **Magento `--reconfigure`** (optional) — rewrite base URLs and search host.

A backup is taken before every import (`--no-backup` to skip). `.harbor/import-rules`
example:
```
live.com             => local.test
https://cdn.live.com => https://shop.test
re:UA-\d+-\d+        =>
```

Harbor seeds commented-out samples for all of this (`import-rules`, one
`.sample` hook per phase under `.harbor/hooks/`) — start by uncommenting those
rather than writing from scratch. `# lines` and `.sample` files are inert.
`hooks/post-import.d/*.sql` is the right place to pin table records to local
values on every import (base URLs, dev passwords, clearing live API keys).

---

## Connection info (`.harbor/connection.txt`)

Generated (don't edit). Holds the real host/port/creds — always prefer this over
guessing. Values follow the convention **db = user = password = project name**,
MySQL on a per-project allocated port, Redis shared on 6379 with a per-project DB
index and `<name>_` key prefix. Machine-readable twin: `.harbor/connection.env`
(gitignored).

---

## Calling another Harbor site (provider/consumer)

Running several projects at once is normal. A consumer reaches a provider over TLS
by name — no `/etc/hosts`, no `verify => false`:

```php
$res = Http::get('https://api.test/v1/orders');   // verifies via Harbor's CA bundle
```

`api.test` resolves to `127.0.0.1` for host PHP too. Tip: a provider and its
consumers on the *same* PHP version share one FPM pool; for deep synchronous call
chains, raise `pm.max_children` or put the provider on a different PHP version so
it gets its own pool.
