#!/usr/bin/env bash
# record-clones.sh — accumulate GitHub "git clones" traffic into an all-time tally.
#
# GitHub only retains the last 14 days of clone traffic, so this snapshots that
# window and merges it into a persistent, date-keyed store. Run at least once
# every 14 days (the workflow runs daily) and no day is ever lost. Re-fetching an
# already-recorded day just overwrites it with GitHub's latest number for that
# day, so nothing is ever double-counted.
#
# Env:
#   GITHUB_REPOSITORY  owner/repo   (set automatically in GitHub Actions)
#   GH_TOKEN           a token with push/admin access to the repo (traffic API
#                      requires it) — the workflow feeds secrets.TRAFFIC_TOKEN
#                      when present, else the built-in GITHUB_TOKEN.
set -euo pipefail

repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY not set}"
token="${GH_TOKEN:?GH_TOKEN not set}"
dir=".github/traffic"
data="$dir/clones.json"
badge="$dir/clones-badge.json"

mkdir -p "$dir"
[ -f "$data" ] || printf '{}\n' > "$data"

# Last-14-days clone traffic. Fail loudly on a non-2xx (e.g. 403 = token lacks
# the required repo access) so the run turns red instead of silently recording 0.
resp="$(curl -fsSL \
  -H "Authorization: Bearer $token" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/repos/$repo/traffic/clones")"

# Merge each day's {count,uniques} into the store, keyed by YYYY-MM-DD.
merged="$(jq -n \
  --argjson old "$(cat "$data")" \
  --argjson new "$resp" '
  reduce ($new.clones[]?) as $c ($old;
    .[$c.timestamp[0:10]] = {count: $c.count, uniques: $c.uniques})
  ')"
printf '%s\n' "$merged" > "$data"

# All-time total clones = sum of daily counts (exact). Unique cloners cannot be
# summed across weeks — the same person recurs — so uniques are per-window only
# and deliberately not totalled here.
total="$(printf '%s' "$merged" | jq '[.[].count] | add // 0')"
days="$(printf '%s' "$merged" | jq 'length')"

# Shields.io endpoint badge the README embeds.
jq -n --arg msg "$total" '{
  schemaVersion: 1,
  label: "Number of downloads",
  message: $msg,
  color: "blue"
}' > "$badge"

printf 'recorded: total_clones=%s across %s day(s)\n' "$total" "$days"
