# Tests

Moved verbatim from Harbor's root `CLAUDE.md`. Authoritative.

## 6.5 Tests

Harbor has a **zero-dependency, pure-bash** unit suite in `test/` — no `bats`, no
installs; it runs on macOS system bash 3.2 like Harbor itself. Layout: `run.sh`
(discovers `test_*.sh`, runs each in its own process, sums the `__TALLY__` line,
exits nonzero on any failure) + `lib.sh` (assert helpers: `assert_eq`,
`assert_ok`/`assert_fail` — which subshell the command so a `die`/`exit` can't
kill the run — `assert_contains`, `harbor_load` to source the units under test,
and `skip_all <reason>` to bail a file whose precondition isn't met). Run it with
`harbor test` or `./test/run.sh` (filter: `harbor test manifest`).

- **Two output modes, one set of helpers.** `run.sh` exports
  `HARBOR_TEST_STREAM=1`, which makes `pass`/`fail`/`skip` emit a compact
  SOH-prefixed marker stream that the runner renders as a **two-column grid** —
  one cell per file, `✓ <n>` all-pass / `✗ <failed>/<total>` otherwise, with
  every failure expanded in a `FAILURES` block below (counts come from the
  `__TALLY__` line; the markers carry the failure detail). Run a file
  *standalone* (`bash test/test_x.sh`) and the same helpers print the readable
  `ok`/`FAIL` lines instead — and on a terminal a `testing <part>…`
  spinner runs per file while it executes (silent when redirected) — so keep both branches working when you
  touch `lib.sh`, and **don't `printf` your own `skip`/pass output** in a test
  file (call the helpers, or the runner can't parse it). Markers are SOH-prefixed
  precisely so a description or an expected/actual value can never be mistaken for
  one; anything a test writes to stdout/stderr that isn't a marker is surfaced,
  not hidden (dimmed note, or attributed to an open failure).

- **Scope is pure logic only** — parsing, allocation, validation, templating,
  serialized-replace. Tests **never touch the host**: no Docker, launchd, nginx,
  certs, or the sandbox. Use throwaway `mktemp -d` dirs and override globals
  (`HARBOR_PORTS_DIR`, `HARBOR_CONFIG`, …); clean up on `EXIT`.
- **Never put an assertion inside a `( … )` subshell.** `PASS`/`FAIL` are plain
  variables, so a subshell's increments never reach `report` — the file tallies
  only its top-level assertions and `run.sh` **exits 0 even when an assertion
  inside the subshell failed**, which is worse than no test at all. Scope a
  global with a **per-call env prefix** instead
  (`"$(HARBOR_CONFIG="$cfg" config_get PORT)"`, `test_common.sh`), or assign it
  at top level between assertions. When a case genuinely needs a child shell
  (checking a function's exit status under `set -e`), wrap it in a helper that
  *returns* a status and assert on that with `assert_ok`/`assert_fail` — never
  assert inside the child.
- **Set `HARBOR_CONFIG` *after* sourcing the lib, never as an env prefix on a
  `bash -c`.** `lib/common.sh` assigns it unconditionally, so a prefix is
  overwritten at source time and the test silently exercises the default config
  instead of the fixture — it still passes, while testing nothing it claims to.
- **When you add or change a pure-logic function** (`lib/manifest.sh`,
  `lib/ports.sh`, `lib/common.sh` helpers, `lib/search-replace.php`'s `rr()`), add
  or adjust its test in the same commit. Keep `test/` shellcheck-clean.
- **Testability seams stay behavior-neutral.** `search-replace.php` returns early
  when `HARBOR_SR_LIB_ONLY=1` so `rr()` can be included and tested without a DB;
  real CLI runs leave it unset and behave identically. Prefer this pattern over
  refactoring production logic for tests.
