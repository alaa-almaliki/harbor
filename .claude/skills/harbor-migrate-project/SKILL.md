---
name: harbor-migrate-project
description: Migrate/onboard an EXISTING PHP app (Laravel, Symfony, CodeIgniter 3/4, Magento, or plain PHP) into Harbor — copy code, pin PHP, provision the stack, import the database, wire config, and serve at https://<name>.test. Use when someone says "move/migrate/import/onboard <app> into Harbor", is adopting a project that already has code and a database, or is replacing a per-project Docker stack with Harbor. Covers legacy gotchas (EOL PHP, Xdebug, MySQL 8 auth).
---

# Migrate an existing project into Harbor

Follow these steps in order. Assume `harbor` is on PATH and `harbor setup` has run.
Full reference: repo `README.md` → "How-to (recipes) → B", and `harbor.md`.

`<name>` = the project/URL slug (lowercase letters, digits, hyphens) → serves at
`https://<name>.test`. Harbor auto-provisions a DB/user/pass all equal to `<name>`.

## 1. Put the code under `projects/`
Code stays on the host; Harbor reads it natively.
```bash
rsync -a /path/to/app/ "$HARBOR_ROOT/projects/<name>/"     # full copy
# or symlink to keep one source of truth:  ln -s /path/to/app "$HARBOR_ROOT/projects/<name>"
```
(`$HARBOR_ROOT` is the Harbor checkout, e.g. `~/harbor`.)

## 2. Pin the PHP version the app needs
```bash
printf '8.3\n' > "$HARBOR_ROOT/projects/<name>/.php-version"
```
If the app needs an **EOL** PHP (7.2/7.3/8.0): install it first and re-sync —
```bash
brew install shivammathur/php/php@7.2 && harbor php sync
```

## 3. Provision + start the stack
```bash
harbor init <name> --existing --php 8.3   # framework auto-detected; override w/ a positional arg
harbor up <name>                          # MySQL (+ OpenSearch/RabbitMQ for Magento)
```

## 4. Bring the database over
Dump from the current source, then import. Example dumping from an old compose `db` service:
```bash
cd /path/to/old-docker && docker compose up -d db
docker compose exec -T db sh -c 'mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --single-transaction --no-tablespaces "$MYSQL_DATABASE"' | gzip > /tmp/<name>.sql.gz
docker compose down
harbor db import <name> /tmp/<name>.sql.gz          # auto-backup, DEFINER-strip, hooks, serialized-safe replace
# rewrite a baked-in domain if needed:  --replace old.com=<name>.test
```

## 5. Wire config (framework-specific)
- **Laravel / Symfony / CodeIgniter 4** → `harbor wire <name>` (surgical `.env`/`.env.local`).
- **CodeIgniter 3 / plain PHP** → `harbor wire <name>` writes `.harbor/connection.php` and
  prints the values; copy host / **port** / db / user / pass into the app's own PHP
  config (`application/config/database.php` for CI3). **Use `127.0.0.1`, never
  `localhost`** (localhost forces a socket and ignores the port). Values are in
  `projects/<name>/.harbor/connection.txt`.
- **Magento** → `harbor install <name>` (fresh) or, for an imported dump,
  `harbor db import <name> <dump> --reconfigure` (fixes base URLs, search, cache).

## 6. Serve + verify
```bash
harbor link <name>     # https://<name>.test — TLS is automatic (exact SAN + reload)
harbor open <name>
harbor ps              # confirm framework / php / stack=up / linked=yes
curl -sI https://<name>.test        # trusted cert; app may 200/302/500
```

## Legacy gotchas (check the app's log if a page errors)
- **"Unable to connect… caching_sha2_password" (2054)** — old PHP mysqli can't do
  MySQL 8's default auth. New Harbor projects already default to the native plugin;
  for this one, flip the user once:
  ```bash
  harbor mysql <name> -e "ALTER USER '<name>'@'%' IDENTIFIED WITH mysql_native_password BY '<name>'; FLUSH PRIVILEGES;"
  ```
- **Xdebug on EOL PHP** — old Xdebug won't compile on new clang; install prebuilt:
  `brew install shivammathur/extensions/xdebug@7.4` then `harbor xdebug on`. No
  need to edit brew's php.ini (Harbor detects it and toggles `xdebug.mode`).
- **Wrong `framework` or `php` in `.harbor/harbor.yml`** — it's the source of truth;
  edit the line and run `harbor link <name>` (for php, also update `.php-version`).
- **base_url / app config** — set the app's base URL to `https://<name>.test/`.
- **"Not private" in browser** — fully quit/reopen the browser (it cached the pre-SAN
  cert); mkcert CA must be installed (`mkcert -install`).

## Rules to respect
Never install app dependencies on the host or edit brew config to make this work —
use `harbor tool`/manifest `tools:` for CLI binaries, and let Harbor own PHP/Xdebug.
Don't hand-edit generated files (`docker-compose.yml`, `connection.env`); change the
manifest and re-run the relevant command.
