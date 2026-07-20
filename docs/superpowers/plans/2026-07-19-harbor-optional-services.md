# Optional Services (incl. no database) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a Harbor project's `services:` list mean exactly what it says — any subset of the catalog, including none — so a project can run with no database.

**Architecture:** `services:` becomes authoritative rather than a suggestion that gets backfilled to `mysql`. Selection happens at `init` via a `--services` flag or an interactive picker; every derived artifact (compose, manifest `db:` block, `connection.env`, doctor baseline, `wire`) becomes conditional on the resolved list. Shrinking the list past an existing Docker volume is confirm-gated. Phase 2 adds `harbor services` to change the list after init.

**Tech Stack:** bash (macOS system bash 3.2), awk, Harbor's own `test/` harness. No new runtime dependencies.

**Spec:** `docs/superpowers/specs/2026-07-19-harbor-optional-services-design.md`

## Global Constraints

Copied verbatim from CLAUDE.md — these apply to *every* task below:

- Target **macOS system bash 3.2**. No associative arrays (`declare -A`), no `flock`, no `mapfile`/`readarray`, no `${var^^}`.
- Every script starts `set -euo pipefail`; source `lib/common.sh` for logging (`log`/`ok`/`warn`/`die`/`step`), `render`, `config_get`.
- **Never end a function or loop body with `[ cond ] && {…}`** — when the guard is false it becomes the return value and a plain caller dies silently under `set -e`. Use `if [ cond ]; then …; fi`.
- `shellcheck`-clean; quote **all** expansions.
- Manifest **nesting must use flow style** (`{…}`/`[…]`) — the parser does not do block sequences/maps.
- Destructive ops confirm via `confirm()`, bypassed by **`HARBOR_YES=1` only**. **There is no `--yes` flag** except on `harbor update` — do not document one.
- Report usage errors with **`usage_die <topic> "<text>"`**, never a bare `die "usage: …"`.
- Tests are pure logic only — **never touch the host**: no Docker, launchd, nginx, certs. Use `mktemp -d` and override globals inside a subshell.
- Templates, not heredocs, for emitted **config files**. Terminal text (help topics, usage) stays a heredoc.

**Commit policy for this plan:** tasks end at a **verified, staged checkpoint** — run `git add`, do **not** run `git commit`. The repo owner makes all commits.

---

## Prior Art (read before Task 1)

`_materialize_services` (`lib/init.sh:76-94`) **already performs an in-place single-line rewrite of the `services:` line** using awk, preserving the rest of the manifest:

```bash
  awk -v svc="services: { $body }" '
    /^services:/ { print svc; next }
    /^db:/       { sub(/,[[:space:]]*image:[[:space:]]*[^},[:space:]]*/, ""); print; next }
    { print }
  ' "$mf" > "$tmp" && mv "$tmp" "$mf"
```

Task 1 generalizes this proven pattern into a reusable helper rather than inventing new machinery. The spec's claim that "no manifest write path exists" is true of a *named helper* but understates what is already working here.

## File Structure

| File | Responsibility | Tasks |
|---|---|---|
| `lib/manifest.sh` | add `manifest_set_line` — the only place a manifest line is rewritten | 1 |
| `lib/init.sh` | catalog, resolution, selection (flag + picker), conditional render | 2,3,4,5,6 |
| `lib/compose.sh` | service-less lifecycle no-ops | 5 |
| `lib/services.sh` **(new)** | shrink-confirm gate (phase 1) + `cmd_services` (phase 2) | 7,10 |
| `lib/db.sh`, `lib/doctor.sh`, `lib/ergo.sh`, `lib/wire.sh` | DB-optional behavior | 8 |
| `templates/manifest/harbor.yml.tmpl` | conditional `db:` block | 6 |
| `test/test_manifest.sh`, `test/test_services.sh` **(new)** | pure-logic tests | 1,2,3,4,7 |
| `lib/help.sh`, `lib/completion.sh`, `README.md`, `plan.md`, `CHANGELOG.md`, `ai/skills/harbor/` | docs + discoverability | 9,10 |

A new `lib/services.sh` keeps selection/confirm logic out of the already-large `lib/init.sh` (400+ lines) and gives phase 2 an obvious home.

---

# PHASE 1 — Optional services

### Task 1: `manifest_set_line` — the manifest write helper

**Files:**
- Modify: `lib/manifest.sh` (append after `manifest_has`, ~line 165)
- Modify: `lib/init.sh:76-94` (`_materialize_services` uses the new helper)
- Test: `test/test_manifest.sh`

**Interfaces:**
- Produces: `manifest_set_line <file> <key> <value>` — replaces the line whose top-level key is `<key>` with `<key>: <value>`; appends `<key>: <value>` if no such line exists. Returns 0. Every other byte of the file is unchanged.

- [ ] **Step 1: Write the failing tests**

Append to `test/test_manifest.sh`, before the final `report`:

```bash
# --- manifest_set_line: in-place single-line rewrite ---------------------------
sfx="$(mktemp)"
cat > "$sfx" <<'YAML'
# a comment that must survive
framework: laravel
services: { mysql: "mysql:8.0" }
php: "8.3"   # trailing comment
YAML

manifest_set_line "$sfx" services '{ opensearch: "os:1" }'
assert_eq "set_line: replaces the key" \
  'services: { opensearch: "os:1" }' "$(grep '^services:' "$sfx")"
assert_eq "set_line: leading comment survives" \
  '# a comment that must survive' "$(sed -n 1p "$sfx")"
assert_eq "set_line: unrelated trailing comment survives" \
  'php: "8.3"   # trailing comment' "$(grep '^php:' "$sfx")"
assert_eq "set_line: line count unchanged" 4 "$(wc -l < "$sfx" | tr -d ' ')"

manifest_set_line "$sfx" node 20
assert_eq "set_line: appends an absent key" 'node: 20' "$(grep '^node:' "$sfx")"

# a key that appears only as a nested map key must NOT be treated as top-level
cat > "$sfx" <<'YAML'
multistore: { mode: domain, stores: { de: de.shop.test } }
YAML
manifest_set_line "$sfx" mode block
assert_eq "set_line: does not match a key inside a flow map" \
  'multistore: { mode: domain, stores: { de: de.shop.test } }' "$(sed -n 1p "$sfx")"
assert_eq "set_line: appends instead" 'mode: block' "$(grep '^mode:' "$sfx")"
rm -f "$sfx"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./test/run.sh manifest`
Expected: FAIL — `manifest_set_line: command not found`

- [ ] **Step 3: Implement the helper**

Append to `lib/manifest.sh` after `manifest_has`:

```bash
# manifest_set_line <file> <key> <value> — set a TOP-LEVEL key's line to
# "<key>: <value>", replacing it in place or appending if absent. Every other
# byte of the file is preserved, including comments — the manifest is
# hand-editable and must survive a machine write.
#
# One line is enough because CLAUDE.md requires flow style for nesting, so a
# value like `services: { … }` never spans lines. `^key:` anchors to column 0,
# so a key nested inside a flow map is never matched.
manifest_set_line() {
  local file="$1" key="$2" value="$3" tmp
  tmp="$file.tmp.$$"
  # Literal prefix match — NO regex, so a key containing metacharacters is
  # matched as text. index()==1 anchors to column 0, which is what makes this a
  # TOP-LEVEL key match: a key nested inside a flow map never starts its line.
  if awk -v k="$key:" 'index($0, k) == 1 { found = 1 } END { exit !found }' "$file"; then
    awk -v k="$key:" -v line="$key: $value" \
      'index($0, k) == 1 { print line; next } { print }' "$file" > "$tmp" && mv "$tmp" "$file"
  else
    # a hand-edited manifest may lack a trailing newline; appending blind would
    # glue the new key onto the last line
    if [ -s "$file" ] && [ -n "$(tail -c1 "$file")" ]; then printf '\n' >> "$file"; fi
    printf '%s: %s\n' "$key" "$value" >> "$file"
  fi
}
```

**Amended twice after review — do not reintroduce either earlier form.**

The first version built a regex from an unescaped `$key`. The second escaped it for `grep` (BRE) but still failed in `awk` (ERE), where `+ ? | ( ) { }` remain metacharacters: `grep` matched, so the replace branch was taken, then `awk` did not match, so the file was rewritten unchanged — **a silent dropped write**. The fix is to use no regex at all. If you find yourself escaping a key for a pattern match here, you are repeating a bug that has already been made twice.

- [ ] **Step 4: Run tests to verify they pass**

Run: `./test/run.sh manifest`
Expected: PASS, all assertions green.

- [ ] **Step 5: Refactor `_materialize_services` onto the helper**

In `lib/init.sh`, replace the awk block at lines 86-92 with:

```bash
  manifest_set_line "$mf" services "{ $body }"
  # drop the now-redundant db.image field left by the legacy format
  tmp="$mf.tmp.$$"
  awk '/^db:/ { sub(/,[[:space:]]*image:[[:space:]]*[^},[:space:]]*/, ""); print; next } { print }' \
    "$mf" > "$tmp" && mv "$tmp" "$mf"
```

- [ ] **Step 6: Verify nothing regressed and stage**

Run: `./test/run.sh && shellcheck lib/manifest.sh lib/init.sh`
Expected: all tests pass, shellcheck silent.

```bash
git add lib/manifest.sh lib/init.sh test/test_manifest.sh
```

Do **not** commit.

---

### Task 2: Catalog + absent-vs-empty resolution

**Files:**
- Create: `lib/services.sh`
- Modify: `bin/harbor` (source the new lib)
- Modify: `lib/init.sh:16-21` (`_project_services`)
- Test: `test/test_services.sh` (new)

**Interfaces:**
- Produces: `services_catalog` → space-separated service names from `templates/compose/services/*.yml.tmpl`.
- Produces: `services_validate <name>...` → dies listing the catalog on an unknown name.
- Changes: `_project_services <name> <framework>` → manifest value verbatim when the `services:` key is **present** (including empty); framework default only when **absent**.

- [ ] **Step 1: Write the failing tests**

Create `test/test_services.sh`:

```bash
#!/usr/bin/env bash
# test_services.sh — service catalog, selection parsing, resolution semantics.
set -uo pipefail
. "$HARBOR_TEST_DIR/lib.sh"
harbor_load common manifest init services

# --- catalog -------------------------------------------------------------------
cat="$(services_catalog)"
case " $cat " in *" mysql "*) pass "catalog: includes mysql" ;;
  *) fail "catalog: includes mysql" "mysql present" "$cat" ;; esac
case " $cat " in *" opensearch "*) pass "catalog: includes opensearch" ;;
  *) fail "catalog: includes opensearch" "opensearch present" "$cat" ;; esac

assert_ok   "validate: known service" services_validate mysql opensearch
assert_fail "validate: unknown service" services_validate mysql nope

# --- resolution: absent vs empty vs written ------------------------------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkproj() {  # mkproj <name> <services-line-or-empty>
  mkdir -p "$tmp/projects/$1/.harbor"
  { printf 'framework: laravel\nphp: "8.3"\n'
    if [ -n "${2-}" ]; then printf '%s\n' "$2"; fi
  } > "$tmp/projects/$1/.harbor/harbor.yml"
}
mkproj absent ""
mkproj empty 'services: {}'
mkproj written 'services: { opensearch: "os:1" }'
mkproj legacy 'services: [mysql, rabbitmq]'

# NOTE: a brace group, NOT a ( … ) subshell. pass/fail mutate the PASS/FAIL
# counters; inside a subshell those mutations are discarded, so every assertion
# in here would report green even against a deliberately broken resolver. This
# was caught in Task 2 — do not "tidy" it back into a subshell.
{ export HARBOR_PROJECTS="$tmp/projects"
  assert_eq "resolve: absent key -> framework default" \
    "mysql" "$(_project_services absent laravel)"
  assert_eq "resolve: empty map -> no services" \
    "" "$(_project_services empty laravel)"
  assert_eq "resolve: written map -> as written" \
    "opensearch" "$(_project_services written laravel)"
  assert_eq "resolve: legacy list -> as written" \
    "mysql rabbitmq" "$(_project_services legacy laravel)"
  assert_eq "resolve: absent key, magento -> magento default" \
    "mysql opensearch rabbitmq" "$(_project_services absent magento)"; }

report
```

The projects-dir global is `HARBOR_PROJECTS` (`lib/common.sh:14`), consumed by `project_dir`/`project_harbor_dir` (`:126-127`). Overriding it inside the subshell is what keeps the test off the host.

- [ ] **Step 2: Run to verify it fails**

Run: `./test/run.sh services`
Expected: FAIL — `services_catalog: command not found`

- [ ] **Step 3: Create `lib/services.sh`**

```bash
#!/usr/bin/env bash
# services.sh — the service catalog and a project's service selection.
#
# The catalog is DERIVED from templates/compose/services/*.yml.tmpl, so adding a
# service template makes it selectable with no second list to maintain.

# services_catalog — space-separated names of every bundled service.
services_catalog() {
  local f out="" n
  for f in "$HARBOR_TEMPLATES"/compose/services/*.yml.tmpl; do
    [ -f "$f" ] || continue
    n="$(basename "$f" .yml.tmpl)"
    if [ -z "$out" ]; then out="$n"; else out="$out $n"; fi
  done
  printf '%s' "$out"
}

# services_validate <name>... — die with a fix hint on an unknown service.
services_validate() {
  local svc cat; cat="$(services_catalog)"
  for svc in "$@"; do
    case " $cat " in
      *" $svc "*) ;;
      *) die "unknown service '$svc' → one of: $cat" ;;
    esac
  done
}
```

- [ ] **Step 4: Source it and fix resolution**

In `bin/harbor`, add `services` to the list of sourced libs (match the existing `. "$HARBOR_LIB/…"` pattern; place it after `init`).

Replace `_project_services` in `lib/init.sh:16-21` with:

```bash
# the stack's services (space-separated). The manifest is authoritative when the
# `services:` key is PRESENT — including when it is empty, which means "no
# containers". Only an ABSENT key falls back to the framework default, so
# manifests written before `services:` existed keep working.
_project_services() {
  local name="$1" framework="$2" mf
  mf="$(manifest_path "$name")"
  if [ -f "$mf" ] && manifest_has "$mf" services; then
    manifest_map_keys "$mf" services
    return 0
  fi
  _init_services "$framework" | tr ',' ' '
}
```

Why this works: `manifest_get` returns the literal `{}` for an empty flow map and empty string for an absent key, so `manifest_has` already distinguishes them (`lib/manifest.sh:165`). No parser change needed.

- [ ] **Step 5: Run tests**

Run: `./test/run.sh`
Expected: PASS including the new `services` file.

- [ ] **Step 6: Stage**

```bash
git add lib/services.sh lib/init.sh bin/harbor test/test_services.sh
```

---

### Task 3: `--services` flag on `init`

**Files:**
- Modify: `lib/services.sh` (add `services_parse_arg`)
- Modify: `lib/init.sh:343-383` (`cmd_init`)
- Test: `test/test_services.sh`

**Interfaces:**
- Produces: `services_parse_arg <csv>` → normalized space-separated list; empty string for `""`; validates each name.

- [ ] **Step 1: Write the failing tests**

Insert into `test/test_services.sh` before `report`:

```bash
# --- --services parsing --------------------------------------------------------
assert_eq "parse: csv"           "mysql opensearch" "$(services_parse_arg 'mysql,opensearch')"
assert_eq "parse: spaces + csv"  "mysql opensearch" "$(services_parse_arg 'mysql, opensearch')"
assert_eq "parse: empty = none"  ""                 "$(services_parse_arg '')"
assert_eq "parse: literal none"  ""                 "$(services_parse_arg 'none')"
assert_eq "parse: dedupes"       "mysql"            "$(services_parse_arg 'mysql,mysql')"
assert_fail "parse: rejects unknown" services_parse_arg 'mysql,bogus'
```

- [ ] **Step 2: Run to verify it fails**

Run: `./test/run.sh services`
Expected: FAIL — `services_parse_arg: command not found`

- [ ] **Step 3: Implement**

Append to `lib/services.sh`:

```bash
# services_parse_arg <csv> — normalize a --services value to a space-separated
# list. "" and "none" both mean no services. Validates every name.
services_parse_arg() {
  local raw="$1" svc out=""
  case "$raw" in ""|none) printf ''; return 0 ;; esac
  for svc in $(printf '%s' "$raw" | tr ',' ' '); do
    case " $out " in *" $svc "*) continue ;; esac   # dedupe
    if [ -z "$out" ]; then out="$svc"; else out="$out $svc"; fi
  done
  # shellcheck disable=SC2086  # deliberate word-split of the validated list
  services_validate $out
  printf '%s' "$out"
}
```

- [ ] **Step 4: Wire the flag into `cmd_init`**

In `lib/init.sh`, add to the option loop (after the `--existing` arm):

```bash
      --services)
        [ "$#" -ge 2 ] || usage_die init "--services needs a value (use --services \"\" for none)"
        svcopt="$2"; svcopt_set=1; shift 2 ;;
```

Declare alongside the other locals: `local svcopt="" svcopt_set=0`.

**Why the arity guard** (this differs from the neighbouring `--php`/`--multistore` arms, which use the bare `${2-}`; do not "make it consistent" by removing it): with `shift 2` and no guard, `harbor init foo --services` — flag typed, value forgotten — behaves exactly like `--services ""` and silently provisions a project with **no database**. For `--php` a missing value is a loud failure later; here it is a silent wrong outcome. `shift 2` on a single remaining argument also returns nonzero, which `set -e` turns into a bare exit with no message.

Then replace the `svcnames=` assignment at `lib/init.sh:378` with:

```bash
  local svcnames
  if [ "$svcopt_set" = 1 ]; then
    svcnames="$(services_parse_arg "$svcopt")"
  else
    svcnames="$(services_select "$name" "$framework")"
  fi
```

`services_select` arrives in Task 4. To keep this task independently testable, stub it for now at the end of `lib/services.sh`:

```bash
# services_select <name> <framework> — replaced by the picker in Task 4.
services_select() { _init_services "$2" | tr -s ', ' ' '; }
```

Note `tr -s ', ' ' '`, matching the fix Task 2 made to `_project_services`. A plain `tr ',' ' '` leaves double spaces (the defaults are written `"mysql, opensearch, rabbitmq"`), which word-splitting hides at most call sites and exact-match assertions do not.

- [ ] **Step 4b: Document the flag in the `init` help topic (same commit)**

CLAUDE.md §6 is explicit: *"if you add a flag, add it to the command's help topic in the same commit"* and *"every flag the command parses must appear there"* — the topic is the flag's contract. Task 9 owns the rest of the docs, but this one line ships with the flag. Add to the `init)` topic in `lib/help.sh`:

```
  --services "a,b"  Which backing services to run. Omit to be asked (or to get
                    the framework default when not on a terminal).
                    --services ""  or  --services none  -> no containers at all.
                    Catalog: mysql, opensearch, rabbitmq, meilisearch, elasticsearch
```

- [ ] **Step 5: Run tests and a real init**

Run: `./test/run.sh && shellcheck lib/services.sh lib/init.sh lib/help.sh`

Then a real run (creates a throwaway project):

```bash
./bin/harbor init tmpsvc plain --services "mysql,opensearch"
grep '^services:' projects/tmpsvc/.harbor/harbor.yml
```
Expected: `services: { mysql: "mysql:8.0", opensearch: "opensearchproject/opensearch:2.19.0" }`

```bash
./bin/harbor init tmpnone plain --services ""
grep '^services:' projects/tmpnone/.harbor/harbor.yml
```
Expected: `services: {  }` — and `harbor init` must **not** die. If it dies at `init_render_compose` with "no services resolved", that is expected until Task 5; note it and continue.

Clean up: `HARBOR_YES=1 ./bin/harbor destroy tmpsvc --files; HARBOR_YES=1 ./bin/harbor destroy tmpnone --files`

- [ ] **Step 6: Stage**

```bash
git add lib/services.sh lib/init.sh test/test_services.sh
```

---

### Task 4: The interactive picker

**Files:**
- Modify: `lib/services.sh` (`services_pick_parse`, `services_select`)
- Test: `test/test_services.sh`

**Interfaces:**
- Produces: `services_pick_parse <input> <catalog> <defaults>` → resolved list, or the string `__INVALID__` on bad input. **Pure — no TTY, no I/O.**
- Produces: `services_select <name> <framework>` → prompts when interactive, else the default. Replaces the Task 3 stub.

- [ ] **Step 1: Write the failing tests**

Insert into `test/test_services.sh` before `report`:

```bash
# --- picker parsing (pure; no TTY) --------------------------------------------
CAT="mysql opensearch rabbitmq meilisearch elasticsearch"
DEF="mysql"
assert_eq "pick: empty input -> defaults"  "mysql"            "$(services_pick_parse ''       "$CAT" "$DEF")"
assert_eq "pick: 'none' -> no services"    ""                 "$(services_pick_parse 'none'   "$CAT" "$DEF")"
assert_eq "pick: numbers"                  "mysql rabbitmq"   "$(services_pick_parse '1 3'    "$CAT" "$DEF")"
assert_eq "pick: commas accepted"          "mysql rabbitmq"   "$(services_pick_parse '1,3'    "$CAT" "$DEF")"
assert_eq "pick: order follows catalog"    "mysql rabbitmq"   "$(services_pick_parse '3 1'    "$CAT" "$DEF")"
assert_eq "pick: dedupes"                  "mysql"            "$(services_pick_parse '1 1'    "$CAT" "$DEF")"
assert_eq "pick: out of range invalid"     "__INVALID__"      "$(services_pick_parse '9'      "$CAT" "$DEF")"
assert_eq "pick: zero invalid"             "__INVALID__"      "$(services_pick_parse '0'      "$CAT" "$DEF")"
assert_eq "pick: garbage invalid"          "__INVALID__"      "$(services_pick_parse 'wat'    "$CAT" "$DEF")"
assert_eq "pick: whitespace-only -> defaults" "mysql"         "$(services_pick_parse '   '    "$CAT" "$DEF")"
assert_eq "pick: leading/trailing spaces"  "mysql rabbitmq"   "$(services_pick_parse '  1 3 ' "$CAT" "$DEF")"
assert_eq "pick: inner spacing preserved as separate tokens" \
                                           "mysql rabbitmq"   "$(services_pick_parse '1   3' "$CAT" "$DEF")"
```

The whitespace-only case is not a tidiness test: without the trim, a user who typed a space before Enter gets **no services** instead of the defaults. The "inner spacing" case guards the obvious wrong fix for it — stripping all whitespace would turn `1 3` into the single token `13` (out of range, `__INVALID__`).

- [ ] **Step 2: Run to verify it fails**

Run: `./test/run.sh services`
Expected: FAIL — `services_pick_parse: command not found`

- [ ] **Step 3: Implement the pure parser**

Append to `lib/services.sh`:

```bash
# services_pick_parse <input> <catalog> <defaults> — pure picker-input parser.
# "" -> defaults, "none" -> empty, otherwise 1-based indexes into <catalog>
# (space- or comma-separated). Prints __INVALID__ on anything else, so the
# caller can re-prompt. Output order follows the catalog, not the input.
services_pick_parse() {
  local input="$1" catalog="$2" defaults="$3" tok i n svc out=""
  # Normalize first: commas -> spaces, runs of whitespace squeezed, ends trimmed.
  # This must NOT delete inner whitespace ("1 3" is two tokens, not "13").
  #
  # The trim matters for correctness, not tidiness: a bare Enter and a
  # space-then-Enter must both mean "defaults". Without it, whitespace-only
  # input falls through to the index loop, matches nothing, and returns "" —
  # silently choosing NO SERVICES from what the user experienced as pressing
  # Enter. Same failure shape as a bare `--services` with no value.
  input="$(printf '%s' "$input" | tr ',' ' ' | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')"
  case "$input" in
    "")     printf '%s' "$defaults"; return 0 ;;
    none)   printf ''; return 0 ;;
  esac
  # collect chosen indexes, validating each token is a digit in range
  local chosen=" "
  n=0; for svc in $catalog; do n=$((n + 1)); done
  for tok in $input; do          # already comma-free and squeezed
    case "$tok" in
      ''|*[!0-9]*) printf '__INVALID__'; return 0 ;;
    esac
    if [ "$tok" -lt 1 ] || [ "$tok" -gt "$n" ]; then printf '__INVALID__'; return 0; fi
    chosen="$chosen$tok "
  done
  i=0
  for svc in $catalog; do
    i=$((i + 1))
    case "$chosen" in
      *" $i "*) if [ -z "$out" ]; then out="$svc"; else out="$out $svc"; fi ;;
    esac
  done
  printf '%s' "$out"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./test/run.sh services`
Expected: PASS.

- [ ] **Step 5: Implement the interactive wrapper**

Replace the Task 3 `services_select` stub in `lib/services.sh`:

```bash
# services_select <name> <framework> — the resolved service list for a new
# project. Prompts only when Harbor is genuinely interactive; a non-TTY caller
# (scripts, CI) and HARBOR_YES=1 both get the framework default silently, so no
# existing scripted `harbor init` changes behavior.
services_select() {
  local name="$1" framework="$2" catalog defaults reply parsed i svc mark
  catalog="$(services_catalog)"
  defaults="$(_init_services "$framework" | tr -s ', ' ' ')"
  if [ ! -t 0 ] || [ "${HARBOR_YES:-0}" = "1" ]; then
    printf '%s' "$defaults"; return 0
  fi
  printf '\nServices for %s  (framework: %s)\n' "'$name'" "$framework" >&2
  i=0
  for svc in $catalog; do
    i=$((i + 1)); mark=""
    case " $defaults " in *" $svc "*) mark="  *default" ;; esac
    printf '  %d) %-14s%s\n' "$i" "$svc" "$mark" >&2
  done
  while :; do
    printf 'Select [Enter = defaults · numbers e.g. "1 3" · "none"]: ' >&2
    read -r reply || { printf '%s' "$defaults"; return 0; }
    parsed="$(services_pick_parse "$reply" "$catalog" "$defaults")"
    if [ "$parsed" != "__INVALID__" ]; then printf '%s' "$parsed"; return 0; fi
    warn "not a valid selection: $reply"
  done
}
```

Note the prompt writes to **stderr** — stdout is the function's return value.

- [ ] **Step 6: Verify interactively and non-interactively, then stage**

```bash
./bin/harbor init tmppick plain < /dev/null   # non-TTY -> no prompt, default
grep '^services:' projects/tmppick/.harbor/harbor.yml
```
Expected: contains `mysql`, no prompt shown.

Then run `./bin/harbor init tmppick2 plain` in a real terminal, choose `none`, and confirm the manifest gets `services: {  }`.

Clean up both, then:

```bash
git add lib/services.sh test/test_services.sh
```

---

### Task 5: Service-less compose + lifecycle no-ops

**Files:**
- Modify: `lib/init.sh:98-132` (`init_render_compose`)
- Modify: `lib/compose.sh` (`cmd_up`, `cmd_down`, `cmd_restart`, `cmd_logs`)

**Interfaces:**
- Consumes: `_project_services` (Task 2).
- Produces: `project_has_stack <name>` → 0 when a compose file exists.

- [ ] **Step 1: Make `init_render_compose` handle the empty list**

Replace `lib/init.sh:102-103` with:

```bash
  # shellcheck disable=SC2046  # word-split the service list into positionals
  set -- $(_project_services "$name" "$framework")
  local cf; cf="$(project_harbor_dir "$name")/docker-compose.yml"
  if [ "$#" -eq 0 ]; then
    # No services is a valid choice, not an error. Emit no compose file at all
    # rather than one with a dangling `services:` key (which docker rejects).
    #
    # Stop the stack BEFORE deleting the file: the compose file is the only
    # handle Harbor (and docker compose) has on those containers. Delete it
    # while they're running and they keep running, unmanageable by `harbor
    # down`/`destroy` — the user's app still talks to a database Harbor no
    # longer knows about. Down-then-delete keeps the "everything reversible"
    # rule (CLAUDE.md §1.6) true. `down` (not `down -v`) so volumes survive:
    # dropping data is `harbor destroy`'s job, never render's.
    if [ -f "$cf" ]; then
      log "no services for '$name' — stopping its stack before removing the compose file"
      if ! project_compose "$name" down; then
        # Keep the compose file: it is the only handle on a stack that may still
        # be running. Deleting it here would recreate the orphan this branch
        # exists to prevent, and leave the project unreachable by every command.
        warn "could not stop '$name' — keeping its compose file so you can retry"
        step "harbor down $name   # then re-run: harbor render $name"
        return 1
      fi
    fi
    rm -f "$cf"
    return 0
  fi
```

**Why the down step exists** (added after a pre-dispatch audit — do not drop it as redundant): without it, `harbor render` on a project whose `services:` was emptied silently orphans running containers. They survive, hold their ports, and no Harbor command can reach them again because every one of them resolves through the compose file that was just deleted.

Then change the final line (was `lib/init.sh:131`) from `> "$(project_harbor_dir "$name")/docker-compose.yml"` to `> "$cf"`.

- [ ] **Step 2: Verify a service-less init now succeeds**

```bash
./bin/harbor init tmpnone plain --services ""
ls projects/tmpnone/.harbor/docker-compose.yml
```
Expected: `harbor init` exits 0; `ls` reports **No such file or directory**.

- [ ] **Step 3: Add the stack guard**

In `lib/compose.sh`, after `project_compose_file` (line 29):

```bash
# does this project have a container stack at all? A project with `services: {}`
# has no compose file — that is a valid state, not an error.
project_has_stack() { [ -f "$(project_compose_file "$1")" ]; }
```

- [ ] **Step 4: Make the lifecycle commands no-op**

**Note on `cmd_restart`:** it now has two branches — a bare `harbor restart` restarts Harbor's own services (`platform_restart`), and `harbor restart <name>` restarts one project's containers. The guard belongs in the **project branch only**, after the name is known. Do not put it before the platform dispatch, or `harbor restart` with no arguments would start checking for a compose file that has nothing to do with it.

Add as the first line after `require_name` in `cmd_up`, `cmd_down`, and the project branch of `cmd_restart`:

```bash
  if ! project_has_stack "$name"; then
    step "nothing to start for '$name' (no services)"; return 0
  fi
```

Use the matching verb per command — `nothing to stop`, `nothing to restart`. In `cmd_logs`'s project branch use `no container logs for '$name' (no services)`.

Rationale to preserve in the comment: **lifecycle commands run in bulk across every project degrade to a no-op; commands that are a direct request for a specific missing thing refuse** (Task 8).

- [ ] **Step 5: Verify the no-ops and stage**

```bash
./bin/harbor up tmpnone   ; echo "exit=$?"
./bin/harbor down tmpnone ; echo "exit=$?"
```
Expected: both print the `nothing to …` step line and `exit=0`.

```bash
./test/run.sh && shellcheck lib/init.sh lib/compose.sh
git add lib/init.sh lib/compose.sh
```

---

### Task 6: Conditional derived artifacts

**Files:**
- Modify: `templates/manifest/harbor.yml.tmpl:7`
- Modify: `lib/init.sh:343-383` (`cmd_init` — feed `DB_BLOCK`)
- Modify: `lib/init.sh:153-194` (`init_write_connection`)

**Interfaces:**
- Consumes: `_project_services` (Task 2).
- Produces: `project_has_service <name> <svc>` → 0 when the project's resolved list contains `<svc>`.

- [ ] **Step 1: Add the predicate**

Append to `lib/services.sh`:

```bash
# project_has_service <name> <svc> — is <svc> in this project's resolved list?
# Convenience for one-off checks (doctor, wire, db). Callers that test several
# services in a row should resolve the list ONCE and `case` against it instead —
# see init_write_connection — since each call here re-parses the manifest.
project_has_service() {
  local name="$1" svc="$2" framework
  framework="$(manifest_get "$(manifest_path "$name")" framework "")"
  case " $(_project_services "$name" "$framework") " in
    *" $svc "*) return 0 ;;
    *) return 1 ;;
  esac
}
```

**Note for Step 3:** `init_write_connection` checks five services in a row. Calling `project_has_service` five times re-parses the manifest ten times (each call does a `manifest_get` for the framework plus `_project_services`' own `manifest_has` + `manifest_map_keys`). Resolve once at the top of the function instead:

```bash
  local framework svcs
  framework="$(manifest_get "$(manifest_path "$name")" framework "")"
  svcs=" $(_project_services "$name" "$framework") "     # padded for `case` matching
```

then guard each block with `case "$svcs" in *" mysql "*) … ;; esac`. Same behavior, one parse. CLAUDE.md's performance rule is explicit about no repeated per-run work that can be done once.

- [ ] **Step 2: Make the manifest `db:` block conditional**

In `templates/manifest/harbor.yml.tmpl`, replace line 7 (`db: { name: …, user: …, password: … }`) with:

```
{{DB_BLOCK}}
```

In `cmd_init`, replace the `DB_NAME="$ident" DB_USER="$ident" DB_PASS="$ident" \` line in the manifest `render` call with:

```bash
  DB_BLOCK="$(case " $svcnames " in
                (*" mysql "*) printf 'db: { name: %s, user: %s, password: %s }' "$ident" "$ident" "$ident" ;;
              esac)" \
```

**Note the leading `(` on the pattern — it is required, not style.** A `case` used as an *expression* inside `$(…)` is a hard syntax error on macOS system bash 3.2 without it. Worse than an error: bash also assigns garbage, so `DB_BLOCK` becomes the literal text `printf 'db: …' ;;` and every new manifest is corrupted. Verified on bash 3.2.57:

```
$ X="$(case "$s" in *" mysql "*) printf 'yes' ;; esac)"
bash: command substitution: syntax error near unexpected token `newline'
$ echo "[$X]"
[ printf 'yes' ;;          # <- garbage, not an empty string
```

`shellcheck` does not catch this. Test any new `$(case …)` with a real `bash <script>` run. A `case` used as a plain statement is unaffected. Now recorded in CLAUDE.md §3.

A DB-less project gets an empty line there rather than credentials for a database that does not exist.

- [ ] **Step 3: Make `connection.env` / `.txt` conditional**

Rewrite `init_write_connection` so each service's vars are appended only when selected. Keep the always-present block (DB-independent) as a heredoc, then append per service:

```bash
init_write_connection() {
  local name="$1" hdir; hdir="$(project_harbor_dir "$name")"
  ports_load "$name"
  local ident; ident="$(db_ident "$name")"
  local root; root="$(config_get MYSQL_ROOT_PASSWORD root)"
  local ce="$hdir/connection.env" ct="$hdir/connection.txt"
  # Resolve the service list ONCE — five project_has_service calls would re-parse
  # the manifest ten times. Padded with spaces so `case` can match whole words.
  local framework svcs
  framework="$(manifest_get "$(manifest_path "$name")" framework "")"
  svcs=" $(_project_services "$name" "$framework") "

  # Redis and mail are shared, always-on Harbor services — never per-project.
  cat > "$ce" <<EOF
REDIS_HOST=127.0.0.1
REDIS_PORT=6379
REDIS_DB=$REDIS_DB_CACHE
REDIS_CACHE_DB=$REDIS_DB_CACHE
REDIS_PAGE_DB=$REDIS_DB_PAGE
REDIS_SESSION_DB=$REDIS_DB_SESSION
REDIS_PREFIX=${ident}_
MAIL_HOST=127.0.0.1
MAIL_PORT=1025
EOF
  cat > "$ct" <<EOF
Harbor connection info for "$name"
  URL        https://$name.$HARBOR_TLD
  Redis      127.0.0.1:6379  db: $REDIS_DB_CACHE (cache) $REDIS_DB_PAGE (page) $REDIS_DB_SESSION (session)  prefix: ${ident}_
  Mailpit    smtp 127.0.0.1:1025   ui http://localhost:8025
EOF

  case "$svcs" in *" mysql "*)
    cat >> "$ce" <<EOF
DB_HOST=127.0.0.1
DB_PORT=$DB_PORT
DB_DATABASE=$ident
DB_USERNAME=$ident
DB_PASSWORD=$ident
DB_ROOT_PASSWORD=$root
EOF
    printf '  MySQL      127.0.0.1:%s  db/user/pass: %s / %s / %s  (root: %s)\n' \
      "$DB_PORT" "$ident" "$ident" "$ident" "$root" >> "$ct"
  ;; esac
  case "$svcs" in *" opensearch "*)
    printf 'OPENSEARCH_HOST=127.0.0.1\nOPENSEARCH_PORT=%s\n' "$OPENSEARCH_PORT" >> "$ce"
    printf '  OpenSearch 127.0.0.1:%s\n' "$OPENSEARCH_PORT" >> "$ct"
  ;; esac
  case "$svcs" in *" rabbitmq "*)
    printf 'RABBITMQ_HOST=127.0.0.1\nRABBITMQ_PORT=%s\n' "$RABBITMQ_PORT" >> "$ce"
    printf '  RabbitMQ   amqp 127.0.0.1:%s   ui http://localhost:%s\n' \
      "$RABBITMQ_PORT" "$RABBITMQ_UI_PORT" >> "$ct"
  ;; esac
  case "$svcs" in *" meilisearch "*)
    local mkey; mkey="$(config_get MEILI_MASTER_KEY harbor-local-meili-master)"
    printf 'MEILISEARCH_HOST=http://127.0.0.1:%s\nMEILISEARCH_KEY=%s\n' "$MEILI_PORT" "$mkey" >> "$ce"
    printf '  Meilisearch http://127.0.0.1:%s   key: %s\n' "$MEILI_PORT" "$mkey" >> "$ct"
  ;; esac
  case "$svcs" in *" elasticsearch "*)
    printf 'ELASTICSEARCH_HOST=127.0.0.1\nELASTICSEARCH_PORT=%s\n' "$ELASTIC_PORT" >> "$ce"
    printf '  Elasticsearch http://127.0.0.1:%s   (security disabled for local dev)\n' "$ELASTIC_PORT" >> "$ct"
  ;; esac
}
```

This also fixes an existing wart: today every project is written `OPENSEARCH_*`, `RABBITMQ_*`, `MEILISEARCH_*` and `ELASTICSEARCH_*` regardless of which services exist.

- [ ] **Step 4: Verify both shapes and stage**

```bash
./bin/harbor init tmpfull plain --services "mysql,opensearch"
cat projects/tmpfull/.harbor/connection.txt
```
Expected: URL, Redis, Mailpit, MySQL, OpenSearch lines — **no** RabbitMQ/Meili/Elastic lines.

```bash
./bin/harbor init tmpnone2 plain --services ""
cat projects/tmpnone2/.harbor/connection.env
grep -c '^db:' projects/tmpnone2/.harbor/harbor.yml
```
Expected: only `REDIS_*` and `MAIL_*`; `grep -c` prints `0`.

Clean up both projects, then:

```bash
./test/run.sh && shellcheck lib/init.sh lib/services.sh
git add lib/init.sh lib/services.sh templates/manifest/harbor.yml.tmpl
```

---

### Task 7: The shrink-confirm gate

**Files:**
- Modify: `lib/services.sh`
- Modify: `lib/init.sh:137-150` (`cmd_render`)
- Test: `test/test_services.sh`

**Interfaces:**
- Produces: `services_dropped <old-list> <new-list>` → services in old but not new. **Pure.**
- Produces: `services_confirm_shrink <name> <old-list> <new-list>` → 0 to proceed, 1 to abort. Prompts only for dropped services whose Docker volume actually exists.

- [ ] **Step 1: Write the failing tests for the pure part**

Insert into `test/test_services.sh` before `report`:

```bash
# --- shrink detection (pure) ---------------------------------------------------
assert_eq "dropped: none"        ""          "$(services_dropped "mysql opensearch" "mysql opensearch")"
assert_eq "dropped: one"         "opensearch" "$(services_dropped "mysql opensearch" "mysql")"
assert_eq "dropped: all"         "mysql"     "$(services_dropped "mysql" "")"
assert_eq "dropped: growth only" ""          "$(services_dropped "mysql" "mysql opensearch")"
```

- [ ] **Step 2: Run to verify it fails**

Run: `./test/run.sh services`
Expected: FAIL — `services_dropped: command not found`

- [ ] **Step 3: Implement**

Append to `lib/services.sh`:

```bash
# services_dropped <old> <new> — services present in <old> but not <new>.
services_dropped() {
  local old="$1" new="$2" svc out=""
  for svc in $old; do
    case " $new " in
      *" $svc "*) ;;
      *) if [ -z "$out" ]; then out="$svc"; else out="$out $svc"; fi ;;
    esac
  done
  printf '%s' "$out"
}

# _service_volume <name> <svc> — the docker volume a service's data lives in, or
# empty if it has none. Volumes are named and scoped to the compose project
# (`name: harbor-<name>` in templates/compose/header.yml.tmpl).
_service_volume() {
  local name="$1" svc="$2" vol=""
  [ -f "$HARBOR_TEMPLATES/compose/volumes/$svc.yml.tmpl" ] || { printf ''; return 0; }
  vol="$(tr -d ' :' < "$HARBOR_TEMPLATES/compose/volumes/$svc.yml.tmpl" | head -1)"
  printf 'harbor-%s_%s' "$name" "$vol"
}

# services_confirm_shrink <name> <old> <new> — confirm before dropping a service
# whose data volume still exists. Removing a service does NOT delete data: the
# named volume is left in place and re-adding the service reattaches it intact;
# only `harbor destroy` drops volumes. Say so — an alarmist prompt for a
# reversible action trains people to ignore the prompts that aren't.
services_confirm_shrink() {
  local name="$1" old="$2" new="$3" svc vol atrisk="" dockerup=1
  # If we can't reach Docker we can't tell whether data exists. Assume it does
  # and prompt anyway: skipping the prompt because the daemon happens to be down
  # turns a safety gate into a coin flip, and "no prompt appeared" is exactly how
  # a user concludes nothing was at stake.
  docker info >/dev/null 2>&1 || dockerup=0
  for svc in $(services_dropped "$old" "$new"); do
    vol="$(_service_volume "$name" "$svc")"
    [ -n "$vol" ] || continue
    if [ "$dockerup" = 0 ] || docker volume inspect "$vol" >/dev/null 2>&1; then
      atrisk="$atrisk $svc:$vol"
    fi
  done
  [ -n "$atrisk" ] || return 0
  local pair
  for pair in $atrisk; do
    warn "removing ${pair%%:*} from '$name' stops its container and unmounts its data"
    step "the volume ${pair#*:} is KEPT — re-adding ${pair%%:*} reattaches it intact"
    step "only 'harbor destroy $name' drops it"
  done
  confirm "Remove$(for pair in $atrisk; do printf ' %s' "${pair%%:*}"; done) from '$name'?"
}
```

- [ ] **Step 4: Gate `cmd_render`**

In `lib/init.sh`, inside `cmd_render`, after the `framework=` line and before `init_render_compose`.

**Ordering is load-bearing: the gate must come BEFORE `_materialize_services`.** That function rewrites the manifest in place (legacy list form → explicit map, `db.image` stripped), so running it first means a user who answers **n** has already had their file modified while being told *"manifest unchanged"*. A confirmation whose "no" still mutates state is a broken gate. Verified empirically: `_materialize_services` on `services: [mysql, rabbitmq]` rewrites it, while `_project_services` resolves that same manifest to `mysql rabbitmq` **without** materializing and without touching the file — `manifest_map_keys` handles both forms. So the gate has everything it needs first, and `_materialize_services` moves to just before `init_render_compose`.

```bash
  # A hand-edited manifest that drops a service must not silently detach its
  # data. One gate, one place: services rm (phase 2) routes through here too, so
  # a user is never asked twice for one action.
  local newlist oldlist=""
  newlist="$(_project_services "$name" "$framework")"
  if [ -f "$(project_compose_file "$name")" ]; then
    # Only the keys under `services:` — a generated compose also has a top-level
    # `volumes:` block whose entries sit at the SAME two-space indent, so a bare
    # /^  [a-z]+:$/ picks up `dbdata` and reports it as a dropped "service".
    # (Verified against a real generated file: it matched `mysql` AND `dbdata`.)
    oldlist="$(awk '
      /^services:/ { in_s = 1; next }
      /^[a-z]/     { in_s = 0 }
      in_s && /^  [a-z][a-z0-9_-]*:$/ { gsub(/[ :]/, ""); print }
    ' "$(project_compose_file "$name")" | tr '\n' ' ')"
  fi
  services_confirm_shrink "$name" "$oldlist" "$newlist" || { warn "aborted — manifest unchanged"; return 1; }
```

Verify the `oldlist` awk against a real generated compose file before relying on it:
`awk '/^  [a-z]+:$/ { gsub(/[ :]/, ""); print }' projects/<any>/.harbor/docker-compose.yml`
It must print exactly the service names. Adjust the pattern if the generated indentation differs.

- [ ] **Step 5: Verify the gate end-to-end**

```bash
./bin/harbor init tmpdrop plain --services "mysql"
./bin/harbor up tmpdrop            # creates the volume
docker volume ls | grep harbor-tmpdrop
```
Then hand-edit `projects/tmpdrop/.harbor/harbor.yml` to `services: {}` and run `./bin/harbor render tmpdrop`.
Expected: the warn block, then `Remove mysql from 'tmpdrop'? [y/N]`. Answer `n` — expected: `aborted — manifest unchanged`, exit nonzero, compose file still present.
Answer `y` on a second run — expected: compose file removed, `docker volume ls` still shows the volume.

Clean up: `HARBOR_YES=1 ./bin/harbor destroy tmpdrop --files`

- [ ] **Step 6: Stage**

```bash
./test/run.sh && shellcheck lib/services.sh lib/init.sh
git add lib/services.sh lib/init.sh test/test_services.sh
```

---

### Task 8: DB-optional behavior across commands

**Files:**
- Modify: `lib/db.sh:16-18` (`_db_up_check`)
- Modify: `lib/doctor.sh:88-90`
- Modify: `lib/ergo.sh:63,67` (`cmd_ps`)
- Modify: `lib/wire.sh`

**Interfaces:**
- Consumes: `project_has_service` (Task 6).

- [ ] **Step 1: Refuse in `db`/`mysql` with a fix hint**

In `lib/db.sh`, add before the existing `_db_up_check` body:

```bash
# A project with no mysql service isn't "not running" — it has no database at
# all. Say which, and how to get one. (Lifecycle commands no-op for a
# service-less project; a direct request for a missing thing refuses.)
_db_require() {
  local name="$1"
  if ! project_has_service "$name" mysql; then
    err "no database service for '$name'"
    step "add one to $(manifest_path "$name") services:, then:"
    step "harbor render $name && harbor up $name"
    exit 1
  fi
}
```

Call `_db_require "$1"` as the first line of `_db_up_check`, before the `ps -q mysql` probe.

- [ ] **Step 2: Drop `pdo_mysql` from the doctor baseline when there's no DB**

In `lib/doctor.sh`, the variable is `baseline`, set by the `case` at lines 87-91 and consumed by `want="$baseline $(manifest_list "$mf" extensions)"` at line 92. Insert between them:

```bash
  # a project with no database has no business being told it needs pdo_mysql
  if ! project_has_service "$name" mysql; then
    baseline="$(printf '%s' "$baseline" | sed 's/pdo_mysql//; s/  */ /g; s/^ //; s/ $//')"
  fi
```

This filters the built-in baseline only — an explicit `extensions:` entry in the manifest still wins, because the user asked for it by name.

- [ ] **Step 3: Show `db:-` in `harbor ps`**

In `lib/ergo.sh`, where the `db:$DB_PORT` column is built (lines 63/67), replace the value with:

```bash
  local dbcol="db:-"
  if project_has_service "$name" mysql; then dbcol="db:$DB_PORT"; fi
```

and use `$dbcol` in the printf.

- [ ] **Step 4: Skip DB keys in `wire`, refuse for Magento**

In `lib/wire.sh`, `cmd_wire` declares `framework` at line 72 and resolves it at line 80, *after* sourcing `connection.env` at 77-78. Insert the guard after line 80, before the dispatch `case`:

```bash
  local has_db=0
  if project_has_service "$name" mysql; then has_db=1; fi
  if [ "$has_db" = 0 ] && [ "$framework" = magento ]; then
    die "magento requires a database — add mysql to $(manifest_path "$name") services:, then: harbor render $name"
  fi
```

Then pass `$has_db` to each `wire_*` function and guard that function's DB lines with `if [ "$has_db" = 1 ]; then … fi`, leaving Redis and mail unconditional. For the skipped case emit `step "db      skipped (no database service)"`.

**This guard is load-bearing, not cosmetic.** `cmd_wire` does `set -a; . "$conn"` (lines 77-78), so after Task 6 a DB-less project's `connection.env` contains **no `DB_*` variables at all**. Any branch that still interpolated `$DB_DATABASE` would hit an unbound variable under `set -u` and abort `wire` outright. Verify with:

```bash
./bin/harbor wire tmpnodb   # must complete, not die on an unbound DB_ variable
```

Magento already defers config to `harbor install` rather than wiring it (line 84), so the new `die` is about failing early with a useful message instead of letting `setup:install` fail later at `lib/magento.sh:20`.

- [ ] **Step 4b: Guard `lib/magento.sh` — a consumer Task 6 exposed**

Found in Task 6's review. `magento_write_install` (`lib/magento.sh:6-30`) and `magento_reconfigure` (`:37-47`) call `_db_load` (which sources `connection.env`) then unconditionally reference `$DB_PORT`, `$OPENSEARCH_PORT` (`:20-21,46`) and `$RABBITMQ_PORT` (`:23`). Task 6 made those variables conditional, so a Magento project created with, say, `--services "mysql"` now dies with a raw bash **"unbound variable"** under the global `set -euo pipefail` — no fix hint, just a stack-free crash.

Nothing currently stops that combination: `services_validate` checks names against the catalog, not against what a framework needs.

Add a fail-fast check with a fix hint, in the same spirit as the Magento `wire` refusal in Step 4:

```bash
# Magento needs all three; connection.env only carries a service's vars when the
# service is selected, so without this the next line dies on an unbound variable.
magento_require_services() {
  local name="$1" svc missing=""
  for svc in mysql opensearch rabbitmq; do
    if ! project_has_service "$name" "$svc"; then missing="$missing $svc"; fi
  done
  if [ -n "$missing" ]; then
    err "magento needs:$missing"
    step "add them to $(manifest_path "$name") services:, then:"
    step "harbor render $name && harbor up $name"
    exit 1
  fi
}
```

Call it at the top of `magento_write_install` and `magento_reconfigure`. Verify by initializing a Magento project with `--services "mysql"` and confirming `harbor install` reports the missing services instead of crashing.

**Also note (Minor, no change required):** `lib/ergo.sh`'s `cmd_mysql` and `lib/db.sh`'s `_db_mysql`/`_db_mysqldump` reference `$DB_ROOT_PASSWORD` after `_db_load`, but every call site passes through `_db_up_check` first, which now refuses cleanly for a DB-less project before any unset variable is read. Safe today, fragile if anything is ever reordered — leave a comment at `_db_require` saying the ordering is load-bearing.

- [ ] **Step 5: Verify each surface**

```bash
./bin/harbor init tmpnodb laravel --services ""
./bin/harbor mysql tmpnodb        ; echo "exit=$?"   # expect the refusal, exit=1
./bin/harbor db backup tmpnodb    ; echo "exit=$?"   # expect the refusal, exit=1
./bin/harbor doctor tmpnodb       # expect NO "extensions missing: pdo_mysql"
./bin/harbor ps | grep tmpnodb    # expect "db:-"
./bin/harbor wire tmpnodb         # expect redis+mail wired, db skipped
```

Clean up: `HARBOR_YES=1 ./bin/harbor destroy tmpnodb --files`

- [ ] **Step 6: Stage**

```bash
./test/run.sh && shellcheck lib/db.sh lib/doctor.sh lib/ergo.sh lib/wire.sh
git add lib/db.sh lib/doctor.sh lib/ergo.sh lib/wire.sh
```

---

### Task 9: Phase 1 docs

**Files:**
- Modify: `lib/help.sh` (`init`, `new`, `up`, `render`, `db` topics)
- Modify: `README.md`, `plan.md`, `CHANGELOG.md`
- Modify: `ai/skills/harbor/SKILL.md`, `ai/skills/harbor/reference.md`

- [ ] **Step 1: Update the `init` help topic**

CLAUDE.md §6: *every flag the command parses must appear in its help topic.* Add to the `init)` topic (`lib/help.sh:408`):

```
  --services "a,b"  Which backing services to run. Omit to be asked (or to get
                    the framework default when not on a terminal).
                    --services ""  or  --services none  -> no containers at all.
                    Catalog: mysql, opensearch, rabbitmq, meilisearch, elasticsearch
```

- [ ] **Step 2: Update `up`, `render`, `db` topics**

Add to `up)`: *"A project with `services: {}` has no containers; `up` is a no-op for it."*

Add to `render)`, with the `[confirms]` marker on the title line: *"Dropping a service whose data volume exists confirms first. Your data is not deleted — the volume is kept and re-adding the service reattaches it; only `harbor destroy` drops volumes. `HARBOR_YES=1` skips the prompt (there is no `--yes` flag)."*

Add to `db)`: *"Requires a mysql service. A project without one gets a fix hint, not a 'stack not running' error."*

- [ ] **Step 3: Update README + plan**

Add a **Services** section to `README.md` near the projects tables covering the catalog, the picker, `--services`, and the DB-less case. Add `--services` to the `harbor init` row. In `plan.md`, update the CLI surface block to show `harbor init <name> [framework] [--services "a,b"] …`.

- [ ] **Step 4: Update CHANGELOG**

Under `## [Unreleased]`:

```markdown
### Added
- **Optional backing services.** `harbor init` now asks which services a project
  needs (or takes `--services "mysql,opensearch"`), and `services: {}` in the
  manifest means no containers at all — a project can run with no database.

### Changed
- **`harbor render` can now prompt.** Dropping a service whose data volume still
  exists confirms first. Data is not deleted — the volume is kept and re-adding
  the service reattaches it. `HARBOR_YES=1` skips the prompt.
- `harbor up`/`down`/`restart`/`logs` are no-ops for a project with no services,
  rather than errors.

### Fixed
- `connection.env`/`connection.txt` no longer advertise `OPENSEARCH_*`,
  `RABBITMQ_*`, `MEILISEARCH_*` and `ELASTICSEARCH_*` for projects that don't
  run those services.
- `harbor db`/`harbor mysql` on a project with no database now say so, instead of
  reporting a misleading "stack not running".
- `harbor doctor` no longer requires `pdo_mysql` for a project with no database.
```

- [ ] **Step 5: Update the project-facing agent skill**

`ai/skills/harbor/` is copied into every project and force-reseeded by `harbor update`, so it must cover `--services`, the picker, and what a DB-less project can't do (`harbor db`, `harbor mysql`, Magento `wire`/`install`).

- [ ] **Step 6: Verify and stage**

```bash
./test/run.sh            # test_help.sh must stay green
./bin/harbor init --help # confirm --services is documented
git add lib/help.sh README.md plan.md CHANGELOG.md ai/skills/harbor/
```

**Phase 1 is complete and shippable here.** Run the CLAUDE.md §7 checklist — `harbor doctor`, `harbor status`, `./test/run.sh`, `shellcheck` on every touched script, `git status` for unintended files — before starting phase 2.

---

# PHASE 2 — `harbor services`

### Task 10: The `services` command

**Files:**
- Modify: `lib/services.sh` (`cmd_services`)
- Modify: `bin/harbor` (dispatch), `lib/completion.sh` (`_HARBOR_CMDS`), `lib/help.sh` (topic)
- Modify: `README.md`, `plan.md`, `CHANGELOG.md`
- Test: `test/test_services.sh`

**Interfaces:**
- Consumes: `services_catalog`, `services_validate`, `services_parse_arg`, `services_select`, `manifest_set_line`, `_services_map_body`, `cmd_render`.
- Produces: `services_apply <old> <add|rm> <svc>...` → the new list. **Pure.**

- [ ] **Step 1: Write the failing tests**

Insert into `test/test_services.sh` before `report`:

```bash
# --- services add/rm list algebra (pure) ---------------------------------------
assert_eq "apply: add new"        "mysql opensearch" "$(services_apply "mysql" add opensearch)"
assert_eq "apply: add existing"   "mysql"            "$(services_apply "mysql" add mysql)"
assert_eq "apply: rm present"     "mysql"            "$(services_apply "mysql opensearch" rm opensearch)"
assert_eq "apply: rm absent"      "mysql"            "$(services_apply "mysql" rm rabbitmq)"
assert_eq "apply: rm last"        ""                 "$(services_apply "mysql" rm mysql)"
assert_eq "apply: add two"        "mysql a b"        "$(services_apply "mysql" add a b)"
```

The last assertion uses fake names to prove `services_apply` is pure list algebra with no validation of its own — validation happens in `cmd_services` before it is called.

- [ ] **Step 2: Run to verify it fails**

Run: `./test/run.sh services`
Expected: FAIL — `services_apply: command not found`

- [ ] **Step 3: Implement `services_apply`**

Append to `lib/services.sh`:

```bash
# services_apply <old-list> <add|rm> <svc>... — pure list algebra. Adding a
# present service and removing an absent one are both no-ops (idempotence).
services_apply() {
  local old="$1" op="$2"; shift 2
  local svc out=""
  case "$op" in
    add)
      out="$old"
      for svc in "$@"; do
        case " $out " in *" $svc "*) continue ;; esac
        if [ -z "$out" ]; then out="$svc"; else out="$out $svc"; fi
      done ;;
    rm)
      for svc in $old; do
        case " $* " in *" $svc "*) continue ;; esac
        if [ -z "$out" ]; then out="$svc"; else out="$out $svc"; fi
      done ;;
  esac
  printf '%s' "$out"
}
```

- [ ] **Step 4: Implement `cmd_services`**

Append to `lib/services.sh`:

```bash
# harbor services [list|add|rm] <name> [svc...] — inspect or change a project's
# backing services. Writes the manifest, then re-renders. Deliberately does NOT
# run `up`: rendering is idempotent, restarting containers is not, and a user
# may be making several changes in a row.
cmd_services() {
  local sub="${1-}" name svc catalog cur new
  case "$sub" in
    list|add|rm) shift ;;
    "")          usage_die services "harbor services <name> | list|add|rm <name> [svc...]" ;;
    *)           sub="" ;;   # `harbor services <name>` -> the picker
  esac
  require_name "${1-}"; name="$1"; shift || true
  local mf; mf="$(manifest_path "$name")"
  [ -f "$mf" ] || die "not initialized: $name → harbor init $name"
  local framework; framework="$(manifest_get "$mf" framework "")"
  catalog="$(services_catalog)"
  cur="$(_project_services "$name" "$framework")"

  case "$sub" in
    list)
      printf 'Services for %s  (catalog: %s)\n' "'$name'" "$catalog"
      for svc in $catalog; do
        case " $cur " in
          *" $svc "*) printf '  [x] %-14s %s\n' "$svc" "$(_service_image "$name" "$svc")" ;;
          *)          printf '  [ ] %s\n' "$svc" ;;
        esac
      done
      return 0 ;;
    add|rm)
      [ "$#" -gt 0 ] || usage_die services "harbor services $sub $name <svc>..."
      services_validate "$@"
      new="$(services_apply "$cur" "$sub" "$@")" ;;
    *)
      new="$(services_select "$name" "$framework" "$cur")" ;;
  esac

  if [ "$new" = "$cur" ]; then ok "no change: $name services unchanged ($cur)"; return 0; fi

  # Write, then render — and RESTORE the manifest if the render's confirm gate is
  # declined. Without the restore, answering "n" would leave the manifest already
  # rewritten while nothing else was applied: the exact "decline still mutates
  # state" defect fixed in Task 7, reintroduced one layer up. Capture the raw
  # line rather than rebuilding it, so a decline is byte-for-byte a no-op.
  local prev; prev="$(manifest_get "$mf" services "")"
  # shellcheck disable=SC2086  # word-split the resolved service list
  manifest_set_line "$mf" services "{ $(_services_map_body "$name" $new) }"
  if ! cmd_render "$name"; then       # carries the shrink-confirm gate from Task 7
    manifest_set_line "$mf" services "$prev"
    warn "reverted: $name services unchanged"
    return 1
  fi
}
```

**Two corrections applied after a pre-dispatch audit — do not undo either:**

1. **The restore-on-decline above.** `manifest_set_line` writes *before* `cmd_render` prompts, so a declined gate would otherwise leave the manifest changed and everything else untouched. Task 7 fixed precisely this shape inside `cmd_render`; routing through it from a caller that has already written reintroduces it.

2. **The bare-`harbor services <name>` picker must preselect the project's CURRENT services, not the framework default.** `services_select <name> <framework>` derives its defaults from `_init_services "$framework"`. Used as-is here, pressing **Enter** at the picker would silently reset a project that runs `mysql opensearch` back to just `mysql` — dropping a service, tripping the shrink gate, and doing it from the keystroke that means "no change, keep what I have". Give `services_select` an optional third argument for the defaults and pass `"$cur"`:

```bash
services_select() {
  local name="$1" framework="$2" catalog defaults reply parsed i svc mark
  catalog="$(services_catalog)"
  defaults="${3-}"
  if [ -z "$defaults" ]; then defaults="$(_init_services "$framework" | tr -s ', ' ' ')"; fi
  ...
```

`cmd_init` keeps calling it with two arguments and is unaffected; `cmd_services` calls `services_select "$name" "$framework" "$cur"`. Verify the `*default` marker in the menu then reflects the project's current selection.

The shrink confirm is **not** duplicated here — `cmd_render` owns it, so a user is asked exactly once.

- [ ] **Step 5: Wire dispatch, completion, and help**

In `bin/harbor`'s `case`, beside the other project commands:

```bash
    services) cmd_services "$@" ;;
```

In `lib/completion.sh`, add `services` to `_HARBOR_CMDS` (after `render`).

In `lib/help.sh`, add a topic — `test/test_help.sh` fails the build without one:

```bash
  services) cat <<'EOF'
harbor services — inspect or change a project's backing services  [confirms]

Usage: harbor services <name>              pick interactively (current preselected)
       harbor services list <name>
       harbor services add  <name> <svc>...
       harbor services rm   <name> <svc>...

Catalog: mysql · opensearch · rabbitmq · meilisearch · elasticsearch

Adding a service you already have, or removing one you don't, is a no-op.
Changes are written to the manifest and re-rendered; run `harbor up <name>`
afterwards to apply them to running containers.

Removing a service whose data volume exists CONFIRMS first. Your data is not
deleted — the volume is kept and re-adding the service reattaches it intact.
Only `harbor destroy <name>` drops volumes. HARBOR_YES=1 skips the prompt
(there is no --yes flag).

Example:
  harbor services add shop opensearch && harbor up shop

See also: harbor render · harbor init --help · harbor destroy
EOF
  ;;
```

- [ ] **Step 6: Verify end-to-end**

```bash
./bin/harbor init tmpsvc2 plain --services "mysql"
./bin/harbor services list tmpsvc2          # [x] mysql, [ ] others
./bin/harbor services add tmpsvc2 opensearch
grep '^services:' projects/tmpsvc2/.harbor/harbor.yml   # both, with images
./bin/harbor services add tmpsvc2 opensearch  # expect "no change"
./bin/harbor services rm tmpsvc2 rabbitmq     # expect "no change"
./bin/harbor services rm tmpsvc2 mysql        # no volume yet -> no prompt
./bin/harbor services --help                  # topic, exit 0
```

Clean up: `HARBOR_YES=1 ./bin/harbor destroy tmpsvc2 --files`

- [ ] **Step 7: Docs and stage**

Add `harbor services` rows to the README and `plan.md` command tables, a CHANGELOG `### Added` line, and cover it in `ai/skills/harbor/`.

```bash
./test/run.sh && shellcheck lib/services.sh bin/harbor lib/completion.sh lib/help.sh
git add -A
```

Then run the full CLAUDE.md §7 checklist and hand off to the repo owner to commit.

---

## Self-Review

**Spec coverage:** A→Tasks 3,4 · B→Tasks 1,2 · C (compose)→Task 5 · C (confirm gate)→Task 7 · D→Tasks 6,8 · E (`harbor services`)→Task 10 · F (tests)→Tasks 1,2,3,4,7,10 · G (docs)→Tasks 9,10. No gaps.

**Known deviations from the spec, deliberate:**
1. The spec calls `_manifest_set_line` new machinery. `_materialize_services` (`lib/init.sh:76-94`) already does an in-place awk line rewrite, so Task 1 *generalizes proven code* rather than inventing it — lower risk than the spec implies.
2. The helper is named `manifest_set_line` (no leading underscore) because it lives in `lib/manifest.sh` and is used across libs; CLAUDE.md reserves the `_` prefix for internal helpers.

**Verified against the source while writing this plan** (no longer assumptions): the projects-dir global is `HARBOR_PROJECTS` (`lib/common.sh:14`); doctor's extension variable is `baseline` (`lib/doctor.sh:87-92`); `cmd_wire`'s framework variable is `framework`, resolved at `lib/wire.sh:80` after `connection.env` is sourced at 77-78.

**Still requires live confirmation:** the `oldlist` awk in Task 7 Step 4 — its indentation pattern must be checked against a real generated `docker-compose.yml` before it is relied on.

**Cross-task hazard worth restating:** Task 6 removes `DB_*` from a DB-less project's `connection.env`, and `cmd_wire` sources that file under `set -u`. Task 8's `has_db` guard is what stops `wire` from dying on an unbound variable. Task 8 must not ship without Task 6, and Task 6's verification should not be read as "wire still works" — that is Task 8's job.

**Type consistency:** `_project_services`, `project_has_service`, `project_has_stack`, `services_catalog`, `services_validate`, `services_parse_arg`, `services_pick_parse`, `services_select`, `services_dropped`, `services_confirm_shrink`, `services_apply`, `manifest_set_line` — each defined once and referenced under that exact name throughout.
