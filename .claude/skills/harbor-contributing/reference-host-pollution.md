# Anti-host-pollution rules

Moved verbatim from Harbor's root `CLAUDE.md`. Authoritative.

## 2. Anti-host-pollution rules

This is the project's defining constraint. Concretely:

- **nginx** — render `etc/nginx/nginx.conf` + `etc/nginx/sites/*.conf`; run via the
  `com.harbor.nginx` LaunchDaemon (`nginx -c etc/nginx/nginx.conf`). Do **not**
  drop files in brew's `servers/`, do **not** edit brew's `nginx.conf`. Reference
  brew's `mime.types` by absolute path (read-only) only.
- **php-fpm** — render `etc/php/<ver>/fpm.conf`; launch with `--fpm-config`. Do
  **not** edit brew's `php-fpm.d/` or pool defaults.
- **php / xdebug** — configure via `-d` flags at launch (and per-site
  `fastcgi_param PHP_ADMIN_VALUE`). Do **not** write into `…/etc/php/*/conf.d/`. Manifest
  `php_ini:` is applied to **both** surfaces from the same source: FPM via
  `link_php_value_block` (`PHP_ADMIN_VALUE`) and the project CLI via `cli_php_pathdir`
  (`-d` flags in the per-project php shim). Keep the two in sync — a php_ini change
  that only reaches one surface (e.g. `memory_limit` on web but not
  `harbor magento`) is a bug. **The web block MUST be `PHP_ADMIN_VALUE`, not plain
  `PHP_VALUE`** — a plain `PHP_VALUE` is overridable by a docroot `.user.ini`
  (and `ini_set()`), and Magento *ships* one (`.user.ini`/`pub/.user.ini` set
  `memory_limit = 756M`), so a plain value let the app silently cap the
  manifest's `memory_limit` to 756M on web while the CLI (which never reads
  `.user.ini`) got the manifest value — an OOM at exactly 756M despite a 4G
  manifest. `PHP_ADMIN_VALUE` can't be overridden, keeping the manifest
  authoritative and the both-surfaces rule real. The CLI's `-d` flags are
  already unoverridable (CLI ignores `.user.ini`), so the symmetry holds. **Xdebug obeys the same both-surfaces rule, via one
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
  `/Library/LaunchDaemons/com.harbor.nginx.plist`, and `/etc/resolver/test`.
  Every one is removed/cleaned by `harbor teardown`. The global user config is
  **not** in this list — it lives in-tree at `etc/config` (gitignored, wiped by
  `teardown --purge` with the rest of `etc/`); Harbor owns **zero** config
  outside its repo. A pre-move `~/.config/harbor/config` is relocated into
  `etc/config` on the next `setup`/`update` (`config_migrate`, `lib/setup.sh`).
  Never reintroduce an out-of-repo config file — resolve new global knobs
  through `config_get` against `etc/config`.
- **Before adding any file-writing path**, ask: does this write into a tool's
  config dir? If yes, redesign so Harbor owns the file and runs its own instance.

---
