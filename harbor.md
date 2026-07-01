# Harbor — Runbook

Practical, day-to-day guide to running Harbor. For the overview see `README.md`;
for design/decisions see `plan.md`; for contributing see `CLAUDE.md`.

Harbor keeps PHP-FPM / nginx / dnsmasq / TLS **native** (Harbor-owned launchd
units, brew config untouched) and runs databases/search/queues in **Docker**.
Shared, always-on: **Mailpit** (`1025`/`8025`) + **Redis** (`6379`). Per project:
**MySQL** (+ **OpenSearch**/**RabbitMQ** for Magento), started on demand.

---

## First-time setup

```bash
ln -s "$PWD/bin/harbor" /usr/local/bin/harbor   # put harbor on PATH
mkcert -install                                 # trust the local CA (one time, you run it)
harbor doctor                                   # fix anything red (prints brew commands)
harbor setup                                    # DNS(:5354) + TLS + FPM pools + nginx + shared stack
source <(harbor completion zsh)                 # optional: tab completion
```

`setup` prompts for **sudo twice**: `/etc/resolver/test` and the nginx
LaunchDaemon (`:80/:443`). Everything is reversible with `harbor teardown`.

> **Port note:** Harbor's nginx needs `:80/:443` and the shared stack needs
> `6379/1025/8025`. Stop any other local stack holding those first.

---

## Daily workflows

### New project (greenfield)
```bash
harbor new shop laravel      # scaffold → init → up → wire → install → link → open
```

### Adopt an existing project
```bash
git clone <repo> projects/shop
harbor init shop --existing  # detect framework, allocate ports, write manifest
harbor up shop               # start MySQL (+ OpenSearch/RabbitMQ if Magento)
harbor wire shop             # inject DB/Redis/mail into the app's config (surgical)
harbor link shop             # https://shop.test  (adds exact cert SAN, reloads nginx)
harbor open shop
```

### Refresh from production
```bash
harbor db pull shop --reconfigure   # ssh mysqldump → strip DEFINERs → hooks → import
                                    #   → serialized-safe replace → scrub → Magento reconfigure
harbor media pull shop              # rsync media/storage (caches excluded)
```

### Everyday commands
```bash
harbor status                # everything's health (self-heals dead units) + project table
harbor ps                    # project table only
harbor up|down|restart shop  # down flushes shop's Redis; MySQL volume is kept
harbor logs shop [service] [-f]
harbor logs nginx|php|dnsmasq [-f]
harbor open shop
```

---

## PHP & Xdebug

```bash
harbor php                 # pool status; * marks the default for new sites
harbor php 8.3             # set default version for new sites
harbor php sync            # after brew install/uninstall php@x
harbor xdebug on|off       # toggle across all pools (trigger-based, port 9003)
```

- Pin a site's version with `projects/<name>/.harbor/harbor.yml` `php:` or a
  `.php-version` file. All installed versions run at once (ondemand pools).
- Xdebug is trigger-based: set `XDEBUG_TRIGGER=1` (env/cookie/query) or use a
  browser extension. With `xdebug on`, `harbor run`/`composer` debug too.

---

## Running code & tools

```bash
harbor run shop <cmd...>          # any command under the project's PHP, in its dir
harbor artisan shop migrate       # + console (Symfony) / spark (CI4) / magento
harbor composer shop require ...  # pinned to the project's PHP
harbor node|npm shop ...          # via nvm + .nvmrc / manifest node:
```

**Containerized CLI tools** (no host installs) — declare in the manifest, then:
```yaml
tools: [wkhtmltopdf, ghostscript]
```
```bash
harbor tools sync shop            # generate shims in .harbor/bin/
harbor tool shop wkhtmltopdf in.html out.pdf
```
For web use, point the library at the shim, e.g. Snappy
`binary => base_path('.harbor/bin/wkhtmltopdf')`.

---

## Databases

```bash
harbor db create shop [db] [user] [pass]   # defaults: all = project name
harbor db backup shop                      # → backups/db/shop/<ts>.sql.gz
harbor db import shop dump.sql.gz          # full pipeline (below)
harbor db drop shop [db]                   # destructive (confirms)
harbor mysql shop                          # mysql client into the project DB
harbor redis shop                          # redis-cli scoped to the project's index
```

**Import pipeline** (`db import` / `db pull`):
decompress → **strip DEFINER** → **pre-import hooks** → load (FK off) →
**serialized-safe search/replace** → **post-import hooks** → optional Magento
`--reconfigure`. An auto-backup is taken first (`--no-backup` to skip).

- **Replace rules:** `projects/<name>/.harbor/import-rules` (`old => new`, empty
  RHS = delete, `re:` = regex) and/or `--replace OLD=NEW`. Serialized PHP lengths
  are recomputed automatically.
- **Hooks:** executables in `.harbor/hooks/pre-import.d/` (edit `$HARBOR_DUMP`) and
  `.harbor/hooks/post-import.d/` (`*.sql` piped to the DB, scripts run with
  `$HARBOR_MYSQL`) — the place to scrub live credentials. Global hooks:
  `etc/hooks/{pre,post}-import.d/`.

Flags: `--keep-definers`, `--no-hooks`, `--no-rules`, `--stream-replace`.

---

## Magento notes

```bash
harbor init shop magento && harbor up shop
harbor composer shop create-project --repository-url=https://repo.magento.com/ magento/project-community-edition .
harbor install shop          # wired setup:install + DX pack (dev mode, disable 2FA, reindex)
harbor magento shop <args>   # bin/magento passthrough
```
- Needs your Marketplace keys in `~/.composer/auth.json`.
- Multi-store (one mode per project):
  ```bash
  harbor store add shop de --domain de.shop.test   # subdomain (adds SAN + nginx map)
  harbor store add shop de --path de               # path (web/url/use_store)
  ```
- No Varnish, no cron by design. Page cache uses Redis.

---

## The manifest

`projects/<name>/.harbor/harbor.yml` is the committable source of truth:

```yaml
framework: laravel
php: "8.4"
services: [mysql]
db: { name: shop, user: shop, password: shop, image: mysql:8.0 }
# node: "20" · docroot: public · domains: [x.test] · extensions: [imagick]
# php_ini: { memory_limit: 2G } · tools: [wkhtmltopdf]
# multistore: { mode: domain, stores: { de: de.shop.test } }
# import: { strip_definers: true } · remote: { host: user@prod, db: shopdb, media: /path }
```

Committable: `harbor.yml`, `import-rules`, `hooks/`. Generated & gitignored:
`connection.env`, `docker-compose.yml`, `install.sh`, `bin/` shims.
Custom nginx rules: drop `projects/<name>/.harbor/nginx.conf` (included in the
site's `server {}`). Global defaults: `~/.config/harbor/config`.

---

## Provider / consumer over TLS

Run many projects at once; a consumer calls a provider by name:
```php
Http::get('https://api.test/v1/orders');   // verifies — Harbor's CA bundle trusts *.test
```
Works because dnsmasq resolves `.test` for PHP too, nginx routes by `Host`, and
host PHP uses `certs/harbor-ca-bundle.pem`. Tip: put a provider on a *different*
PHP version so it gets its own pool for deep synchronous call chains.

---

## Switching between Harbor and another Docker stack

Harbor and a full-Docker project collide on **`:80 :443 :6379 :1025 :8025`**.
Free them from whichever side is active — Harbor pauses/resumes without losing
setup:

```bash
# hand the ports to your old Docker stack
harbor stop                    # frees Harbor's ports (keeps plists, resolver, certs)
docker compose up -d           # (in the old project) — now owns :80/:443/etc.

# switch back to Harbor
docker compose down            # (in the old project) — release the ports
harbor start                   # nginx + dnsmasq + pools + shared stack back up
```

- `harbor stop` needs **sudo** once (to bootout the nginx daemon). Resume is
  `harbor start` (sudo once to bootstrap it).
- Always bring the *other* side down before starting a side — nginx will
  crash-loop if `:80/:443` is still held.
- Running project stacks use high ports (`20000+`) and don't conflict; `harbor
  stop` leaves them running (RAM). Use `harbor down <name>` to stop those too.
- `harbor status` shows `STOPPED` while paused and won't try to self-heal.

## Teardown / troubleshooting

```bash
harbor destroy shop [--files]  # drop stack+volumes, vhost, ports (— and files)
harbor teardown [--purge]      # remove all launchd units + resolver (+ config/certs)
harbor doctor [shop]           # re-check host (+ a project's PHP extensions)
harbor status                  # self-heals dead com.harbor.* units
```

- **Cert not trusted?** `mkcert -install`, then `harbor secure` to reissue.
- **`.test` won't resolve?** check `com.harbor.dnsmasq` in `harbor status` and
  `/etc/resolver/test`.
- **`up` fails / DB races?** `harbor up` waits for health; check `harbor logs shop`.
- **Xdebug still off after `on`?** it's trigger-based — send `XDEBUG_TRIGGER`.
- Host stays clean: brew's nginx/php/dnsmasq config is never modified; teardown
  restores the pre-Harbor state.
