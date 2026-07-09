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

### `<name>` is optional here — omit it
When your shell's cwd is inside this project (`projects/<name>/…`), Harbor infers
the name. So from the project directory:

```bash
harbor artisan migrate            # not: harbor artisan <name> migrate
harbor composer install
harbor up                         # start THIS project's stack
harbor logs -f
```

If you're **not** in the project dir, pass the name as the first arg
(`harbor artisan <name> migrate`). An explicit valid name always wins. Everything
below omits `<name>` — add it back if you run from elsewhere.

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
```bash
harbor mysql                          # interactive client into THIS project's DB
harbor mysql -e "SELECT COUNT(*) FROM users;"
harbor db backup                      # -> backups/db/<name>/<timestamp>.sql.gz
harbor db import <file> [db]          # hookable pipeline: DEFINER-strip, replace, scrub
harbor db import <file> --force       #   skip server-rejected rows instead of aborting
harbor db import <file> --replace old.com=<name>.test
harbor db pull                        # ssh mysqldump from prod -> straight into import
harbor db create <db> [user] [pass]   # extra DB (defaults: db name for all three)
harbor db drop <db>                   # confirm-gated
```
`db import` auto-backs-up first (`--no-backup` to skip) and runs
`.harbor/hooks/pre-import.d/` + `post-import.d/` (credential scrub, etc.).

**Throwaway DB, no project attachment** — a scratch MySQL on `127.0.0.1:3306`:
```bash
harbor db sandbox create test         # auto-starts the server on first use
harbor db sandbox list|console test|backup test|restore test <dump>|drop test
harbor db sandbox down                # stop, KEEP data   (destroy = drop the volume)
```
Use `down`, not `destroy`, for cleanup — `destroy` drops the volume and every DB in it.

### Stack lifecycle (the Docker services, not PHP)
```bash
harbor up                             # start MySQL (+ OpenSearch/RabbitMQ for Magento)
harbor down                           # stop (keeps the MySQL volume; flushes its Redis)
harbor restart
harbor destroy                        # remove containers + volumes + vhost (confirm-gated)
```
PHP is host-side and always on — `up`/`down` only move the Docker services.

### Logs (first stop when a page 500s)
```bash
harbor logs -f                        # this project's container logs
harbor logs php                       # Harbor's PHP-FPM log (fatals, stack traces)
harbor logs nginx                     # nginx access/error
harbor logs clear                     # truncate in place (safe while running)
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
tools: [wkhtmltopdf, ghostscript]  # containerized CLI binaries (see below)
```

After editing the manifest:
| You changed… | Run |
|---|---|
| `services:` (add/version a DB/search/queue) | `harbor render && harbor up` |
| `php:` (and `.php-version`) | `harbor link` (re-points the vhost to the new pool) |
| `docroot:` / `domains:` | `harbor link` |
| `extensions:` | `harbor doctor` (validates; install missing PHP ext via `pecl`) |

**YAML nesting must use flow style** (`{…}` / `[…]`) — Harbor's parser doesn't do
block maps/sequences. Write `services: { mysql: "mysql:8.0" }`, not an indented block.

### Wiring app config (never clobbers)
```bash
harbor wire                # inject DB/Redis/mail into the app config, surgically
harbor wire --print        # preview the values without writing
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
harbor tools sync           # (re)generate shims at .harbor/bin/<tool>
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
  `harbor run php -v`. Extension missing? `harbor doctor`.
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
