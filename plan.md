# Harbor — Hybrid Local PHP Development Platform · Execution Plan

## Context

Harbor is a **hybrid** local development platform for PHP projects. It keeps the
latency-sensitive, always-on pieces **native on macOS** and pushes heavy,
disposable backing services into **Docker** — a "lighter deck" without host
bloat. The driving goal is **low RAM / low clutter** while supporting plain PHP,
**Magento**, **Laravel**, **Symfony**, and **CodeIgniter** side by side.

**Native (host):** PHP-FPM (all versions), nginx, Xdebug, dnsmasq, TLS (mkcert).
**Docker — shared (always on, cheap):** Mailpit, Redis.
**Docker — per project (manual up/down):** MySQL 8, OpenSearch + RabbitMQ (Magento).

Host already provides (verified): Homebrew PHP 7.4/8.1/8.2/8.3/8.4/8.5 with FPM
binaries and Xdebug compiled for each; nginx with `servers/` include dir;
dnsmasq; mkcert (CA installed); Docker 29.4 + compose v2; Composer 2.9; node via
**nvm** (v22). Apple Silicon, macOS 26.

## Decisions (all confirmed)

| Area | Decision |
|------|----------|
| **PHP execution** | **Concurrent `ondemand` FPM pools** — every installed version runs its own pool on its own socket (`var/php-<ver>.sock`). Idle cost is just the master (~5–15 MB each). No switching. |
| **PHP per site** | Each site pins its version via a `.php-version` file (or `harbor link --php`); nginx routes that site to the matching socket. |
| **Xdebug** | `harbor xdebug on\|off\|status`; layered via `-d zend_extension=…` flags (no edits to Homebrew php.ini), **trigger-based**, client `127.0.0.1:9003`. One toggle, both surfaces: all FPM pools **and** the project CLI (`run`/`composer`/`magento`/…), from the same `xdebug_dflags` helper. |
| **Service topology** | **Per-project compose stacks**; **manual `harbor up`/`down` only** (no auto-stop). |
| **Shared services** | **Mailpit** (SMTP `127.0.0.1:1025`, UI `:8025`) and **Redis** (`127.0.0.1:6379`), one shared stack, always on. |
| **Redis hygiene** | `databases 256`, **persistence off** (`--save "" --appendonly no`). Per-project DB-index block + key prefix. **Flush-on-down**: `harbor down <name>` runs `FLUSHDB` on that project's indices only. |
| **DB engine** | **MySQL 8.0** default; per-project override (incl. MariaDB) via the `mysql` entry in the manifest `services:` map (e.g. `mysql: "mariadb:11.4"`). |
| **Domains** | `.test` via dnsmasq `address=/test/127.0.0.1` (covers all sub-levels). |
| **TLS** | One shared cert whose SAN list (`var/cert-sans`) carries an **exact `<name>.test` per linked site** (+ `*.<name>.test` for subdomain stores). A bare `*.test` is kept only as best-effort — **Secure Transport / browsers reject wildcards directly under the reserved `.test` TLD**, so trust comes from the exact SANs. `harbor link` adds the host's SAN and reissues; `harbor secure` rebuilds. |
| **Server-to-server TLS** | Harbor builds a combined CA bundle (`certs/harbor-ca-bundle.pem` = system bundle + mkcert root CA) and points host PHP at it (`openssl.cafile` / `curl.cainfo`), so projects can call each other over `https://<name>.test` (provider/consumer) with TLS actually verifying — no `verify=false` hacks. |
| **Loopback-only** | Every published container port and service UI (Mailpit, RabbitMQ) binds `127.0.0.1` only — **never** `0.0.0.0`. Nothing is exposed on the LAN. |
| **Containerized CLI tools** | External binaries an app shells out to (wkhtmltopdf, ghostscript, `soffice`, `convert`, ffmpeg…) run in throwaway containers via generated shim scripts, declared in manifest `tools:` — **never installed on the host**. |
| **Magento extras** | OpenSearch + RabbitMQ per project. **No Varnish, no cron.** FPC via Redis page cache. |
| **Multi-store** | **One mode per project** (manifest `multistore.mode: domain\|path\|none`). Domain → nginx `map` + `MAGE_RUN_CODE/TYPE` + `*.<name>.test` SAN. Path → Magento-native `web/url/use_store=1`. |
| **Composer** | `harbor composer <name>` runs the global Composer under the project's **pinned PHP CLI**. v2 default; v1 via manifest `composer_bin`. |
| **Node** | `harbor node\|npm <name>` bridges to **nvm**, honoring `.nvmrc` / manifest `node`; **prompts** `nvm install` if the version is missing. |
| **Requirements check** | `harbor doctor` reports required/config/optional status (installed + configured + running). **Report only** — prints `brew install …` commands, never installs. `setup` gates on required; `init/up/link` run a targeted subset and fail fast. |
| **Config injection** | Source of truth in `.harbor/`; surgical per-key upsert into the app's real config; never clobbers (see below). |
| **Ownership / no pollution** | All nginx/php-fpm/dnsmasq config is authored from templates and **owned in Harbor's `etc/`**. Brew's nginx/php/dnsmasq config dirs are **never written to**. Harbor runs its **own** nginx (root LaunchDaemon, `:80/:443`), php-fpm pools and dnsmasq (`:5354`, user LaunchAgents). Fully reversible via `harbor teardown`. |
| **Project manifest** | Each project's topology lives in one declarative, committable `.harbor/harbor.yml` (framework, php, node, services, multistore, db, hooks). Everything else (compose, vhost, connection env) is **generated** from it. |
| **Global config** | User-overridable defaults in `~/.config/harbor/config` (default php, locale/tz/currency, admin creds, MySQL root pw, OpenSearch heap, etc.) replace hardcoded values; per-project manifest overrides global. |
| **RAM tuning** | Footprint is the point: OpenSearch heap capped (`-Xms512m -Xmx512m`, security/ML off), MySQL lean (modest `innodb_buffer_pool_size`, `performance_schema=off`). |
| **Invariant: code on host** | Project source is **never** mounted into a container — PHP reads it natively (fast FS, native Xdebug). Service containers may only mount their own data volumes. |

## Ownership & no-pollution model

Harbor is the single source of truth for every generated config. Nothing is
written into Homebrew's config trees (`etc/nginx/servers`, `etc/php/*/conf.d`,
`etc/dnsmasq.*`). The brew packages provide **binaries only**; Harbor supplies
the configuration and runs its own instances.

| Component | Owned by Harbor | How the software is driven | Pollution |
|---|---|---|---|
| **nginx** | `etc/nginx/nginx.conf`, `etc/nginx/sites/*.conf`, snippets | Harbor runs `nginx -c etc/nginx/nginx.conf` via `com.harbor.nginx` **LaunchDaemon** (root, for `:443`); master root, workers drop to the user. mime.types read from brew by absolute path. | **none** |
| **php-fpm** | `etc/php/<ver>/fpm.conf` | per-version `com.harbor.php-<ver>` **LaunchAgent** runs `lib/fpm-exec.sh <ver>`, which execs `php-fpm -F --fpm-config …` (+ xdebug `-d` flags when on). | **none** |
| **php / xdebug** | runtime `-d` flags | toggled by Harbor; no `conf.d` files ever written. | **none** |
| **dnsmasq** | `etc/dnsmasq/harbor.conf` | Harbor runs its **own** dnsmasq via `com.harbor.dnsmasq` LaunchAgent (`dnsmasq -C … `, `port=5354`, `address=/test/127.0.0.1`). Brew's `dnsmasq.conf` untouched. | **none** |
| **TLS** | `certs/_wildcard.test.pem` (+ key) | referenced by absolute path in vhosts. mkcert CA already in the system trust store (mkcert's domain, not ours). | **none** |

**Xdebug toggle without plist churn:** `xdebug_dflags <ver>` (`lib/common.sh`)
reads `var/xdebug` and returns the `-d zend_extension=… -d xdebug.mode=…
-d xdebug.start_with_request=trigger -d xdebug.client_host=127.0.0.1 …` flags when
on (and `-d xdebug.mode=off` when off, to neutralize an xdebug brew's php.ini
already loads). `harbor xdebug on|off` just rewrites `var/xdebug` and
`launchctl kickstart -k`s the pools — no plist regeneration, no brew php edits.

It is the **single source of truth for both surfaces**: the FPM LaunchAgent's
`lib/fpm-exec.sh <ver>` and the per-project CLI shim (`cli_php_pathdir`, rewritten
on every `harbor run`) call the same helper, so `harbor xdebug on` means the same
thing for a web request and for `harbor magento`/`composer`/`artisan`. Both dial
`127.0.0.1:9003` — pinned rather than xdebug's `localhost` default, which on macOS
resolves to `::1` first and would silently miss an IDE listening on IPv4. Flags
that reach only one surface are a bug (same rule as `php_ini:`).

**Sudo touchpoints (one-time, both reversible):** installing
`/Library/LaunchDaemons/com.harbor.nginx.plist` (needs root for `:443`) and
writing `/etc/resolver/test`. `harbor teardown` `sudo`-removes both.

**`harbor teardown`** unloads + deletes all `com.harbor.*` units, removes
`/etc/resolver/test`, stops Harbor's nginx/dnsmasq/FPM, and (with `--purge`)
drops `etc/` rendered config and certs — leaving brew nginx/php/dnsmasq
byte-for-byte as before. `harbor unlink <name>` just removes that one vhost +
reloads.

## Configuration model (global config + per-project manifest)

Two layers of declarative config; both are plain text, both override hardcoded
defaults (manifest wins over global wins over built-in).

**Global** — `~/.config/harbor/config` (KEY=VALUE), the one place to change
defaults: `DEFAULT_PHP`, `LOCALE`/`CURRENCY`/`TIMEZONE`, `ADMIN_USER`/
`ADMIN_PASSWORD`, `MYSQL_ROOT_PASSWORD`, `OPENSEARCH_HEAP`, `MYSQL_IMAGE`, etc.
Created with sane values on first `harbor setup`.

**Per-project manifest** — `projects/<name>/.harbor/harbor.yml` is the single
source of truth for a project's topology and is **committable** (teammates clone
+ `harbor up` → identical stack):

```yaml
framework: magento          # plain|laravel|symfony|codeigniter|magento
php: "8.3"                   # pinned version (-> .php-version + vhost socket)
node: "20"                  # optional; -> .nvmrc
docroot: pub                # override auto-detected docroot (plain PHP / legacy apps)
domains: [shop.test, myclient.com]   # extra server_names beyond <name>.test
extensions: [imagick, redis]         # required PHP extensions (doctor validates)
tools:     [wkhtmltopdf, ghostscript]   # containerized CLI tools (shimmed; no host install)
php_ini:   { memory_limit: 2G, "opcache.validate_timestamps": 1 }   # per-project ini
services: { mysql: "mysql:8.0", opensearch: "opensearchproject/opensearch:2.19.0", rabbitmq: "rabbitmq:3.13-management-alpine" }   # name: image (redis/mailpit shared)
db:        { name: shop, user: shop, password: shop, image: mysql:8.0 }
multistore: { mode: domain, stores: { de: de.shop.test, fr: fr.shop.test } }
import:    { strip_definers: true, rules: import-rules }   # hooks live in .harbor/hooks/
remote:    { host: user@prod, db: shopdb, media: /var/www/pub/media }   # db pull / media pull
```
A project may also drop a `.harbor/nginx.conf` snippet (committable) that is
`include`d inside its vhost `server {}` — the escape hatch for apps needing custom
rewrites (legacy `.htaccess` equivalents, WordPress/Drupal/PrestaShop, etc.).

`harbor init`/`new` write the manifest; `up`, `link`, `wire`, `install`, `store`,
`db`, `import` all **read** it. Editing the manifest + re-running the relevant
command re-generates derived files (compose, vhost, `connection.env`). Runtime
state (`connection.env`, `compose.env`, `ports`) is **gitignored**; the manifest,
`hooks/`, and `scripts/` are committable (see Safety & shareability).

## Directory layout

```
harbor/
  bin/harbor                     # single entrypoint, dispatches subcommands
  lib/
    common.sh                    # paths, logging, templating, php helpers
    doctor.sh                    # requirements checks
    ports.sh                     # per-project port + redis-db allocator
    php.sh                       # concurrent ondemand FPM pools + xdebug
    dns.sh tls.sh nginx.sh       # setup + site provisioning (Harbor-owned)
    launchd.sh                   # generate/load/unload com.harbor.* plists
    fpm-exec.sh                  # wrapper plists run; builds -d xdebug args
    compose.sh                   # shared stack + per-project stack lifecycle
    manifest.sh                  # parse/write .harbor/harbor.yml + global config
    wire.sh store.sh db.sh       # config injection, multistore, dumps/seed
    sandbox.sh                   # project-independent scratch MySQL (harbor db sandbox)
    remote.sh                    # db pull / media pull over ssh
    magento.sh                   # magento passthrough + local-DX helpers
    tools.sh                     # composer / node / npm wrappers
    search-replace.php           # serialized-safe row-level replace (run w/ project PHP)
    completion/{harbor.bash,harbor.zsh}   # shell completion
  templates/
    php/fpm.conf.tmpl            # one ondemand pool, per version/socket
    nginx/nginx.conf.tmpl        # Harbor's OWN top-level nginx config
    nginx/{plain,laravel,symfony,magento,codeigniter}.conf.tmpl
    nginx/snippets/*.conf.tmpl   # shared fastcgi / ssl snippets
    dnsmasq/harbor.conf.tmpl     # own dnsmasq instance (port 5354)
    launchd/{nginx,php,dnsmasq}.plist.tmpl
    compose/shared.yml.tmpl · compose/header.yml.tmpl
    compose/services/<svc>.yml.tmpl · compose/volumes/<svc>.yml.tmpl   # per-service fragments
    env/{laravel,symfony,codeigniter}.tmpl
  etc/                           # RENDERED, Harbor-OWNED config (source of truth)
    nginx/nginx.conf             # included by Harbor's nginx only
    nginx/sites/<name>.test.conf # one vhost per linked site
    nginx/snippets/*.conf
    php/<ver>/fpm.conf           # used via `php-fpm --fpm-config`
    dnsmasq/harbor.conf
    hooks/{pre-import.d,post-import.d}/   # GLOBAL import hooks (all projects)
  certs/                         # _wildcard.test.pem + key + harbor-ca-bundle.pem
  docker/docker-compose.yml      # SHARED stack: mailpit + redis (generated)
  projects/<name>/
    .harbor/harbor.yml           # COMMITTABLE manifest (single source of truth)
    .harbor/import-rules         # committable replace rules (init seeds a commented sample)
    .harbor/hooks/{pre-import.d,post-import.d}/   # committable per-project hooks (init seeds
                                 #   inert *.sample hooks + a README with each phase's contract)
    .harbor/scripts/<script>     # COMMITTABLE per-project scripts (on PATH for run/shell)
    .harbor/{connection.env,connection.txt,compose.env,   # GITIGNORED runtime
             docker-compose.yml,install.sh}
    .harbor/bin/<tool>           # GITIGNORED generated tool shims (wkhtmltopdf, …)
  backups/db/<name>/             # timestamped dumps
  ~/.config/harbor/config        # GLOBAL user defaults (KEY=VALUE)
  var/
    run/php-<ver>.{sock,pid}     # per-version FPM runtime sockets/pids
    run/dnsmasq.pid
    default-php                  # default version for new sites
    xdebug                       # on|off  (read by fpm-exec wrapper)
    cert-sans                    # SAN list for the wildcard cert
    ports/<name>                 # allocated ports + redis-db base
    log/                         # fpm + nginx + dnsmasq logs

# Harbor-owned launchd units (the ONLY files outside the repo, besides resolver)
~/Library/LaunchAgents/com.harbor.php-<ver>.plist   # FPM pool (user)
~/Library/LaunchAgents/com.harbor.dnsmasq.plist     # dnsmasq :5354 (user)
/Library/LaunchDaemons/com.harbor.nginx.plist       # nginx :80/:443 (root)
/etc/resolver/test                                  # macOS DNS hook -> 127.0.0.1:5354
```

## Port & Redis allocation

Each project gets a stable index `N`; host ports come from a contiguous block:
`base = 20000 + N*20`. Only **per-project** services get host ports (shared
Mailpit/Redis are fixed).

| Slot | Port | Notes |
|------|------|-------|
| MySQL | `base+0` | container 3306 |
| OpenSearch | `base+1` | Magento only |
| RabbitMQ (AMQP) | `base+2` | Magento only |
| RabbitMQ (mgmt UI) | `base+3` | Magento only |

Redis is shared, so each project instead gets a **DB-index block** of 4 on the
shared instance: `redis_base = N*4` → `cache=base`, `page_cache=base+1`,
`session=base+2`, `spare=base+3`. Plus key prefix `<name>_`. With `databases 256`
that supports 64 concurrent projects. `harbor down <name>` flushes exactly these
indices.

Allocation is persisted to `var/ports/<name>` (KEY=VALUE, no jq) and mirrored
into `.harbor/connection.env` + `.harbor/compose.env`. Allocation and cert-SAN
updates take a `flock` (`var/lock`) so concurrent `harbor` invocations can't race
into duplicate ports or a corrupted SAN list. A freed port/index is also checked
against anything actually listening before reuse (fail-fast hint if occupied).

## CLI surface

```
harbor doctor [--required]            # host requirements report (report-only)
harbor setup                          # one-time host prep (gated by doctor)
harbor php [<ver>]                     # show pool status / set default version
harbor php sync                        # re-create pools after brew install/uninstall php@x
harbor xdebug on|off|status
harbor new <name> <framework>         # scaffold + init + up + wire + install + link + open
harbor init <name> [framework] [--existing] [--multistore domain|path] [--php <ver>]
harbor render <name>                  # regenerate compose+connection from the manifest (services: versions)
harbor link <name>                    # nginx vhost <name>.test (+ *.<name>.test
                                      #   automatically for domain-multistore Magento)
harbor unlink <name>
harbor wire <name> [--print]          # inject config into the app (surgical)
harbor up|down|restart <name>         # per-project docker stack (down flushes redis)
harbor destroy <name> [--files]       # remove stack+volumes, vhost, ports, redis (confirm)
harbor logs <name> [service] [-f]
harbor logs nginx|php|dnsmasq [-f]    # platform service logs (var/log)
harbor install <name>                 # framework installer (Magento setup:install, …)
harbor seed <name>                    # framework seeders / migrations
harbor run <name> <cmd...>            # run any command under project PHP, in project dir
harbor artisan|console|spark <name> [args...]   # framework console passthroughs
harbor magento <name> [args...]       # bin/magento under project PHP (+ DX helpers)
harbor composer <name> [args...]      # composer under the project's PHP
harbor node|npm <name> [args...]      # node/npm via nvm + .nvmrc
harbor tool <name> <tool> [args...]   # run a containerized CLI tool (wkhtmltopdf, …)
harbor tools sync <name>              # (re)generate tool shims from the manifest
harbor store add|list|rm <name> ...   # multistore routing
harbor db create <name> [db] [user] [pass] # defaults: db=project, user=db, pass=db
harbor db drop   <name> [db]               # destructive (confirm)
harbor db backup <name> [db] [file]        # -> backups/db/<name>/<ts>.sql.gz
harbor db import <name> <file> [db]        # decompress→strip-definer→hooks→load→replace
harbor db pull  <name>                     # ssh mysqldump from remote -> import pipeline
harbor db sandbox create|drop|list|backup|restore|console|up|down|destroy|status
                                           # project-independent scratch MySQL on 127.0.0.1:3306
harbor media pull <name>                   # rsync remote media/storage
harbor mysql|redis|shell <name>       # open a console into the project's services
harbor open <name>                    # open https://<name>.test in the browser
harbor ps | list                      # status of all projects / running stacks
harbor mail up|down                   # shared stack (mailpit + redis)
harbor secure [host...]               # (re)issue wildcard cert / add SANs
harbor status                         # pools, sites, running stacks, ports
harbor completion bash|zsh            # print shell completion script
harbor test [filter]                  # run Harbor's own unit suite (test/), optional name filter
harbor update [--check|--stash]       # self-update: ff to origin/main + reseed agent skills
harbor teardown [--purge]             # remove all Harbor launchd units, resolver, config
```

## Setup (`harbor setup`)

Idempotent, re-runnable. After the doctor required-gate passes (all config is
rendered into Harbor's `etc/`; nothing is written into brew dirs):
1. **dnsmasq** — render `etc/dnsmasq/harbor.conf` (`port=5354`,
   `address=/test/127.0.0.1`), install + load `com.harbor.dnsmasq` LaunchAgent,
   write `/etc/resolver/test` (`nameserver 127.0.0.1` / `port 5354`).
   *Sudo:* only the `/etc/resolver/test` write.
2. **TLS** — `mkcert` the wildcard from `var/cert-sans` into `certs/`; build
   `certs/harbor-ca-bundle.pem` (system CA bundle + mkcert `rootCA.pem`) so host
   PHP trusts `*.test` for server-to-server calls.
3. **FPM pools** — render `etc/php/<ver>/fpm.conf` per installed version
   (ondemand, own socket in `var/run/`); install + load one
   `com.harbor.php-<ver>` LaunchAgent each (via `lib/fpm-exec.sh`).
4. **nginx** — render `etc/nginx/nginx.conf` (+ snippets); install + load the
   `com.harbor.nginx` LaunchDaemon (`nginx -c etc/nginx/nginx.conf`).
   *Sudo:* installing the root LaunchDaemon (needed for `:443`).
5. **Shared stack** — render `docker/docker-compose.yml` (mailpit + redis),
   `docker compose up -d`.

## PHP — concurrent ondemand pools

- One FPM master per version, `pm = ondemand` (zero idle workers), listening on
  `var/run/php-<ver>.sock`, run by a `com.harbor.php-<ver>` LaunchAgent that
  execs `lib/fpm-exec.sh <ver>`. Generous installer-friendly limits (memory_limit
  2G, etc.) live in `etc/php/<ver>/fpm.conf`.
- nginx site config `fastcgi_pass`es to the socket for that site's pinned version.
- `harbor php` lists pool status and the default version; `harbor php <ver>` sets
  the default for new sites (does **not** switch existing sites).
- **Xdebug**: `fpm-exec.sh` reads `var/xdebug` and toggles **`xdebug.mode`** —
  `on` → `-d xdebug.mode=debug,develop -d xdebug.start_with_request=trigger
  -d xdebug.client_port=9003`; `off` → `-d xdebug.mode=off`. It only adds
  `-d zend_extension=<so>` when the version doesn't already load Xdebug (brew PHP
  often does, defaulting `xdebug.mode=develop`). `harbor xdebug on|off` rewrites
  `var/xdebug` and `launchctl kickstart -k`s the pools — no plist regeneration,
  no brew ini edits.
- **Per-project php.ini overrides:** since one pool serves all sites of a version,
  per-project settings (manifest `php_ini:`) are applied **per-site** by rendering
  `fastcgi_param PHP_VALUE "memory_limit=2G\nopcache.validate_timestamps=1\n…";`
  into that site's vhost — not at the pool. The **same `php_ini:` is also applied
  to the project's CLI** — `cli_php_pathdir` emits it as `-d key=value` flags in
  the per-project php shim — so `harbor magento`/`run`/`composer` honor
  `memory_limit` etc. (the manifest is the single source of truth for web and CLI
  ini alike; a Magento `di:compile` no longer OOMs at the host's 128M default).
  Dev-friendly opcache (`validate_timestamps=1`) is the default so code edits show
  immediately.
  (Extensions can't be loaded per-site, so manifest `extensions:` is a
  *must-be-installed-for-this-version* requirement that `doctor` checks, not a
  per-site load.)
- **CA trust for all pools + CLI:** `etc/php/<ver>/fpm.conf` sets
  `php_admin_value[openssl.cafile]` / `[curl.cainfo]` to
  `certs/harbor-ca-bundle.pem`, and the `composer`/`run`/`artisan`/`magento`
  wrappers pass the same via `-d`. So every Harbor-run PHP process trusts
  `*.test` and projects can call each other over HTTPS (see below).
- **launchd specifics:** pools run `php-fpm -F` (no daemonize — launchd owns the
  process) with `KeepAlive`; the plist raises `RLIMIT_NOFILE` and the FPM pool +
  nginx set a high open-files limit (`worker_rlimit_nofile`) — Magento/Composer
  routinely hit "too many open files" otherwise.
- **Version re-sync:** `harbor php sync` (also run by `setup`) creates a pool for
  every installed `php@x` and removes pools for uninstalled ones — idempotent, so
  adding a PHP version later is just `brew install php@8.6 && harbor php sync`.
  `doctor` flags any version installed without a pool.

## nginx site provisioning

- `harbor link <name>` renders the framework template to Harbor's own
  `etc/nginx/sites/<name>.test.conf` (included by `etc/nginx/nginx.conf`), then
  `nginx -t -c etc/nginx/nginx.conf && nginx -s reload -c etc/nginx/nginx.conf`.
  Nothing is written into brew's nginx dir.
- **Docroot:** auto-detected (Magento→`pub/`, Laravel/Symfony→`public/`, Symfony
  legacy→`web/`, CI4→`public/`, CI3→app root, plain→project root) and
  **overridable** via manifest `docroot:` — essential for plain/legacy apps with
  non-standard roots.
- **Custom rules escape hatch:** if `projects/<name>/.harbor/nginx.conf` exists it
  is `include`d inside the `server {}` block — lets any app carry its own rewrites
  (legacy `.htaccess` equivalents, WordPress/Drupal/PrestaShop).
- **Extra domains:** manifest `domains:` adds server_names beyond `<name>.test`
  (client/legacy hostnames); non-`.test` names get their own cert SANs and rely on
  the same wildcard CA. dnsmasq only answers `.test`, so non-`.test` domains need a
  `/etc/hosts` entry (Harbor prints the line to add).
- **fastcgi correctness (all templates):** `fastcgi_param HTTPS on;` on the 443
  server so apps detect HTTPS (no redirect loops / mixed content / wrong base
  URLs); `client_max_body_size 128M;` and `fastcgi_read_timeout 600s;` so admin
  uploads and long installers/imports don't fail.
- Templates carry framework-correct rules (Magento static/media + `MAGE_*`
  params; Laravel/Symfony front-controller `try_files`; etc.) and TLS via the
  shared wildcard cert.
- **Cert SANs at link:** every `harbor link <name>` adds the exact `<name>.test`
  to `var/cert-sans`, reissues the shared cert, and reloads nginx — exact SANs are
  what Secure Transport/browsers actually trust (the bare `*.test` is not honored).
- **Magento multistore (domain mode)**: `server_name <name>.test *.<name>.test;`
  + generated `map $http_host $MAGE_RUN_CODE/$MAGE_RUN_TYPE` (valid in the `http`
  context where `servers/*` is included); also add `*.<name>.test` to `var/cert-sans`
  (a one-level wildcard under `<name>.test` *is* honored).

## Per-project Docker stacks

- `harbor init <name> [framework]`: allocate ports/redis-db; write the
  `.harbor/harbor.yml` manifest; render `.harbor/docker-compose.yml` from the
  manifest + framework template with host ports bound to `127.0.0.1`; write
  `compose.env`, `connection.env/.txt`. Works on **existing** code with
  `--existing` (no scaffold).
- Compose is **assembled from fragments** driven by the manifest `services:` list —
  one `templates/compose/services/<svc>.yml.tmpl` per service under a shared
  `header` + `volumes` footer. Defaults: plain/Laravel/Symfony/CodeIgniter →
  **mysql** only (shared redis + mailpit); Magento → **mysql + opensearch +
  rabbitmq**. Edit `services:` and `harbor render <name>` to change the stack.
  `mysql` is the primary-DB slot; each entry's value is its image, so a
  MySQL-compatible engine (MariaDB) is a `mysql: "mariadb:11.4"` swap, with an
  engine-aware server command (`_db_command`).
- **Invariant:** containers mount only their own data volumes — **never project
  source**. PHP on the host reads the code natively (fast FS, native Xdebug).
- **Invariant:** all ports/UIs publish to `127.0.0.1` only (never `0.0.0.0`) — no
  LAN exposure.
- **RAM tuning** baked into the templates: OpenSearch `-Xms512m -Xmx512m` with
  `plugins.security.disabled=true` and ML off; MySQL with a modest
  `innodb_buffer_pool_size` and `performance_schema=OFF`. Overridable via global
  config / manifest.
- **Readiness:** compose services declare `healthcheck`s; `harbor up` blocks until
  MySQL and OpenSearch actually accept connections before returning, so
  `install`/`import` never race a half-booted stack.
- `harbor up|down|restart <name>` wrap `docker compose -f .harbor/docker-compose.yml`
  (the compose file is **fully rendered** by Harbor — concrete ports/creds/images,
  no `--env-file` — and carries `name: harbor-<name>`). **`down` flushes the
  project's Redis indices**; `up` blocks on healthchecks before returning.
- **Data vs cache:** `down` flushes Redis (cache) but **keeps MySQL volumes**
  (data) — only `destroy` / `down -v` drops the database. Stated loudly so an empty
  Redis after a restart is never mistaken for data loss.
- **`harbor destroy <name>`**: unlink vhost, `down -v` (drop volumes), flush Redis
  indices, release the port/redis-db allocation, drop the SAN; `--files` also
  deletes the project directory. Confirm-gated.

## Inter-project communication (provider/consumer)

Multiple projects run side by side by default — one nginx serves all vhosts,
concurrent FPM pools run them at once, the wildcard cert covers them all, and the
allocator keeps their stacks from colliding. A consumer calls a provider at
`https://<provider>.test/…`: dnsmasq resolves it to `127.0.0.1`, nginx routes by
`Host` to the provider's pool.

- **TLS verifies** because host PHP uses `certs/harbor-ca-bundle.pem` (system CA +
  mkcert root) via `openssl.cafile`/`curl.cainfo` — server-to-server HTTPS works
  with full verification, no `verify=false`.
- **DNS resolves for PHP** because `/etc/resolver/test` (port 5354) is honored by
  macOS `getaddrinfo`, which curl/PHP use — so `https://a.test` resolves from CLI
  and FPM alike.
- **Worker-pool note:** providers and consumers on the **same** PHP version share
  one on-demand pool; a synchronous call chain holds one worker per hop. The
  default `pm.max_children` is comfortable for dev; for deep/high-concurrency
  chains either raise it or put the provider on a **different** PHP version (its
  own pool). Documented in `harbor.md`.

## Config injection (never clobbers)

- Harbor-owned source of truth: `.harbor/connection.env` (+ `.txt`) and
  `.harbor/compose.env` (compose reads this via `--env-file`, isolated from the
  app `.env`).
- `harbor wire <name>` injects surgically, **allowlist of keys only**, `.bak` on
  first write, idempotent:
  - **Laravel / CI4** → per-key upsert in `.env`.
  - **Symfony** → write only `.env.local` (`DATABASE_URL`, `REDIS_URL`/
    `MESSENGER_TRANSPORT_DSN`, `MAILER_DSN`); committed `.env` untouched.
  - **Magento** → never edit `env.php`; use `setup:install` + `setup:config:set`.
  - **CI3 / plain** → write `.harbor/connection.php` (array) + `--print` block.

## Installers & data

- `harbor install <name>` (framework-aware): Magento generates a transparent,
  re-runnable `.harbor/install.sh` (`setup:install` fully wired to allocated DB
  port + convention creds, OpenSearch/RabbitMQ/Redis ports & indices; admin
  `admin`/`Admin123!`;
  `en_US`/`USD`/`UTC`) run under the project PHP; `id_prefix` added to `env.php`
  post-install; mail via PHP `sendmail_path` → Mailpit shim. Laravel →
  `key:generate` + `migrate`; Symfony → `doctrine:migrations:migrate`; CI4 →
  `spark migrate`.
- **DB lifecycle** (`harbor db create|drop|backup|import`), all against the
  project's MySQL container via `docker compose exec -T` using the container root
  account (stack must be up):
  - **Credential convention** — identifiers default down a chain: `db` → project
    name; `user` → db; `password` → db. So `harbor db create shop` ⇒ db/user/pass
    all `shop`. Hyphens sanitized to `_` for MySQL identifiers.
  - `create` = `CREATE DATABASE IF NOT EXISTS` + `CREATE USER` + `GRANT ALL`
    (idempotent). `drop` = `DROP DATABASE` (+ optional user), confirm-gated.
  - `backup` = `mysqldump` → `backups/db/<name>/<timestamp>.sql.gz`.
  - `import` runs a **hookable pipeline**:
    1. **decompress** (`.sql`/`.sql.gz`/`.zip`) to a temp working file `$HARBOR_DUMP`;
       a dump whose last line ends mid-statement (truncated download/export) is
       refused with a fix hint — `--force` loads the partial dump anyway.
    2. **strip DEFINER** (automatic — removes `DEFINER=…`/`SQL SECURITY DEFINER`
       so a missing prod user can't break the import; `--keep-definers` to disable).
    3. **pre-import hooks** — each executable in `.harbor/hooks/pre-import.d/*`
       (global `etc/hooks/pre-import.d/*` first) runs with `$HARBOR_DUMP` + env;
       mutates the dump in place (e.g. `sed -i "$HARBOR_DUMP" …`).
    4. **load** into MySQL (`FOREIGN_KEY_CHECKS=0`).
    5. **serialized-safe search-replace** (built-in convenience; row-level via
       `lib/search-replace.php`, recomputes `s:N:"…"` lengths) from
       `.harbor/import-rules` + `--replace OLD=NEW`/`--regex`/`--no-rules`.
    6. **post-import hooks** — `.harbor/hooks/post-import.d/*` (+ global) run
       against the live DB with `$HARBOR_MYSQL` + DB env; `*.sql` files are piped
       to the DB, executables are run (e.g. scrub live credentials/API keys).
    7. optional Magento `--reconfigure` (base URLs + search host).
  - **Hooks**: per-project `projects/<name>/.harbor/hooks/{pre,post}-import.d/`
    plus global `etc/hooks/{pre,post}-import.d/` (global first, then project),
    lexical order; `--no-hooks` to skip. Env for all: `HARBOR_PROJECT/_DIR`,
    `HARBOR_FRAMEWORK`, `HARBOR_DB`, `HARBOR_PHP`; pre adds `HARBOR_DUMP`; post adds
    `HARBOR_DB_HOST/PORT/USER/PASS` + `HARBOR_MYSQL`.
  - `--stream-replace` opts into a fast literal in-stream pass (skips the temp
    file) for dumps known to have no serialized data.
  - Root password defaults to `root` (local dev), stored in Harbor-owned
    `.harbor/connection.env`, overridable.
- **Auto-provisioned primary DB**: `init` sets `MYSQL_DATABASE/USER/PASSWORD` from
  the same convention, so the project's main DB+user exist on first container boot;
  `db create` is for *additional* databases.
- **Sandbox DB** (`harbor db sandbox <sub>`, `lib/sandbox.sh`): a project-*independent*
  scratch MySQL for testing/checking things out — a **Harbor-owned singleton stack**
  (`docker/sandbox.yml` from `templates/compose/sandbox.yml.tmpl`, compose name
  `harbor-sandbox`), deliberately on the standard `127.0.0.1:3306` so it's the
  obvious "just give me a database" server. Unlike per-project stacks it is *not*
  under `projects/`, uses no port-allocator slot, and is **lazily started** on first
  use (low-RAM ethos). Same credential convention as `db create`; identifiers go
  through `db_ident`. `create/drop/list/backup/restore/console/up/down/destroy/status`.
  Reversible: `teardown` runs `sandbox_down`, `teardown --purge` runs
  `sandbox_destroy` (drops the `harbor-sandbox` data volume). Port/image overridable
  via config `SANDBOX_MYSQL_PORT` / `SANDBOX_MYSQL_IMAGE` (a `mariadb:*` image swaps
  the engine, reusing the engine-aware `_db_command`).
- `harbor seed <name>` dispatches framework seeders under the project PHP.

## Remote data sync (`db pull` / `media pull`)

The real refresh-from-prod workflow that the import hooks/replace exist to serve.
Remote connection details live in the manifest (`remote:` block — ssh host, db
name/creds, media paths):
- **`harbor db pull <name>`** streams `ssh <host> 'mysqldump …'` straight into the
  `db import` pipeline (strip-definers → pre-hooks → load → serialized replace →
  post-hooks/credential scrub → Magento reconfigure) — no intermediate file. With
  `--save` it also writes the dump to `backups/db/<name>/`.
- **`harbor media pull <name>`** `rsync`s remote media to the right place per
  framework (Magento `pub/media`, Laravel `storage/app`), with sensible excludes
  (cache/resized). Code is git-managed, so only user-generated assets sync.

## Console passthroughs

`harbor run <name> <cmd…>` runs any command under the project's pinned PHP CLI in
the project dir (so it sees the same DB/Redis/ports as the site). `artisan`,
`console`, `spark`, and `magento` are thin aliases over it
(`harbor artisan shop migrate` ⇒ `run shop php artisan migrate`). This also covers
long-running workers — `harbor run shop 'php artisan queue:work'`,
`harbor run shop 'php bin/console messenger:consume'` — which Harbor does not
manage (consistent with no-cron); you run them in a terminal as needed.

## Magento workflow helpers

- **`harbor magento <name> [args…]`** — `bin/magento` passthrough under the
  project's pinned PHP.
- **Local-DX pack** (run automatically after `install` / `db import` for Magento,
  or via `harbor magento <name> localize`): disable 2FA + AdobeIMS modules
  (`Magento_TwoFactorAuth`, `Magento_AdminAdobeImsTwoFactorAuth`), set
  `deploy:mode:set developer`, reindex + cache flush. Removes the usual
  post-import admin-login pain.
- **Auth keys**: reuse the user's global `~/.composer/auth.json` for Marketplace
  credentials so `composer create-project` / `harbor new … magento` just works.

## Lifecycle (`harbor new`)

One-shot greenfield: scaffold via `composer create-project` (or framework
installer) → `init` (manifest + allocation) → `up` (+ readiness wait) → `wire` →
`install` (+ Magento DX pack) → `link` → `open`. Each step is also runnable
standalone; `new` just chains them. `harbor destroy` is the inverse.

## Ergonomics & completion

- **Consoles**: `harbor mysql <name>` (mysql client into the project DB),
  `harbor redis <name>` (redis-cli scoped to the project's DB index/prefix),
  `harbor shell <name>` (shell in the project dir with the project's PHP/node on
  PATH).
- `harbor open <name>` opens the HTTPS URL; `harbor logs <name> -f` follows;
  `harbor ps`/`list` shows every project with state (php, stack up/down, ports).
- **Shell completion** (`harbor completion bash|zsh`) completes subcommands and
  **project names** (from `projects/*`), since names are the most-typed argument.

## Safety & shareability

- **Destructive ops** (`drop`, `destroy`, `down -v`, `teardown`) confirm
  interactively; `--yes` skips for scripting.
- **Auto-backup before import**: `db import`/`db pull` snapshot the current DB to
  `backups/db/<name>/pre-import-<ts>.sql.gz` first (skip with `--no-backup`), so a
  bad dump or hook is always recoverable.
- **Committable vs runtime**: the manifest (`harbor.yml`), `import-rules`, and
  `hooks/` are committable; runtime (`connection.env`, `compose.env`,
  `docker-compose.yml`, `install.sh`, `var/ports`) is generated and gitignored.
  `init`/`new` write a `.harbor/.gitignore` enforcing the split, so a repo is
  shareable without leaking local ports/creds and a teammate reproduces the stack
  from the manifest alone.

## Process supervision, logs & self-heal

- nginx/dnsmasq/FPM run under launchd with `KeepAlive`, so a crashed service is
  restarted automatically.
- `harbor status` / `harbor doctor` report whether each `com.harbor.*` unit is
  loaded and healthy and **re-load** any that aren't (self-heal) — a dead pool
  won't silently 502.
- Platform logs live in `var/log/` (`php-fpm.log`, `php-error.log`,
  `nginx-{access,error}.log`, `dnsmasq.log`); tail with
  `harbor logs nginx|php|dnsmasq [-f]`. Project/stack logs stay on
  `harbor logs <name>`.

## Containerized CLI tools (no host installs)

Apps that shell out to external binaries (wkhtmltopdf, ghostscript, LibreOffice
`soffice`, ImageMagick `convert`, ffmpeg, pandoc…) don't get host installs —
declare them per project in the manifest `tools:` and Harbor backs each with a
container image and generates a **shim** at `.harbor/bin/<tool>`:

```bash
#!/usr/bin/env bash
exec docker run --rm -i \
  -v "$HARBOR_PROJECT_DIR:$HARBOR_PROJECT_DIR" \
  -v "$TMPDIR:$TMPDIR" -w "$PWD" \
  <image> <tool> "$@"
```

- **Same-path mounts:** the project dir **and** `$TMPDIR` are mounted at identical
  paths, so both project-relative and absolute temp paths (how most PHP PDF/image
  libraries pass files) resolve inside the container; workdir tracks the caller.
- **Catalog + overrides:** `tools: [wkhtmltopdf, ghostscript]` uses a built-in
  name→image catalog; `tools: { wkhtmltopdf: { image: …, bin: … } }` overrides.
- **CLI + web:** shims are on PATH for `harbor run`/`shell`; for web requests point
  the app's tool path at the shim (e.g. Snappy
  `binary => base_path('.harbor/bin/wkhtmltopdf')`); `wire` sets known ones.
- **Ephemeral by default** (`docker run --rm`, zero resident RAM); a `resident`
  mode keeps a warm container and uses `docker exec` for call-heavy workloads.
- **macOS:** the projects directory and `$TMPDIR` must be in Docker Desktop's
  file sharing; `doctor` checks and prints the fix. Shims are gitignored;
  `harbor tools sync <name>` regenerates them.
- Distinct from PHP **extensions** (e.g. `imagick`), which are in-process and still
  need a pecl install for that version — `tools:` is only for external binaries.

## Doctor (requirements)

Categories: **Required** (homebrew, nginx, dnsmasq, mkcert + CA trusted, docker
cli + daemon running, compose v2, ≥1 php-fpm), **Harbor configuration**
(`/etc/resolver/test`, wildcard cert, nginx servers dir), **Optional** (composer,
nvm, per-version xdebug). Each item checked for installed / configured / running.
**Report only** — prints `brew install …`. Non-zero exit if required missing.
`setup` gates on required; `init/up/link` run a relevant subset with fail-fast,
fix-hint errors.

**Per-project extension check** — `harbor doctor <name>` (and `up`/`install`)
validates the **PHP extensions** the project needs against its *pinned* version:
a built-in per-framework baseline (e.g. Magento → `bcmath, ctype, curl, dom, gd,
iconv, intl, mbstring, openssl, pdo_mysql, simplexml, soap, sockets, sodium, xsl,
zip`) plus the manifest's `extensions:` (pecl ones like `imagick`, `redis`,
`apcu`). Missing ones are reported with the exact `pecl install …` / `brew …`
hint for that version. This is the most common "works on mine, not yours" gap.

## Deferred (documented, not built)

- **Workers / queues** — not managed by Harbor (consistent with no-cron). Run them
  via `harbor run <name> 'php artisan queue:work'` /
  `'php bin/console messenger:consume'` / Magento consumers in a terminal. A
  managed-worker supervisor could be added later if needed.
- **Vite / webpack HMR** — the JS dev server on its own port over a TLS `.test`
  site needs the app's Vite config to set `server.https` + `server.hmr.host`;
  `harbor.md` documents the pattern (and the dev-server port) rather than
  auto-wiring it.
- **Xdebug modes** — toggle is debug-mode today; `harbor xdebug
  profile|coverage|debug|off` (and a profiler output dir) is a planned enhancement.

## Build sequence

**Core (foundational — shapes everything downstream):**
1. `bin/harbor` dispatcher + `lib/common.sh`, `lib/doctor.sh`, `lib/ports.sh`,
   `lib/launchd.sh`, **`lib/manifest.sh` (harbor.yml + global config)** — decide
   the config model first since all later commands read it.
2. `harbor doctor` + `harbor setup` (own dnsmasq:5354, tls, owned nginx
   LaunchDaemon, FPM LaunchAgents, shared stack; writes global config) + `teardown`.
3. PHP pools via `php.sh` + `lib/fpm-exec.sh` (`-F`, KeepAlive, RLIMIT_NOFILE,
   CA bundle) + `harbor xdebug` + `harbor php sync`.
4. nginx templates (5 frameworks) + `link`/`unlink`: Magento multistore map,
   **docroot override**, **`.harbor/nginx.conf` include**, extra **`domains:`**,
   per-site **`PHP_VALUE`** ini, **fastcgi correctness** (`HTTPS on`,
   `client_max_body_size`, `fastcgi_read_timeout`).
5. Compose templates (shared + default + magento) + `init`/`up`/`down`/`restart`/
   `logs` — with **RAM tuning** (OpenSearch heap, lean MySQL), **readiness waits**,
   **code-on-host invariant**, redis flush-on-down, `destroy`.
6. `wire.sh` (config injection) + `tools.sh` (composer/node/npm).
7. `install`/`seed` + `db create|drop|backup`, the **hookable `db import`** +
   `search-replace.php` + `store` + `status` + **doctor per-project extension check**.

**Phase 2 (workflow + DX, on the core):**
8. Console passthroughs (`run`/`artisan`/`console`/`spark`); **containerized CLI
   tools** (`tools:` shims in `.harbor/bin/`, `harbor tool`/`tools sync`); `db pull`
   / `media pull` (remote.sh); Magento helpers (`magento.sh`); `harbor new`.
9. Ergonomics (`mysql`/`redis`/`shell`/`open`/`ps`/`list`), platform logs +
   self-heal in `status`/`doctor`, shell completion, safety rails (confirm/`--yes`,
   auto-backup-before-import, `.harbor/.gitignore`, loopback-only binding).
10. End-to-end smoke test (Verification) + `plan.md` → polished `harbor.md` runbook.

> Note: the early scaffolding (`lib/common.sh`, `lib/ports.sh`, `lib/php.sh`,
> `templates/php/php-fpm.conf.tmpl`) predates some decisions and will be
> reconciled to this plan during build — notably **concurrent ondemand pools**
> (per-version sockets via LaunchAgents + `fpm-exec.sh`, not a switcher),
> **shared Redis DB-index allocation** (Redis port slot removed), **Mailpit/Redis
> moved to the shared stack**, and the **Harbor-owned config model** (own nginx /
> dnsmasq / FPM; nothing written into brew dirs; sockets/pids under `var/run/`).

## Verification

- `harbor doctor` shows all required green after `brew` installs; `harbor setup`
  succeeds; `dig shop.test @127.0.0.1 -p 5354` → 127.0.0.1 and
  `ping shop.test` resolves via `/etc/resolver/test`; `certs/` has the wildcard.
- After setup, brew's `etc/nginx`, `etc/php/*/conf.d`, `etc/dnsmasq.*` are
  **unchanged** (no Harbor files written there); all `com.harbor.*` units load.
- Two pools live at once: a Magento site (8.3) and a Laravel site (8.4) both
  serve over HTTPS with no cert warning, confirming concurrent ondemand pools.
- `harbor xdebug on` → triggered breakpoint caught on port 9003.
- **Laravel**: `init` → `wire` → `up` → `https://demo-lar.test`; DB connects
  (allocated port), cache/session in shared Redis (project prefix + indices),
  mail in the shared Mailpit UI.
- **Magento**: `init demo-mag magento` → `up` → `composer`-installed code →
  `install`; OpenSearch/RabbitMQ reachable on allocated ports; storefront via
  `pub/`; multistore (domain) `de.demo-mag.test` resolves, is covered by the
  cert, and routes via `MAGE_RUN_CODE`.
- `harbor down demo-mag` flushes only its Redis indices (other running projects'
  keys intact); `harbor status` reflects pools, sites, running stacks, ports.
- Run two stacks simultaneously → no port collision (allocator).
- **Provider/consumer:** with `a.test` and `b.test` both up,
  `harbor run b 'php -r "var_dump(file_get_contents(\"https://a.test/ping\"));"'`
  succeeds with **TLS verification** (combined CA bundle) — no `verify=false`.
- `harbor db import` a dump (incl. Magento `--reconfigure`) serves correctly.
