---
name: harbor
description: How to drive Harbor — the local dev platform that serves THIS project at https://<name>.test — to run PHP/Composer/Node, manage the database, tail logs, debug with Xdebug, and change config. Use for ANY development task in this project: running commands, migrations, tests, tinker/REPL, DB import/backup, queues, or troubleshooting a broken page. The rule that saves you every time — drive the app through `harbor …`, never bare `php`/`composer`/`npm` (those pick the wrong PHP version and miss the DB/Redis env).
---

# Working in a Harbor project

This project is served by **Harbor**, a hybrid local PHP platform for macOS:
PHP-FPM, nginx, TLS and DNS run natively; MySQL (and OpenSearch/RabbitMQ for
Magento) run in Docker; Redis + Mailpit are shared. The site is at
**`https://<name>.test`** with a trusted cert. `<name>` is this project's
directory name under `projects/`.

**Read this before running commands — it will save you from the three mistakes
agents make here:** running bare `php`/`composer` (wrong PHP version), editing
generated files (they get overwritten), and using `localhost` instead of
`127.0.0.1` (Harbor binds loopback IPs, not the hostname).

---

## The one rule: go through `harbor`

Everything that touches this app's code, PHP, or services runs through `harbor`
so it gets **this project's pinned PHP version** and its DB/Redis/mail env:

```bash
harbor run <cmd…>        # ANY command under the project's PHP, in its dir
harbor artisan <cmd…>    # Laravel     (also: console = Symfony, spark = CI4)
harbor composer <cmd…>   # Composer under the pinned PHP
harbor node|npm <cmd…>   # Node/npm via nvm + .nvmrc
harbor magento <cmd…>    # bin/magento passthrough
```

**Do NOT run bare `php artisan …`, `composer …`, `npm …`.** The terminal's `php`
is whatever brew last linked — usually the wrong version — and has none of the
DB/Redis/mail environment. `harbor run php -v` shows the version you actually get.

### When you can omit `<name>` — and when you can't
**Only the passthrough/console commands infer the project from your cwd:**
`run`, `artisan`, `console`, `spark`, `magento`, `composer`, `node`, `npm`,
`mysql`, `redis`, `shell`. From inside the project dir, drop the name:

```bash
harbor artisan migrate            # infers the project from cwd (not: harbor artisan <name> …)
harbor composer install
harbor mysql -e "SELECT 1;"
```

**Every other command needs an explicit `<name>`** — `up`, `down`, `restart`,
`render`, `link`, `unlink`, `wire`, `logs <name>`, `db …`, `destroy`,
`tools sync`, `doctor <name>`. Name-less they error (`project name required`, or
`invalid project name '--flag'` if a flag lands first):

```bash
harbor up <name>                  # NOT: harbor up   → err project name required
harbor logs <name> -f
harbor db backup <name>
```

An explicit valid name always wins, so passing it everywhere is safe. Below, the
passthrough/console examples omit `<name>`; the rest show it — copy that split.

---

## Daily tasks

### Run code / tests / REPL
```bash
harbor run php -v                     # confirm the pinned version
harbor run vendor/bin/phpunit         # tests, under the right PHP
harbor run php artisan tinker         # or: harbor artisan tinker
harbor run <script>                   # .harbor/scripts/<script> is on PATH (see below)
```

### Database
`mysql` infers the project (needs the stack **up**); the `db …` subcommands take
the project name as their first arg:
```bash
harbor mysql                          # infers project; interactive client into its DB
harbor mysql -e "SELECT COUNT(*) FROM users;"
harbor db backup <name>               # -> backups/db/<name>/<timestamp>.sql.gz
harbor db import <name> <file> [db]   # hookable pipeline: DEFINER-strip, replace, scrub
harbor db import <name> <file> --force        # skip server-rejected rows instead of aborting
harbor db import <name> <file> --replace old.com=<name>.test
harbor db pull <name>                 # ssh mysqldump from prod -> straight into import
harbor db create <name> [db] [user] [pass]    # extra DB (db/user/pass default to <name>)
harbor db drop <name> [db]            # confirm-gated
```
`db import` auto-backs-up first (`--no-backup` to skip) and runs
`.harbor/hooks/pre-import.d/` + `post-import.d/` (credential scrub, etc.).

**This project may have no database at all.** Check `services:` in
`.harbor/harbor.yml` — if it's `{}` or has no `mysql` key, `harbor db …` and
`harbor mysql` refuse with a fix hint instead of running (not a "stack not
running" error). Magento requires `mysql` + `opensearch` (RabbitMQ is
optional — only async/bulk ops need it, though a new project selects it by
default); its `install`/`wire` refuse up front, naming every missing required
service, if either is absent. To add a database: `harbor services add <name> mysql && harbor up
<name>` (or hand-edit `services:` in the manifest and `harbor render <name> &&
harbor up <name>`) — this may prompt if a previously-dropped service's old
volume still exists — see Configuration.

**Throwaway DB, no project attachment** — a scratch MySQL on `127.0.0.1:3306`:
```bash
harbor db sandbox create test         # auto-starts the server on first use
harbor db sandbox list|console test|backup test|restore test <dump>|drop test
harbor db sandbox down                # stop, KEEP data   (destroy = drop the volume)
```
Use `down`, not `destroy`, for cleanup — `destroy` drops the volume and every DB in it.

### Stack lifecycle (the Docker services, not PHP) — needs `<name>`
```bash
harbor up <name>                      # start MySQL (+ OpenSearch/RabbitMQ for Magento)
harbor down <name>                    # stop (keeps the MySQL volume; flushes its Redis)
harbor restart <name>
harbor destroy <name>                 # remove containers + volumes + vhost (confirm-gated)
```
PHP is host-side and always on — `up`/`down` only move the Docker services.

### Logs (first stop when a page 500s)
```bash
harbor logs <name> -f                 # this project's container logs (name required)
harbor logs php                       # Harbor's PHP-FPM log — name-less (platform log)
harbor logs nginx                     # nginx access/error — name-less
harbor logs clear                     # truncate in place — name-less; safe while running
```
Also check the app's own log (`storage/logs/laravel.log`, `var/log/`, …).

### Consoles
```bash
harbor shell                          # shell in the project dir, pinned PHP + node on PATH
harbor redis                          # redis-cli scoped to this project's DB index
```

---

## Debugging with Xdebug

Xdebug is **trigger-based** on port 9003 — enabled globally, engaged per-request:

```bash
harbor xdebug on                      # once; layers debug mode onto the pools
# In your IDE: start listening on 127.0.0.1:9003 (PhpStorm phone icon / VS Code "Listen for Xdebug")
```
- **Web:** send the trigger from the browser (Xdebug helper extension, or
  `?XDEBUG_TRIGGER=1`).
- **CLI:** prefix the trigger env var so it reaches PHP:
  ```bash
  XDEBUG_TRIGGER=1 harbor artisan queue:work
  XDEBUG_TRIGGER=1 harbor run php some-script.php
  ```
`harbor xdebug off` when done (keeps normal CLI runs fast). Profiling isn't wired
for CLI — only debug/develop modes are enabled.

---

## Configuration — the manifest is the source of truth

Everything about this project's topology lives in **`.harbor/harbor.yml`**. Edit
it, then run the command that regenerates the derived files. **Never hand-edit the
generated files** (`docker-compose.yml`, `connection.env`, `.harbor/bin/*`) — they
are overwritten. Connection details (host/port/creds) are in
**`.harbor/connection.txt`**.

```yaml
framework: laravel          # plain | laravel | symfony | codeigniter | magento
php: "8.3"                  # pinned version  (also mirror to .php-version)
node: "20"                  # optional -> .nvmrc
docroot: public             # override auto-detected web root (Laravel: public, Magento: pub)
domains: [extra.test]       # extra hostnames beyond <name>.test
extensions: [imagick, redis]   # required PHP ext — `harbor doctor <name>` validates
php_ini: { memory_limit: 2G, "opcache.validate_timestamps": 1 }
services: { mysql: "mysql:8.0" }   # add opensearch/rabbitmq/meilisearch/elasticsearch here
                                    # {} (empty) means NO containers — no database at all
tools: [wkhtmltopdf, ghostscript]  # containerized CLI binaries (see below)
```

After editing the manifest (all of these need an explicit `<name>`):
| You changed… | Run |
|---|---|
| `services:` (add/version/remove a DB/search/queue) | `harbor services add\|rm <name> <svc>...` (or hand-edit + `harbor render <name>`), then `harbor up <name>` — **confirms** before dropping a service whose data volume still exists (data is kept either way; `HARBOR_YES=1` skips) |
| `php:` (and `.php-version`) | `harbor link <name>` (re-points the vhost to the new pool) |
| `docroot:` / `domains:` | `harbor link <name>` |
| `extensions:` | `harbor doctor <name>` (validates; install missing PHP ext via `pecl`) |

**YAML nesting must use flow style** (`{…}` / `[…]`) — Harbor's parser doesn't do
block maps/sequences. Write `services: { mysql: "mysql:8.0" }`, not an indented block.

### Wiring app config (never clobbers) — needs `<name>`
```bash
harbor wire <name>                 # inject DB/Redis/mail into the app config, surgically
harbor wire <name> --print         # preview the values (just cats connection.txt)
```
- **Laravel / Symfony / CI4** → `wire` edits `.env` / `.env.local` key-by-key
  (keeps a `.bak`; Symfony only touches `.env.local`).
- **CI3 / plain PHP** → copy host/port/db/user/pass from `.harbor/connection.txt`
  into your config by hand. **Use `127.0.0.1`, never `localhost`.**
- **Magento** → config goes through its own CLI / `env.php`; don't hand-edit `env.php`.

---

## External binaries — containerize, don't install

If the app shells out to `wkhtmltopdf`, `ghostscript`, LibreOffice (`soffice`),
`ffmpeg`, `pandoc`, etc., **do not `brew install` them.** Declare them in the
manifest and Harbor runs each in a throwaway container behind a shim:

```yaml
tools: [wkhtmltopdf, ghostscript]
```
```bash
harbor tools sync <name>    # (re)generate shims at .harbor/bin/<tool>  (name required)
```
The shims are on PATH for `harbor run`/`harbor shell`. For web requests, point the
library's binary path at the shim, e.g. Laravel Snappy:
`'binary' => base_path('.harbor/bin/wkhtmltopdf')`. PHP *extensions* (e.g.
`imagick`) are different — those are in-process and need a `pecl` install for the
pinned PHP; add them to `extensions:` and `harbor doctor` flags what's missing.

## Project scripts (committable, travel with the app)
Drop executables in `.harbor/scripts/` (`chmod +x`). They run under the pinned PHP
and are on PATH: `.harbor/scripts/invoice` → `harbor run invoice`. Use this for
project-specific commands instead of ad-hoc shell snippets.

---

## Gotchas that bite agents here

- **Use `127.0.0.1`, not `localhost`.** Every service binds the loopback IP. In
  app config and any `mysql -h`, `redis-cli -h`, `curl`, use `127.0.0.1`.
- **Ports aren't the defaults.** MySQL is on a per-project allocated port (not
  3306), Redis is shared on 6379 with a per-project DB index. Get the real values
  from `.harbor/connection.txt` — don't assume.
- **Calling another Harbor site?** `https://other.test` resolves and verifies TLS
  from host PHP (Harbor's CA bundle) — no `verify => false`, no `/etc/hosts`.
- **Queues/workers aren't supervised** — run them yourself:
  `harbor run php artisan queue:work` (or a `.harbor/scripts/` wrapper).
- **A page 500s?** `harbor logs php` + the app log. Wrong PHP version symptom?
  `harbor run php -v`. Extension missing? `harbor doctor <name>`.
- **Don't commit** generated/runtime files — `.harbor/connection.env`,
  `compose.env`, `docker-compose.yml`, `.harbor/bin/` are gitignored. The manifest,
  `import-rules`, `hooks/`, and `scripts/` are committable.

---

## More depth

- **`reference.md`** (next to this file) — full command table, manifest schema,
  the db-import pipeline, multi-store (Magento), and side-by-side project calls.
- **Harbor's own `README.md`** — user-facing docs and recipes (EOL PHP, MySQL 8
  auth, switching stacks).
- `harbor doctor` / `harbor status` / `harbor ps` — health and what's running.
