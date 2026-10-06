# Harbor — Agent Guide

Instructions for any AI agent building or modifying Harbor. **These rules
override default behavior. Follow them exactly.**

Harbor is a **hybrid local PHP dev platform** for macOS: PHP-FPM/nginx/Xdebug/
dnsmasq/TLS run natively (as Harbor-owned launchd units), while databases/search/
queues run in Docker. The goal is **low RAM, low clutter, zero pollution of the
host**. Read `plan.md` (full design + decisions) and `README.md` (user-facing
docs) before changing anything. The plan and README are the source of truth — if
your change contradicts them, update them in the same commit.

Implementation is **bash** (no runtime language deps). Target macOS + Apple
Silicon + Homebrew.

---

## 1. Critical rules (non-negotiable)

1. **Never pollute the host.** Do not write into Homebrew's config dirs
   (`$(brew --prefix)/etc/nginx`, `…/etc/php/*`, `…/etc/dnsmasq*`). See §4.
2. **Harbor owns its config.** Every nginx/php-fpm/dnsmasq config is rendered
   from `templates/` into Harbor's `etc/`, and Harbor runs its **own** instances.
3. **Loopback only.** Every published port and service UI binds `127.0.0.1`,
   never `0.0.0.0`. No LAN exposure, ever.
4. **Code stays on the host.** Containers mount **only their own data volumes** —
   never project source. PHP reads code natively.
5. **The manifest is the source of truth.** `projects/<name>/.harbor/harbor.yml`
   drives everything; commands *read* it and *generate* derived files. Never make
   a derived file (compose, vhost, connection.env) authoritative.
6. **Everything reversible.** Every install/link/allocate has a matching
   uninstall/unlink/release. `harbor teardown` must restore the host to its
   pre-Harbor state. If you add something that touches the system, add its undo.
7. **Idempotent.** Every command is safe to re-run. Setup, sync, render, allocate
   must converge, not duplicate.
8. **Surface sudo.** The only allowed sudo touchpoints are the nginx
   LaunchDaemon and `/etc/resolver/test`. Never run `sudo` silently — announce it
   and explain why. Add no new sudo without explicit human sign-off.
9. **No host installs for app dependencies.** External binaries (wkhtmltopdf,
   ghostscript, soffice, ffmpeg…) are containerized via shims (manifest `tools:`),
   never `brew install`ed for a project.
10. **Never commit secrets or runtime state.** `connection.env`, `compose.env`,
    generated compose/vhost/shims, `var/` are gitignored. Only the manifest,
    `import-rules`, `hooks/`, and `scripts/` (per-project scripts, on PATH for
    `run`/`shell`) are committable.

---

## Where the rest of the rules live

The detailed rules — anti-host-pollution specifics, bash/design best practices,
conventions, extension points, the test suite, and the required after-every-change
checklist — are in the **`harbor-contributing` skill**
(`.claude/skills/harbor-contributing/`), which loads on demand. Invoke it before
building or modifying Harbor. Its reference files are authoritative:

| File | Covers |
|---|---|
| `reference-host-pollution.md` | §2 — what Harbor may and may not write outside its repo |
| `reference-bash.md` | §3 — bash 3.2 traps, `set -e`, mktemp, safety, design rules |
| `reference-conventions.md` | §5 — paths, ports, credentials, domains, PHP knobs, Magento multi-store |
| `reference-extending.md` | §6 — adding a command, framework, service, tool, singleton |
| `reference-testing.md` | §6.5 — the pure-bash test suite and its rules |
| `reference-workflow.md` | §4 + §7 — CHANGELOG discipline and the required post-change checklist |

**Every change still ends with the §7 checklist** (`reference-workflow.md`):
`harbor doctor` + `harbor status` green, `.gitignore` checked, `CHANGELOG.md`
updated under `## [Unreleased]`, `CLAUDE.md`/`plan.md`/`README.md` updated if a
convention changed, and a security/performance/usability sanity pass.

---

## 8. Don't

- Don't add files to brew's nginx/php/dnsmasq config dirs.
- Don't bind `0.0.0.0`. Don't mount project source into a container.
- Don't `brew install` an app's binary dependency — containerize it.
- Don't hand-edit Magento `env.php` or blanket-rewrite an app's `.env`.
- Don't require `jq`/`yq`. Don't add a runtime language dependency.
- Don't run destructive ops without a confirm/`--yes`. Don't `sudo` silently.
- Don't let a derived/generated file become the source of truth — the manifest is.
