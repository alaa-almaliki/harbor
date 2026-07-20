#!/usr/bin/env bash
# help.sh — per-command help topics.
#
# Two doors into the same text: `harbor <cmd> --help` / `-h`, and `harbor help
# <cmd>`. Both print to STDOUT and exit 0 — asking for help is not an error, so
# it stays pipeable (`harbor db --help | less`). That's deliberately different
# from the terse `usage:` one-liners commands `die` with on actual misuse, which
# stay on stderr with a nonzero exit and point back here.
#
# Conventions for a topic (keep them consistent — people scan these, they don't
# read them):
#   • one-line purpose, then Usage, then subcommands/flags, then 1-2 REAL
#     examples, then See also. Compact enough to fit a screen without paging.
#   • mark destructive things [confirms] and say how to skip the prompt. Note:
#     confirm() reads HARBOR_YES=1 only — there is NO --yes flag except on
#     `harbor update`. Don't document one that doesn't exist.
#   • document EVERY flag the command actually parses, and where a flag must be
#     positional say so. The README's tables are a summary; this is the contract.
#   • prefer the gotcha that costs an hour over the fact that's obvious from the
#     command name (e.g. `down` flushes Redis; `composer` bypasses the php shim).
#   • prose belongs in README.md; this is a reminder, not a tutorial.
#
# bash 3.2: no associative arrays, so topics are a plain case statement.

# Commands that exec another tool and forward argv to it. Their `--help` belongs
# to THAT tool (`harbor composer --help` must reach Composer, not us), so the
# dispatcher must not intercept it. Harbor's own docs for these live at
# `harbor help <cmd>`.
help_passthrough() {
  case "$1" in
    run|composer|artisan|console|spark|magento|node|npm) return 0 ;;
    *) return 1 ;;
  esac
}

# Every topic — derived from completion's command list rather than hand-kept, so
# there's exactly one place that knows what commands exist. `version`/`help` need
# no topic; `db-sandbox` is a subcommand topic, so it isn't a dispatched command.
# test/test_help.sh asserts this matches help_topic's arms and bin/harbor's
# dispatch.
# shellcheck disable=SC2086  # deliberate word-split of the command list
help_topics() { printf '%s\n' $_HARBOR_CMDS db-sandbox | grep -vE '^(version|help)$' | sort; }

# help_intercept <cmd> <args...> — print the topic when the user asked US for
# help, and return 0 so the caller stops. Returns 1 (silently) to fall through.
#
# The rule: `-h`/`--help` is Harbor's to answer wherever HARBOR is still the one
# parsing, and belongs to the tool once we're forwarding argv to it. Getting this
# wrong is not cosmetic — `harbor logs nginx --help` used to hang on `tail -F` and
# `harbor xdebug on --help` used to turn Xdebug on and restart every pool, because
# a help request reached code that treats a stray arg as data.
#
# So, by the position of the first -h/--help:
#   1st arg          -> the <cmd> topic. Harbor is definitely parsing.
#   2nd arg          -> the <cmd>-<sub> topic if there is one, else <cmd>. Covers
#                       `php use --help`, `xdebug on --help`, `logs nginx --help`.
#   3rd arg onward   -> ONLY a <cmd>-<sub> topic. By here Harbor has usually handed
#                       argv over, so `harbor tool shop wkhtmltopdf --help` must
#                       still reach wkhtmltopdf — but `db sandbox create --help` is
#                       plainly ours, and having a `db-sandbox` topic is what tells
#                       the two apart.
# Passthrough commands are never intercepted at any position.
help_intercept() {
  local cmd="$1"; shift
  if help_passthrough "$cmd"; then return 1; fi
  local a pos=0 n=0 first=""
  for a in "$@"; do
    n=$((n + 1))
    [ "$n" -eq 1 ] && first="$a"
    case "$a" in -h|--help) pos="$n"; break ;; esac
  done
  [ "$pos" -eq 0 ] && return 1
  # $first is the flag itself when pos=1, so only pair it with <cmd> beyond that.
  if [ "$pos" -ge 2 ] && help_topic "$cmd-$first"; then return 0; fi
  if [ "$pos" -le 2 ] && help_topic "$cmd"; then return 0; fi
  return 1
}

# usage_die <topic> "<text>" — the one way to report a usage error: terse usage on
# stderr, nonzero exit, and a pointer to the full topic. It picks `--help` vs
# `harbor help <cmd>` by asking help_passthrough, so no call site has to remember
# which kind it is. <topic> is the topic key — `db`, or `db-sandbox` which renders
# as `harbor db sandbox --help`.
usage_die() {
  local topic="$1" text="$2" cmd hint
  cmd="$(printf '%s' "$topic" | tr '-' ' ')"
  if help_passthrough "$topic"; then hint="harbor help $cmd"; else hint="harbor $cmd --help"; fi
  die "usage: $text  →  $hint"
}

# help_topic <cmd> — print <cmd>'s help on stdout. Returns 1 (printing nothing)
# when there's no topic, so callers can fall through.
help_topic() {
  case "$1" in

  # --- host & lifecycle -------------------------------------------------------
  doctor) cat <<'EOF'
harbor doctor — report host requirements; never installs anything

Usage: harbor doctor [<name>]

  <name>    Also check that project's PHP extensions against its pinned version

Reports: required tools (brew, php-fpm, nginx, dnsmasq, mkcert + CA, docker),
Harbor's own config (/etc/resolver/test, cert, CA bundle, nginx.conf), and
optional extras (composer, nvm, xdebug per PHP version).

Exits nonzero only if a REQUIRED item is missing — missing optional/config items
report but don't fail. A project with no `mysql` service isn't asked for
`pdo_mysql` in its extension baseline.

Examples:
  harbor doctor
  harbor doctor shop        # + shop's extension baseline for its framework

See also: harbor status · harbor setup
EOF
  ;;

  setup) cat <<'EOF'
harbor setup — one-time host preparation. Idempotent; safe to re-run.

Usage: harbor setup        (no flags)

Runs doctor first and stops if a required check fails, then: DNS (dnsmasq +
resolver), TLS (mkcert cert + CA bundle), PHP-FPM pools, nginx, shared stack.

Sudo (announced, twice): writing /etc/resolver/test, and installing the nginx
LaunchDaemon (+ `nginx -t`, which binds :80/:443). Nothing else needs root.

Never writes into Homebrew's nginx/php/dnsmasq config — Harbor renders its own
into etc/ and runs its own instances.

Note: ~/.config/harbor/config is written only if absent — re-running setup will
not refresh it.

See also: harbor teardown (undo) · harbor doctor · harbor start | stop
EOF
  ;;

  teardown) cat <<'EOF'
harbor teardown — remove Harbor from the host                       [confirms]

Usage: harbor teardown [--purge]

  --purge   Also drop the sandbox MySQL volume and delete rendered config
            + certs. Must be the FIRST argument.

Always removes: nginx LaunchDaemon, dnsmasq agent, /etc/resolver/test, all PHP
pools, the shared stack, the sandbox container.

Does NOT touch: your projects/ code, per-project stacks or volumes, backups/, or
~/.config/harbor/config. Homebrew's own nginx/php/dnsmasq stay untouched.

Skip the prompt with HARBOR_YES=1 (there is no --yes flag).
Sudo: removing the nginx LaunchDaemon and /etc/resolver/test.

Examples:
  harbor teardown
  HARBOR_YES=1 harbor teardown --purge

See also: harbor destroy <name> (one project) · harbor stop (just pause)
EOF
  ;;

  stop) cat <<'EOF'
harbor stop — pause Harbor, freeing its ports for another stack

Usage: harbor stop        (no flags)

Frees :80 :443 :6379 :1025 :8025 and stops nginx, dnsmasq, the PHP pools and the
shared stack. Plists, certs and resolver are kept — resume with `harbor start`.

Project stacks are NOT stopped (they live on 20000+); use `harbor down <name>`.

Sudo: stopping the nginx LaunchDaemon.

See also: harbor start · harbor down <name> · harbor teardown
EOF
  ;;

  start) cat <<'EOF'
harbor start — resume Harbor after `harbor stop`

Usage: harbor start        (no flags)

Reloads the PHP pools, dnsmasq, nginx and the shared stack.

Free :80/:443 from your other stack first — a busy port only warns, it doesn't
fail, and nginx just won't come up.

Sudo: starting the nginx LaunchDaemon.

See also: harbor stop · harbor status
EOF
  ;;

  status) cat <<'EOF'
harbor status — what's running, and self-heal anything that died

Usage: harbor status        (no flags)

Shows the default PHP + xdebug state, each platform service (nginx, dnsmasq, PHP
pools, shared redis + mailpit), then the project table.

Self-healing: it reloads dead com.harbor.* units and warns when it did. That's a
mutation, not just a report — `harbor doctor` is the read-only one.

Paused (after `harbor stop`) short-circuits: no heal, no listing.
No sudo — nginx is probed by port precisely to avoid it.

See also: harbor ps · harbor doctor
EOF
  ;;

  ps|list) cat <<'EOF'
harbor ps — one row per project (alias: harbor list)

Usage: harbor ps        (no flags)

Columns: PROJECT FRAMEWORK PHP STACK LINKED PORTS. A project whose stack is up is
shown in green. Only directories with a manifest are listed.

  STACK    up = its compose stack has running containers
  LINKED   yes = etc/nginx/sites/<name>.test.conf exists
  PORTS    the project's MySQL port, or `db:-` for a project with no `mysql`
           service

See also: harbor status (platform services too) · harbor up | down <name>
EOF
  ;;

  php) cat <<'EOF'
harbor php — PHP versions and pools. Three different knobs — see below.

Usage: harbor php [<ver>|sync|use <ver>]

  (no args)      Show pool status: default version, xdebug state, per-version pool
  <ver>          Set the DEFAULT PHP for NEW sites only (existing pins unchanged)
  sync           Re-create pools after `brew install`/uninstall of a php@x
  use <ver>      Switch the BREW-LINKED cli `php` (plain terminal / IDE / global
                 composer). Independent of Harbor: `harbor run` and nginx always
                 use each project's own pinned version regardless.

All installed versions run concurrently as on-demand pools — a project pins its
version via manifest `php:` or a .php-version file, not via this command.

Examples:
  harbor php                # what's running
  harbor php 8.3            # new projects default to 8.3
  harbor php use 8.3        # my terminal's `php` becomes 8.3 (hash -r after)

See also: harbor xdebug --help · harbor link <name> (re-point a site's pool)
EOF
  ;;

  xdebug) cat <<'EOF'
harbor xdebug — global Xdebug toggle, trigger-based on 127.0.0.1:9003

Usage: harbor xdebug [on|off|status]        (default: status)

  on       Enable across all pools AND the project CLI, then reload pools
  off      Disable (also neutralizes an xdebug your brew php.ini loads)
  status   Print the current state

Trigger-based, so leaving it on is cheap — a session only starts when triggered:

  Web:  browser extension (Xdebug helper), or append ?XDEBUG_TRIGGER=1
  CLI:  XDEBUG_TRIGGER=1 harbor magento setup:upgrade

Configured at launch via -d flags; brew's php.ini is never edited. Needs xdebug
built for that PHP version (`pecl install xdebug`; `harbor doctor` shows which
versions have it).

Examples:
  harbor xdebug on
  XDEBUG_TRIGGER=1 harbor artisan queue:work

See also: harbor doctor (which versions have xdebug) · harbor php --help
EOF
  ;;

  update) cat <<'EOF'
harbor update — fast-forward Harbor itself to origin/main

Usage: harbor update [--check] [--stash] [--yes|-y]

  --check    Report pending commits and exit; changes nothing
  --stash    git stash -u first, pop after (a dirty tree otherwise aborts)
  --yes|-y   Sets HARBOR_YES=1 for any nested prompt

Fast-forward only — never a merge commit or a history rewrite. A diverged branch
aborts and asks you to reconcile. Also force-reseeds the agent skill into every
project (overwriting the managed files in place).

Afterwards it prints targeted next steps based on what changed (platform
templates -> `harbor setup`; compose -> `harbor render`/`up`) and runs doctor. It
never mutates host state itself — no sudo, no launchd reload.

Examples:
  harbor update --check
  harbor update --stash

See also: harbor version · harbor setup
EOF
  ;;

  test) cat <<'EOF'
harbor test — run Harbor's own unit suite (test/)

Usage: harbor test [filter]

  filter    Substring match on the test FILE name

Pure bash, zero dependencies, no host mutation — no Docker, launchd, nginx or
certs are touched. Each test file runs in its own process. Exits nonzero if any
assertion fails.

Examples:
  harbor test
  harbor test manifest      # just test_manifest.sh

See also: CLAUDE.md §6.5 (what belongs in the suite)
EOF
  ;;

  completion) cat <<'EOF'
harbor completion — emit shell completion (commands, projects, help topics)

Usage: harbor completion bash|zsh        (argument required)

Prints a script to stdout; it writes nothing itself.

  bash:  echo 'source <(harbor completion bash)' >> ~/.bashrc
  zsh:   echo 'source <(harbor completion zsh)'  >> ~/.zshrc

PHP versions are baked in when emitted, so re-source after a `harbor update`.
Project names are looked up live at completion time.

See also: harbor help (all commands)
EOF
  ;;

  secure) cat <<'EOF'
harbor secure — re-issue the shared TLS cert, optionally adding hostnames

Usage: harbor secure [host...]

  (no args)   Re-issue the cert with the current SAN set
  host...     Add each hostname as a SAN, then re-issue

SANs are cumulative and persist in var/cert-sans. There is no removal flag — edit
that file to drop one. `harbor link` adds a site's SAN for you, so you rarely
need this directly.

Exact per-site SANs are required: a bare *.test is NOT trusted under the reserved
.test TLD. Needs mkcert with its CA installed (`mkcert -install`).

Sudo: reloading nginx.

Example:
  harbor secure api.test admin.shop.test

See also: harbor link <name> · harbor doctor
EOF
  ;;

  mail) cat <<'EOF'
harbor mail — the shared Mailpit + Redis stack

Usage: harbor mail [up|down]

  (no args)   Open the Mailpit UI at http://localhost:8025
  up          Start the shared stack
  down        Stop it (volumes kept)

Caution: this controls Redis too, not just Mailpit — `harbor mail down` stops the
shared Redis that EVERY project uses. That's why `harbor status` suggests
`harbor mail up` when redis shows DOWN.

Ports: mailpit :1025 (SMTP) / :8025 (UI), redis :6379 — all on 127.0.0.1.

See also: harbor status · harbor redis --help
EOF
  ;;

  # --- projects ---------------------------------------------------------------
  new) cat <<'EOF'
harbor new — scaffold a brand-new project and serve it, end to end

Usage: harbor new <name> [framework]        (framework defaults to: plain)

  framework   laravel | symfony | codeigniter | magento | plain

Chains 6 steps: init -> up -> scaffold (composer create-project) -> wire ->
install -> link + open. Fails if the project dir exists and isn't empty (use
`harbor init` to adopt existing code).

No --services flag here — the init step underneath still prompts (interactive
picker on a terminal) or silently takes the framework default under
HARBOR_YES=1/non-interactive. Need a different list? Let it default, then edit
`services:` in the manifest and `harbor render <name> && harbor up <name>`.

wire and install are best-effort — only init, up and link are fatal.
Sudo: the final link reloads nginx.

Examples:
  harbor new shop magento
  harbor new blog laravel

See also: harbor init --help (adopt existing code) · harbor destroy <name> (undo)
EOF
  ;;

  init) cat <<'EOF'
harbor init — allocate ports and write the manifest (no scaffolding)

Usage: harbor init <name> [framework] [--php <ver>] [--existing]
                    [--services "a,b"]

  framework        Auto-DETECTED from the code if omitted (bin/magento -> magento,
                   artisan -> laravel, bin/console -> symfony, spark ->
                   codeigniter, else plain)
  --php <ver>      Pin PHP. Default: .php-version, else the global default
  --existing       Advisory only: warns if the dir has no app code yet
  --multistore <m> Accepted but only prints a hint — edit the manifest instead
  --services "a,b"  Which backing services to run. Omit to be asked (or to get
                    the framework default when not on a terminal, or under
                    HARBOR_YES=1 — scripted `harbor init` calls are unaffected).
                    --services ""  or  --services none  -> no containers at all.
                    Catalog is derived from templates/compose/services/*.yml.tmpl
                    and shown numbered, alphabetically, by the interactive
                    picker — run `harbor init <name>` on a terminal to see it
                    rather than trusting a list here that can drift.

Writes projects/<name>/.harbor/harbor.yml (the source of truth), the compose
file, connection.env, .gitignore, scripts, and the agent skill. Default services:
magento -> mysql + opensearch + rabbitmq; everything else -> mysql.

Flags and the framework may appear in any order. No sudo, no confirm.

Examples:
  harbor init shop                        # detect framework from the code
  harbor init legacy --php 7.4 --existing

See also: harbor new --help (greenfield) · harbor render · harbor up
EOF
  ;;

  render) cat <<'EOF'
harbor render — regenerate compose + connection.env from the manifest  [confirms]

Usage: harbor render <name>        (no flags)

Run after editing the manifest's `services:` (versions, or adding/removing a
service). Regenerating does NOT apply anything — follow with `harbor up <name>`.

Dropping a service whose data volume still exists confirms first. Your data is
NOT deleted — the named volume is kept and re-adding the service reattaches it
intact; only `harbor destroy <name>` drops volumes. Growing the list, or
dropping a service that was never `up`ed (no volume yet), never prompts.
HARBOR_YES=1 skips the prompt (there is no --yes flag). Declining leaves the
manifest, compose file and containers untouched.

Otherwise safe: it doesn't touch your manifest beyond that, except to
materialize a legacy list-format `services:` into the explicit map form. Also
reseeds the project's agent skill (non-clobbering).

Example:
  harbor render shop && harbor up shop

See also: harbor up · harbor init --help · harbor destroy --help
EOF
  ;;

  link) cat <<'EOF'
harbor link — serve the project at https://<name>.test

Usage: harbor link <name>        (no flags)

Renders the vhost, adds the site's exact cert SAN, re-issues the shared cert, and
reloads nginx. Re-run it after changing the project's PHP version to re-point the
vhost at the right pool.

A Magento project with `multistore.mode: domain` also gets *.<name>.test
automatically — there is no --wildcard flag.

Docroot: manifest `docroot:` wins, else magento->pub, laravel/symfony->public,
codeigniter->public if present, plain->project root. A missing docroot only
warns; the site 404s until it exists.

Sudo: `nginx -t` and reload.

See also: harbor unlink · harbor open · harbor secure --help
EOF
  ;;

  unlink) cat <<'EOF'
harbor unlink — remove the project's vhost

Usage: harbor unlink <name>        (no flags)

Removes the vhost, drops <name>.test (and *.<name>.test) from the cert SANs,
re-issues the cert, and reloads nginx. The stack keeps running — use
`harbor down <name>` for that.

Custom `domains:` SANs from the manifest are NOT removed; edit var/cert-sans.

Sudo: nginx reload.

See also: harbor link · harbor down · harbor destroy
EOF
  ;;

  wire) cat <<'EOF'
harbor wire — inject DB/Redis/mail config into the app, surgically

Usage: harbor wire <name> [--print]

  --print   Print the connection details and write nothing. Must come right
            after <name>.

Allowlist-only and idempotent: it replaces or appends individual keys and never
blanket-rewrites your config. Backs the file up ONCE to <file>.harbor-bak — a
second wire will not refresh that backup.

Per framework:
  laravel      .env       (DB_*, REDIS_*, MAIL_*)
  symfony      .env.local (DATABASE_URL, REDIS_URL, MAILER_DSN) — .env untouched
  codeigniter  .env (CI4); CI3 falls back to .harbor/connection.php
  magento      nothing — Magento is configured by `harbor install` (setup:install)
  plain        .harbor/connection.php

A project with no `mysql` service skips the DB_* lines (still wires Redis +
mail) — laravel/symfony/codeigniter/plain wire fine without one. A DB-less
Magento project instead refuses up front with a fix hint (Magento requires a
database).

Use 127.0.0.1 (not localhost) and the project's allocated port — both are in the
printed output.

Example:
  harbor wire shop --print

See also: harbor install --help · harbor init
EOF
  ;;

  up) cat <<'EOF'
harbor up — start the project's Docker stack

Usage: harbor up <name>        (no flags)

Starts the containers and waits up to 180s for healthchecks (a timeout only
warns). Needs the Docker daemon.

A project with `services: {}` (no `mysql`/etc.) has no containers at all — `up`
is a no-op for it, not an error, since bulk/scripted runs over every project
shouldn't fail on a DB-less one.

Does NOT start the shared Redis/Mailpit — that's `harbor mail up` (or setup).

See also: harbor down · harbor restart · harbor ps
EOF
  ;;

  down) cat <<'EOF'
harbor down — stop the project's Docker stack (data kept)

Usage: harbor down <name>        (no flags)

Note: this also FLUSHES the project's Redis indices (cache/page/session/spare) —
a stopped project shouldn't leave stale cache behind for the next one. If you
need the cache preserved, don't use `down`.

MySQL volumes are kept. To drop volumes use `harbor destroy <name>`.

No-op (not an error) for a project with `services: {}` — there's nothing to
stop.

See also: harbor up · harbor destroy --help · harbor stop (all of Harbor)
EOF
  ;;

  restart) cat <<'EOF'
harbor restart — restart Harbor itself, or one project's containers

Usage: harbor restart               restart Harbor (stop + start)   [sudo]
       harbor restart <name>        restart that project's containers
                                    (no flags)

With no name it is exactly `harbor stop && harbor start`: shared stack, php
pools, dnsmasq and nginx go down and come back up. nginx is a LaunchDaemon, so
that path asks for sudo. Running project stacks are left alone — they sit on
20000+ ports.

With a name it restarts only that project's containers. Unlike `down`, it does
NOT flush Redis. It does not re-render compose either — after editing the
manifest run `harbor render <name> && harbor up <name>`. No-op (not an error)
for a project with `services: {}` — there's nothing to restart.

See also: harbor stop · harbor start · harbor up · harbor down · harbor render
EOF
  ;;

  destroy) cat <<'EOF'
harbor destroy — remove a project's stack, volumes, ports and vhost  [confirms]

Usage: harbor destroy <name> [--files]

  --files   ALSO delete the project directory itself (your code). Must come
            right after <name>. The prompt does not mention this — be sure.

Drops containers AND volumes (the database is gone), unlinks the vhost, and
releases the port block — a later re-init may get different ports.

Skip the prompt with HARBOR_YES=1 (there is no --yes flag).
Sudo: nginx reload via unlink.

Examples:
  harbor destroy shop
  harbor db backup shop && harbor destroy shop     # keep the data first

See also: harbor down (just stop) · harbor db backup --help
EOF
  ;;

  logs) cat <<'EOF'
harbor logs — tail project, platform, or site logs

Usage: harbor logs <name> [service] [-f]
       harbor logs nginx|php|dnsmasq [-f]
       harbor logs clear [all|nginx|php|dnsmasq|<name>]

  <name> [args]   docker compose logs --tail=200; extra args pass through, so
                  `-f` and service names work as usual
  nginx|php|dnsmasq   Harbor's own platform logs (last 200 lines)
  clear [target]  Truncate logs in place (default: all)

Platform logs follow on ANY extra argument, not just -f — `harbor logs nginx x`
follows too.

`harbor logs <name>` is a no-op (not an error) for a project with `services: {}`
— there are no containers to log.

`clear` truncates in place rather than deleting, so running daemons keep their
file handles. No sudo needed: nginx's logs are deliberately user-owned.

Examples:
  harbor logs shop -f
  harbor logs nginx -f
  harbor logs clear shop

See also: harbor status
EOF
  ;;

  open) cat <<'EOF'
harbor open — open https://<name>.test in your browser

Usage: harbor open <name>        (no flags)

Prints the URL if it can't open a browser. It does not check that the project is
linked or running — if the page fails, try `harbor ps` and `harbor link <name>`.

See also: harbor link · harbor ps
EOF
  ;;

  install) cat <<'EOF'
harbor install — run the framework's installer/migrations

Usage: harbor install <name>        (no flags; <name> is required)

  magento      setup:install wired to Harbor's ports/credentials, then a local-DX
               pass (developer mode, 2FA off, reindex, cache flush)
  laravel      key:generate, then `migrate --force`
  symfony      doctrine:migrations:migrate --no-interaction
  codeigniter  spark migrate (CI4)
  plain        nothing

Caution: this runs migrations with --force and no prompt — it can change or drop
data in the project's database. Stack must be up (Magento checks; others don't).

Magento needs `mysql` + `opensearch` + `rabbitmq` — missing any of them names
ALL the missing ones (`magento needs: opensearch rabbitmq`) with a fix hint,
rather than dying partway through on an unbound variable.

See also: harbor seed --help · harbor wire --help · harbor up
EOF
  ;;

  seed) cat <<'EOF'
harbor seed — run the framework's seeders

Usage: harbor seed <name>        (no flags; <name> is required)

  laravel      artisan db:seed --force
  symfony      doctrine:fixtures:load --no-interaction
  codeigniter  spark db:seed (CI4)
  magento      setup:upgrade  — NOT a seeder; it applies schema/data patches
  plain        nothing

See also: harbor install --help
EOF
  ;;

  # --- running code -----------------------------------------------------------
  run) cat <<'EOF'
harbor run — run any command under the project's PHP, in its directory

Usage: harbor run [<name>] <cmd...>
       ( <name> optional inside a project dir or a `harbor shell` )

The PHP is the project's pinned version, with its manifest php_ini and the xdebug
toggle applied. PATH order: .harbor/scripts, then .harbor/bin (tool shims), then
your host PATH.

Gotcha — argument count changes the semantics:
  ONE arg   -> run through `sh -c`, so pipes/globs/&& work:
              harbor run shop 'php -v | head -1'
  TWO+ args -> exec'd directly, no shell involved:
              harbor run shop php -v

Examples:
  harbor run shop php -v
  XDEBUG_TRIGGER=1 harbor run shop php bin/thing

See also: harbor shell · harbor composer --help · harbor help artisan
EOF
  ;;

  composer) cat <<'EOF'
harbor composer — Composer under the project's pinned PHP

Usage: harbor composer [<name>] <args...>
       ( <name> optional inside a project dir or a `harbor shell` )

Runs with COMPOSER_MEMORY_LIMIT=-1. Needs composer on the host.

Gotcha: Composer itself is invoked with the real PHP binary, NOT Harbor's shim —
so the manifest's php_ini and the xdebug toggle do NOT apply to the Composer
process. They do apply to any `php` a Composer script spawns (that resolves
through the shim). To debug Composer itself:
  harbor run <name> php -d xdebug.mode=debug $(which composer) install

`harbor composer --help` reaches Composer's own help — this text is at
`harbor help composer`.

Examples:
  harbor composer shop require vendor/pkg
  harbor composer install       # inside the project dir

See also: harbor run --help
EOF
  ;;

  artisan) cat <<'EOF'
harbor artisan — Laravel's artisan under the project's PHP

Usage: harbor artisan [<name>] <args...>
       ( <name> optional inside a project dir or a `harbor shell` )

Runs `php artisan …` via harbor run, so the pinned PHP version, manifest php_ini
and the xdebug toggle all apply.

`harbor artisan --help` reaches artisan's own help — this text is at
`harbor help artisan`.

Examples:
  harbor artisan shop migrate
  XDEBUG_TRIGGER=1 harbor artisan queue:work

See also: harbor run --help · harbor install --help
EOF
  ;;

  console) cat <<'EOF'
harbor console — Symfony's bin/console under the project's PHP

Usage: harbor console [<name>] <args...>
       ( <name> optional inside a project dir or a `harbor shell` )

Runs `php bin/console …` via harbor run — pinned PHP, manifest php_ini and the
xdebug toggle all apply.

`harbor console --help` reaches Symfony's own help; this text is at
`harbor help console`.

Example:
  harbor console shop cache:clear

See also: harbor run --help
EOF
  ;;

  spark) cat <<'EOF'
harbor spark — CodeIgniter 4's spark under the project's PHP

Usage: harbor spark [<name>] <args...>
       ( <name> optional inside a project dir or a `harbor shell` )

Runs `php spark …` via harbor run. CI3 has no spark — use `harbor run` instead.

`harbor spark --help` reaches spark's own help; this text is at
`harbor help spark`.

Example:
  harbor spark shop migrate

See also: harbor run --help
EOF
  ;;

  magento) cat <<'EOF'
harbor magento — bin/magento under the project's PHP

Usage: harbor magento [<name>] <args...>
       ( <name> optional inside a project dir or a `harbor shell` )

A plain passthrough — it adds no subcommands of its own. The pinned PHP version,
manifest php_ini (e.g. memory_limit) and the xdebug toggle all apply.

Harbor's Magento helpers live on other commands:
  harbor install <name>          setup:install + local-DX pass
  harbor seed <name>             setup:upgrade
  harbor db import … --reconfigure   fix base URLs + search after an import

`harbor magento --help` reaches Magento's own help; this text is at
`harbor help magento`.

Examples:
  harbor magento shop setup:di:compile
  XDEBUG_TRIGGER=1 harbor magento indexer:reindex

See also: harbor run --help · harbor db --help
EOF
  ;;

  node|npm) cat <<'EOF'
harbor node / harbor npm — Node via nvm, using the project's version

Usage: harbor node [<name>] <args...>
       harbor npm  [<name>] <args...>
       ( <name> optional inside a project dir or a `harbor shell` )

Version: manifest `node:` -> the project's .nvmrc -> nvm's default. Needs nvm; if
the version isn't installed it PROMPTS to install it (declining continues on the
default version rather than aborting).

Gotcha: unlike `harbor run`, these do not put the project's PHP shim,
.harbor/scripts or .harbor/bin on PATH — an npm script calling `php` gets your
host's linked php, not the project's pin. Use `harbor run` when a script needs
the pinned PHP.

`harbor npm --help` reaches npm's own help; this text is at `harbor help npm`.

Example:
  harbor npm shop run build

See also: harbor run --help · harbor shell
EOF
  ;;

  shell) cat <<'EOF'
harbor shell — a shell in the project dir with its PHP/Node on PATH

Usage: harbor shell [<name>]
       ( <name> optional inside a project dir )

PATH order: the project's PHP shim (pinned version + php_ini + xdebug), then
.harbor/scripts, then .harbor/bin (tool shims), then your PATH. `exit` returns.

It exports HARBOR_PROJECT, so every `[<name>]`-optional command resolves to this
project even if you cd elsewhere — handy, and occasionally surprising.

Example:
  harbor shell shop

See also: harbor run --help · harbor mysql --help
EOF
  ;;

  tool) cat <<'EOF'
harbor tool — run a containerized CLI tool against the project

Usage: harbor tool <name> <tool> [args...]        (<name> is REQUIRED)

Runs the tool in a throwaway container so nothing is installed on your host. The
shim is regenerated on every run, so you never need `tools sync` first.

Built-in catalog: wkhtmltopdf, ghostscript (gs), pandoc, ffmpeg, soffice
(libreoffice). Add or override in the manifest:
  tools: { wkhtmltopdf: { image: "surnet/alpine-wkhtmltopdf:...", bin: wkhtmltopdf } }

Gotchas:
  • <name> is required — this one does NOT infer the project from your cwd.
  • Only the project dir and $TMPDIR are visible to the tool, mounted at their
    real paths (so absolute paths work). Relative args resolve from the PROJECT
    ROOT, not your cwd.
  • Needs the Docker daemon. No TTY, but stdin/pipes work.

Example:
  harbor tool shop wkhtmltopdf in.html out.pdf

See also: harbor tools --help · harbor run --help
EOF
  ;;

  tools) cat <<'EOF'
harbor tools — (re)generate the project's tool shims

Usage: harbor tools sync <name>        (`sync` is the only subcommand; <name> REQUIRED)

Writes a shim per manifest `tools:` entry into <project>/.harbor/bin/, which is
on PATH for run/shell/artisan/etc. That's how an app finds `wkhtmltopdf` with
nothing installed on the host.

You rarely need this: `harbor tool` regenerates the shim it needs on every run.
Use `tools sync` when the APP itself shells out to the binary.

Gotchas:
  • Shims are named after the tool's `bin`, so aliases collapse: `ghostscript`
    and `gs` both produce .harbor/bin/gs; `libreoffice` produces `soffice`.
  • A project with no `tools:` reports "synced 0 tool shim(s)" — success, not an
    error.
  • .harbor/scripts beats .harbor/bin on PATH, so a committed script shadows a shim.

Example:
  harbor tools sync shop

See also: harbor tool --help
EOF
  ;;

  # --- data -------------------------------------------------------------------
  db) cat <<'EOF'
harbor db — per-project MySQL databases

Usage: harbor db <sub> <name> [args]        (<name> is required for every sub)

  create <name> [db] [user] [pass]   Create DB + user (each defaults to <name>)
  drop <name> [db]                   Drop the database             [confirms]
  backup <name> [db] [file]          Dump to backups/db/<name>/<db>-<ts>.sql.gz
  import <name> <file> [db]          Import a dump (auto-backup first)
  pull <name> [import flags]         mysqldump over ssh, straight into import
  sandbox <sub>                      Scratch MySQL, no project — see below

import flags (also accepted by `pull`):
  --no-backup        Skip the automatic pre-import backup
  --force            Best-effort load: skip statements the server rejects, and
                     load a dump that looks truncated (refused by default)
  --keep-definers    Keep DEFINER= clauses (stripped by default)
  --replace OLD=NEW  Serialized-safe search/replace after load (repeatable)
  --stream-replace   Do --replace with sed before load (faster, NOT serialize-safe)
  --no-hooks         Skip .harbor/hooks/
  --no-rules         Skip .harbor/import-rules
  --reconfigure      Magento: fix base URLs + search engine after import

Requires a `mysql` service. A project with none (`services: {}` or no `mysql`
key) gets `no database service for '<name>'` and a fix hint (add it to
`services:`, then `harbor render && harbor up`) — not a "stack not running"
error.

Notes: `import` overwrites the target DB with no prompt — the auto-backup
(backups/db/<name>/pre-import-<ts>.sql.gz) is the safety net. A dump that ends
mid-statement (truncated download/export) is refused with a hint — every table
after the cut would be silently missing. Rules and hooks are validated up
front, before the backup/load: a malformed rule (missing `=>`, invalid `re:`
regex) aborts, a hook that would be skipped (not executable, misplaced *.sql)
warns, and a shell hook with a syntax error aborts. `drop` removes the
database but keeps the MySQL user. `pull` needs manifest `remote: { host, db }`.
Skip a confirm with HARBOR_YES=1 (there is no --yes flag). Stack must be up.

Recurring rules/fixups live in the project, seeded as inert samples by init:
  .harbor/import-rules                 old => new, applied on every import
  .harbor/hooks/post-import.d/*.sql    SQL run after every import — pin records
                                       to local values (base URLs, dev passwords)
  .harbor/hooks/pre-import.d/          executables that edit the dump pre-load

Examples:
  harbor db backup shop
  harbor db import shop dump.sql.gz --replace https://prod.com=https://shop.test
  harbor db pull shop --reconfigure

See also: harbor db sandbox --help · harbor mysql --help · harbor media --help
EOF
  ;;

  db-sandbox) cat <<'EOF'
harbor db sandbox — a scratch MySQL on 127.0.0.1:3306, owned by no project

Usage: harbor db sandbox <sub> [args]        (never takes a project name)

  create <db> [user] [pass]   Create DB + user (each defaults to <db>)
  drop <db> [user]            Drop the DB *and its user*          [confirms]
  list                        List databases                        (alias: ls)
  backup <db> [file]          Dump to backups/db/sandbox/<db>-<ts>.sql.gz
  restore <db> <file>         Load a dump into <db>            (alias: import)
  console [db]                Interactive root client            (alias: mysql)
  up | down                   Start / stop (down keeps the volume)  (alias: stop)
  destroy                     Stop AND drop the data volume      [confirms]
  status                      Is it running? (default; aliases: ps, no args)

This is the "just give me a MySQL" server — deliberately on the standard :3306,
so it can clash with a host MySQL. Override with SANDBOX_MYSQL_PORT in
~/.config/harbor/config. It starts lazily on first use.

`down` keeps your data; `destroy` deletes it. `restore` is a thin loader — no
auto-backup, no hooks, no --replace (that's `harbor db import`). Skip a confirm
with HARBOR_YES=1 (there is no --yes flag).

Examples:
  harbor db sandbox create scratch
  harbor db sandbox restore scratch dump.sql.gz

See also: harbor db --help (per-project databases)
EOF
  ;;

  media) cat <<'EOF'
harbor media — sync remote media/storage down to the project

Usage: harbor media pull <name>        (`pull` is the only subcommand)

Destination by framework: magento -> pub/media, laravel -> storage/app,
otherwise -> media/. Caches are excluded.

CAUTION: this is `rsync -az --delete` and is NOT confirm-gated. Local-only files
under the destination are deleted to mirror the remote, with no prompt.

Needs manifest `remote: { host: user@host, media: /path }` and rsync. The stack
does not need to be up.

Example:
  harbor media pull shop

See also: harbor db pull (in `harbor db --help`)
EOF
  ;;

  store) cat <<'EOF'
harbor store — Magento multi-store routing

Usage: harbor store add <name> <code> --domain <host> | --path <seg>
       harbor store list <name>
       harbor store rm <name> <code>

  --domain <host>   Route by hostname  -> <code>.<name>.test
  --path <seg>      Route by URL path  -> <name>.test/<seg>

The mode flag must come straight after <code>; one of the two is required.

A project uses ONE mode — domain or path — and it's locked once set: adding a
store in the other mode fails. Note the lock persists even after removing every
store; edit the manifest's `multistore:` to reset.

Store codes allow [a-zA-Z0-9_] only — no hyphens (unlike project names). Adding
or removing re-links the vhost (sudo: nginx reload). Re-adding an existing code
replaces it.

Example:
  harbor store add shop uk --domain uk.shop.test

See also: harbor link --help
EOF
  ;;

  mysql) cat <<'EOF'
harbor mysql — a MySQL client into the project's database

Usage: harbor mysql [<name>] [args...]
       ( <name> optional inside a project dir or a `harbor shell` )

Opens a root client inside the project's MySQL container with the project's
database already selected — no host mysql client needed. Extra args go to the
mysql client.

Notes: connects as root, not the app user. There's no [db] argument — `USE
other_db;` to switch. The stack must be up. Requires a `mysql` service — a
project with none gets a fix hint instead of a misleading "stack not running".

Examples:
  harbor mysql shop
  harbor mysql shop -e 'SHOW TABLES'

See also: harbor db --help · harbor db sandbox --help
EOF
  ;;

  redis) cat <<'EOF'
harbor redis — redis-cli scoped to the project's cache index

Usage: harbor redis [<name>] [args...]
       ( <name> optional inside a project dir or a `harbor shell` )

Redis is SHARED across projects — each project gets a block of 4 DB indices
(cache, page, session, spare) rather than its own container. This command targets
the project's CACHE index; reach another with `-n <idx>` (the later -n wins).

There is no `harbor redis flush` subcommand — args are passed straight to
redis-cli, so use `harbor redis <name> FLUSHDB` (which wipes that index, with no
prompt). `harbor down <name>` also flushes the project's indices.

Needs the shared stack up (`harbor mail up`).

Examples:
  harbor redis shop
  harbor redis shop KEYS '*'

See also: harbor mail --help · harbor down --help
EOF
  ;;

  *) return 1 ;;
  esac
}

# cmd_help [<cmd>] — `harbor help` (general usage) or `harbor help <cmd>` (topic).
cmd_help() {
  # `harbor help`, `harbor help --help` — both mean "how do I use help": the
  # command list. Don't look `--help` up as a topic name and fail.
  case "${1-}" in ''|-h|--help) usage; return 0 ;; esac
  # `harbor help db sandbox` — a subcommand topic is keyed `<cmd>-<sub>`, so accept
  # it spelled the way a user would actually type it.
  [ $# -gt 1 ] && help_topic "$1-$2" && return 0
  if help_topic "$1"; then return 0; fi
  { err "no help topic for '$1'"
    printf '\nTopics:\n'
    help_topics | tr '\n' ' ' | fold -s -w 72 | sed 's/^/  /'
    printf '\nTry: harbor help    (all commands)\n'
  } >&2
  return 1
}
