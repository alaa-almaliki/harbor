# Conventions

Moved verbatim from Harbor's root `CLAUDE.md`. Authoritative.

## 5. Conventions

- **Paths/naming:** launchd units are `com.harbor.<svc>`; sockets/pids in
  `var/run/`; logs in `var/log/`; transient scratch (dump decompress, remote
  pull) in `var/tmp/` (`$HARBOR_TMP`, reclaimed by `teardown`) — **not** the OS
  `$TMPDIR`, so a multi-GB decompress stays inside Harbor and is Harbor's to
  clean; per-project state in `var/ports/<name>` and `projects/<name>/.harbor/`.
- **Ports:** `base = 20000 + N*20`; offsets per `lib/ports.sh`. Redis is shared —
  projects get a DB-index block, not a port.
- **Credential convention:** db → project name; user → db; password → db.
- **Domains:** `<name>.test` (+ `*.<name>.test` for subdomain stores); resolved by
  Harbor's dnsmasq on 5354. One shared cert with **exact per-site SANs** added at
  `link` — a bare `*.test` is NOT trusted (Secure Transport/browsers reject
  wildcards under the reserved `.test` TLD).
- **PHP:** concurrent ondemand pools, one socket per version; site pins via
  manifest `php:` → `.php-version` → global default (`link_php_source` is the
  ONE place that precedence lives); xdebug global toggle, trigger-based, port
  9003. **There are exactly three version knobs, and they must stay three** —
  `harbor php <ver>` (default for NEW sites), `harbor php switch [<name>] <ver>`
  (one project), `harbor php use <ver>` (the brew-linked shell `php`, which
  Harbor itself never reads). They are trivially confusable, so a new knob needs
  a genuinely new scope, not a new spelling of one of these; `php_switch` is where
  per-project switching belongs. A **downgrade confirms, an upgrade doesn't**,
  and the prompt is asked *before* any work so declining costs nothing; word it
  for what actually happens (the switch is reversible and touches no data — it's
  code built for the newer PHP that won't come back), never alarmingly.
  `switch` **converges the whole environment** —
  pool, manifest, `.php-version`, vhost — because a manifest value the vhost never
  got is the exact half-applied state the command exists to prevent; it stops at
  the environment and never touches `vendor/`/`composer.lock`, which are the
  app's. It writes `.php-version` only when the project already has one (Harbor
  doesn't invent files, but a stale one beside a changed manifest is a trap,
  since the manifest silently outranks it). Its manifest write is armed with an
  EXIT trap **before** the write — the `cmd_services` pattern — because `die`s in
  `cmd_link`'s graph call `exit` and would sail past an explicit revert branch.
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
