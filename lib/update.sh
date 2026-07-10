#!/usr/bin/env bash
# update.sh — self-update Harbor: fast-forward the checkout to origin/main and
# re-seed the derived, project-side artifacts (agent skills), then surface the
# right follow-up steps for whatever changed. Never rewrites history or creates
# merge commits (ff-only); the projects/ dir is git-ignored by Harbor's repo, so
# reseeding an app's skill never dirties Harbor's own tree.

_git() { git -C "$HARBOR_ROOT" "$@"; }

# The Harbor projects (dirs under projects/ that carry a .harbor manifest).
_harbor_projects() {
  local d name
  for d in "$HARBOR_PROJECTS"/*/; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    [ -f "$(manifest_path "$name")" ] && printf '%s\n' "$name"
  done
}

# Force-refresh the agent skill in every project so improvements propagate.
update_reseed_skills() {
  local name count=0
  # shellcheck disable=SC2046  # names are validated (no spaces); split on newlines
  for name in $(_harbor_projects); do
    init_write_agent_skills "$name" 1
    step "refreshed skill → projects/$name/.claude/skills/harbor"
    count=$((count + 1))
  done
  [ "$count" -eq 0 ] && step "no projects to reseed"
  return 0
}

# Version string baked into the (possibly just-updated) launcher on disk — the
# running process still holds the pre-update value in $HARBOR_VERSION.
_update_disk_version() {
  grep -E '^HARBOR_VERSION=' "$HARBOR_ROOT/bin/harbor" 2>/dev/null | head -1 | cut -d'"' -f2
}

cmd_update() {
  local check=0 stash=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --check)   check=1; shift ;;
      --stash)   stash=1; shift ;;
      --yes|-y)  HARBOR_YES=1; shift ;;
      -h|--help) echo "usage: harbor update [--check] [--stash] [--yes]"; return 0 ;;
      *) die "unknown option: $1 (usage: harbor update [--check] [--stash])" ;;
    esac
  done

  need_cmd git
  _git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "harbor update needs a git checkout at $HARBOR_ROOT (not a git repo)"
  _git remote get-url origin >/dev/null 2>&1 \
    || die "no 'origin' remote in $HARBOR_ROOT → git remote add origin <url>"

  local branch before
  branch="$(_git rev-parse --abbrev-ref HEAD)"
  before="$(_git rev-parse HEAD)"

  log "harbor update — fetching origin (on '$branch', $HARBOR_VERSION)"
  _git fetch --quiet --prune origin || die "git fetch failed → check your network / remote"

  local remote_ref="origin/main" remote_head
  _git rev-parse --verify --quiet "$remote_ref" >/dev/null \
    || die "no '$remote_ref' on origin (is main the release branch?)"
  remote_head="$(_git rev-parse "$remote_ref")"

  # --- already current ---------------------------------------------------------
  if [ "$before" = "$remote_head" ]; then
    ok "already up to date ($HARBOR_VERSION, $(_git rev-parse --short HEAD))"
    if [ "$check" = 0 ]; then
      log "re-seeding agent skills (in case the skill changed locally)"
      update_reseed_skills
    fi
    return 0
  fi

  # --- there is an update ------------------------------------------------------
  local behind log_lines
  behind="$(_git rev-list --count "HEAD..$remote_ref" 2>/dev/null || echo '?')"
  log "$behind new commit(s) on $remote_ref:"
  log_lines="$(_git log --oneline --no-decorate "HEAD..$remote_ref" | head -n 20)"
  printf '%s\n' "$log_lines" | sed 's/^/    /'

  if [ "$check" = 1 ]; then
    step "run 'harbor update' to apply"
    return 0
  fi

  [ "$branch" = "main" ] || warn "on '$branch', not 'main' — will fast-forward it to $remote_ref"

  # --- clean-tree guard (untracked files don't block a fast-forward) -----------
  local dirty=0 stashed=0
  _git diff --quiet && _git diff --cached --quiet || dirty=1
  if [ "$dirty" = 1 ]; then
    [ "$stash" = 1 ] || die "working tree has local changes → commit them, or re-run: harbor update --stash"
    log "stashing local changes"
    _git stash push -u -m "harbor-update-$before" >/dev/null || die "git stash failed"
    stashed=1
  fi

  # --- fast-forward only (never a merge commit / rewrite) ----------------------
  log "fast-forwarding $branch → $remote_ref"
  if ! _git merge --ff-only "$remote_ref" >/dev/null 2>&1; then
    [ "$stashed" = 1 ] && _git stash pop >/dev/null 2>&1 || true
    die "cannot fast-forward '$branch' (diverged from $remote_ref) → reconcile manually with git"
  fi
  if [ "$stashed" = 1 ]; then
    log "restoring stashed changes"
    _git stash pop >/dev/null 2>&1 \
      || warn "stash pop hit conflicts — your changes are safe in 'git stash list'; resolve with 'git status'"
  fi

  local after; after="$(_git rev-parse HEAD)"
  ok "updated $(_git rev-parse --short "$before") → $(_git rev-parse --short "$after")  ($HARBOR_VERSION → $(_update_disk_version))"

  # --- re-seed derived project artifacts --------------------------------------
  log "re-seeding agent skills into projects"
  update_reseed_skills

  # --- targeted follow-ups based on what actually changed ----------------------
  local changed; changed="$(_git diff --name-only "$before" "$after")"
  case "$changed" in
    *templates/nginx/*|*templates/php/*|*templates/dnsmasq/*|*.plist.tmpl*|*lib/launchd.sh*|*lib/nginx.sh*|*lib/php.sh*|*lib/dns.sh*)
      warn "platform config/templates changed → run 'harbor setup' to re-render + reload nginx/php/dnsmasq" ;;
  esac
  case "$changed" in
    *templates/compose/*|*lib/compose.sh*|*lib/init.sh*)
      warn "compose templates changed → per project: 'harbor render <name> && harbor up <name>' to apply" ;;
  esac
  case "$changed" in
    *bin/harbor*|*lib/*)
      step "launcher/libraries updated — effective on your next 'harbor' command (this run used the old code)" ;;
  esac

  # --- health check ------------------------------------------------------------
  log "running doctor"
  cmd_doctor || warn "doctor flagged items to resolve (see above)"

  ok "harbor update complete — see CHANGELOG.md for what's new"
}
