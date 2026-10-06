# Bash and design best practices

Moved verbatim from Harbor's root `CLAUDE.md`. Authoritative.

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
- **A `mktemp` template's `XXXXXX` must be the LAST characters** — BSD `mktemp`
  (macOS) only substitutes *trailing* X's, so `harbor-pull.XXXXXX.sql.gz` is
  never randomized: it's taken literally, and the second run dies with
  `mkstemp failed … File exists`. GNU `mktemp` substitutes it anyway, so this
  passes every Linux test and only bites on the target platform. When you need a
  suffix, create with a trailing-X template and **rename** afterward
  (`tmp="$(mktemp …XXXXXX)"; mv "$tmp" "$tmp.sql.gz"; tmp="$tmp.sql.gz"`) — as
  `db_pull` (`lib/remote.sh`) does, because `db_import` decompresses by extension.
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
- `db import`/`db pull` take an **auto-backup first** (`--no-backup` to skip),
  then prune to a retention window: only the newest N `pre-import-*.sql.gz` per
  project are kept (`_db_prune_backups`, `lib/db.sh`). N resolves manifest
  `backups.keep` (per-project override) → config `DB_BACKUP_KEEP`
  (`etc/config` global default) → **3** (`_db_backup_keep`);
  `0`/negative disables pruning. **Prune only auto-taken `pre-import-*` dumps —
  never manual `db backup` files** (`<db>-<ts>.sql.gz`); those are user-owned. A
  non-numeric value falls back to the default rather than risk deleting on garbage.
  **Prune only after a *successful* backup** (`_db_autobackup`, `lib/db.sh`): a
  failed dump still leaves a partial gzip (gzip exits 0 on empty input), and
  keeping it while pruning to the window could evict a valid older backup — so on
  failure the partial is removed and existing backups are left untouched, no
  prune. This is the same "empty ≠ failed" trap as §3: `| gzip > f` masks
  mysqldump's exit, so gate on the pipeline status under pipefail (`if dump | gzip
  && [ -s f ]`), not on the file existing. `_db_prune_backups` always reports the
  outcome (pruned/kept/off) so retention isn't a silent side effect.
- `db restore [--checkpoint N]` (`db_restore`, `lib/db.sh`) rolls back to a
  pre-import backup — checkpoints numbered **newest-first** (`#1` = last import) by
  `_db_checkpoints`/`_db_checkpoint_file`. It reloads **verbatim** by delegating to
  `db_import` with `--no-rules --no-hooks --keep-definers` (a pre-import backup is
  already local, wired data — re-running the import transform on it would be
  wrong), letting `db_import` take the pre-restore snapshot + prune. **Load-bearing
  ordering: stage the chosen checkpoint to `var/tmp` (a copy) *before* that
  snapshot runs** — the snapshot's retention prune only touches
  `backups/db/<name>/pre-import-*`, so restoring the *oldest* checkpoint while at
  the keep limit would otherwise delete the very file being restored. Copying it
  out of `backups/` first sidesteps that entirely. **Destructive gate:** bare
  `db restore` on an interactive stdin (`[ -t 0 ]`, non-`HARBOR_YES`) shows a
  numbered picker (`_db_restore_menu`, latest = #1 default, `q` cancels) and the
  deliberate numeric choice over its overwrite-warned prompt *is* the gate — no
  second `confirm()`. `--checkpoint N`, a non-tty stdin, and `HARBOR_YES=1` skip
  the menu and target #1; those paths take the normal `confirm()` (bypassed by
  `HARBOR_YES=1`). So exactly one interactive gate fires in every case, and
  automation still bypasses via `HARBOR_YES=1`.
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
- **A secret must never reach a process's argv, and the manifest must never
  hold one.** `ps` is world-readable, so a password on any command line
  (`mysqldump -pXXX`, and just as bad the wrapping `bash -c "…-pXXX…"` that `ssh
  host "cmd"` spawns) leaks to every user on both ends. `db pull`'s remote-auth
  path (`lib/remote.sh`) is the pattern to copy: the manifest carries only the
  **username** (`remote.user`); the password is resolved at run time
  (`HARBOR_REMOTE_DB_PASSWORD` → gitignored `.harbor/remote.env` → interactive
  prompt) and handed to the remote via **`MYSQL_PWD` exported *inside* the script
  fed to `ssh host 'bash -s'` on stdin** — never interpolated into argv. Values
  going into that remote script are single-quoted with `_shq` so an arbitrary
  password can't break quoting or inject. Any new gitignored secret file must be
  self-protecting in projects that predate its template line — `_ensure_gitignored`
  (`lib/common.sh`) appends the ignore entry whenever the file is present (not
  gated on which password source wins, or the env-var path would leave it
  un-ignored), fixing a missing trailing newline first so the entry can't glue
  onto the last line. **A seeded secrets file is CREATE-IF-ABSENT, never
  re-rendered** — the inverse of derived config (compose/vhost/connection.env),
  which is regenerated every `render`. `init_write_remote_env` (`lib/init.sh`,
  called from both `cmd_init` and `cmd_render`) writes `.harbor/remote.env` as a
  gitignored, all-commented template only when it doesn't exist, so it's
  discoverable yet a re-render can never wipe the user's password. Every line is
  commented, so a freshly seeded file resolves to nothing and changes no behavior.
  **When a secret can come from either an env var or a config file, use the SAME
  name for both surfaces.** Shipping `HARBOR_REMOTE_DB_PASSWORD` (env) but
  `REMOTE_DB_PASSWORD` (file key) bit a user immediately — they put the env-var
  name in the file and were still prompted. `.harbor/remote.env` uses the exact
  same key, `HARBOR_REMOTE_DB_PASSWORD`. Don't make people remember which name
  applies where.
- **The manifest is committable, so non-secret-but-sensitive infra (prod IP, SSH
  login, DB username) shouldn't be *forced* into it either.** Every `remote:`
  connection field resolves env var → gitignored `.harbor/remote.env` → manifest,
  via one helper `_remote_field <name> <ENVKEY> <subkey>` (`lib/remote.sh`) — so a
  user can lift the whole `remote:` block out of the committed manifest into
  `.harbor/remote.env` and commit nothing about prod. The manifest keys stay as a
  shareable fallback (last in precedence), so this is purely additive. `describe`
  resolves through the same helper so it reports the *effective* value, not a
  manifest echo. When you add a remote field, route it through `_remote_field`,
  not a bare `manifest_get remote.<x>`.
- **Run a remote command through `ssh host 'bash -s'` (script on stdin), not the
  login shell.** `set -o pipefail` — needed so a failed `mysqldump` isn't masked
  by `gzip`'s exit 0 — isn't valid in dash/csh/tcsh, and a login shell isn't
  guaranteed to be bash; delivering the script on stdin also keeps secrets out of
  argv. Apply it to BOTH the authed and the defer-to-remote-auth branches, not
  just the one carrying a password (that split was a shipped regression).
- **A remote `mysqldump` with no `-h` connects over the unix socket, which MySQL
  matches as `@localhost`.** App DB users are almost always granted for
  `@'127.0.0.1'`/`@'%'` (TCP), so a socket dump is denied — `Access denied …
  @'localhost'` (using password: YES) — despite correct credentials. When Harbor
  supplies the auth (`remote.user` set), default the dump to `-h 127.0.0.1` (how
  the app connects), overridable via `remote.db_host` (`localhost` forces the
  socket back). `localhost` and `127.0.0.1` are different accounts to MySQL; never
  treat them as interchangeable.
- **Prompt on `/dev/tty`, and gate on actually opening it, not `[ -r /dev/tty ]`.**
  Reading a secret from `/dev/tty` (not stdin) means the prompt still works when
  stdin is redirected, but `[ -r /dev/tty ]` can report readable on a controlling
  terminal that then fails to open ("Device not configured"), spewing errors and
  a bogus downstream failure instead of a clean "run interactively" hint. Probe
  with `if ! { : </dev/tty; } 2>/dev/null; then die …; fi`. Use `read -r -s` for
  the silent read and never echo the value back.

---
