# CHANGELOG discipline and the after-every-change checklist

Moved verbatim from Harbor's root `CLAUDE.md`. Authoritative.

## 4. CHANGELOG discipline

Harbor keeps a `CHANGELOG.md` following **[Keep a Changelog](https://keepachangelog.com)**
and **[SemVer](https://semver.org)**.

- **Every change that affects behavior, commands, config, or the host footprint
  updates `CHANGELOG.md` in the same commit** — under the `## [Unreleased]`
  section, in the right category: **Added / Changed / Deprecated / Removed /
  Fixed / Security**.
- Write entries for users, imperative and concise: *"Add `harbor tool` for
  containerized CLI binaries"*, not *"refactored db.sh"*.
- **Flag host-footprint changes explicitly.** Anything that adds/removes a file
  outside the repo, a sudo touchpoint, or a launchd unit gets a line and, if
  user-visible, a note in `README.md` + `plan.md`.
- On release, move `Unreleased` items under a new `## [x.y.z] - YYYY-MM-DD`
  heading and bump per SemVer (breaking → major, feature → minor, fix → patch).
- Don't invent dates — if you need today's date, ask or leave `Unreleased`.

---

## 7. After every change — required checklist

Run this **every time you finish a unit of work**, in order. Do not claim done
until all five pass.

1. **Harbor healthcheck.** Run `harbor doctor` (and `harbor status`) — all required
   checks green, every `com.harbor.*` unit loaded, nothing broken. For a touched
   command, do a real run (see `plan.md` → Verification), not just dry logic.
   `shellcheck` passes on touched scripts; the command is **idempotent** and has a
   working **undo** (teardown still fully cleans the host). If you touched a
   pure-logic function, run `./test/run.sh` and keep it green (see §6.5).
2. **Check `.gitignore`.** Any new generated/runtime/secret output (`etc/`, `var/`,
   `certs/`, `backups/`, project `.harbor/` runtime, tool shims) must be ignored;
   confirm nothing sensitive is staged and any newly-tracked file is intended
   (`git status` + `git check-ignore <path>`). Update `.gitignore` if needed.
3. **Update `CHANGELOG.md`.** Add an entry under `## [Unreleased]` in the right
   category; flag any host-footprint change explicitly (see §4).
4. **Update `CLAUDE.md`.** If the change established or altered a convention, rule,
   or pattern, persist it here (and in `plan.md`/`README.md` if user-visible) so it
   carries forward — never rely on memory alone.
5. **Sanity check — security, performance, usability.**
   - *Security:* loopback-only; no secrets committed; **no host pollution**
     (nothing written into brew config dirs); no new/unannounced sudo; destructive
     ops gated.
   - *Performance:* RAM stays low (ondemand pools, no needless resident
     containers, service heap caps); no per-request work that should be cached.
   - *Usability:* errors fail fast with a fix hint; confirms on destructive ops;
     help/completion and docs reflect the change.
