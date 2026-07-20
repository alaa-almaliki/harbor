#!/usr/bin/env bash
# manifest.sh — read .harbor/harbor.yml (constrained YAML subset) + global config.
#
# No yq/jq. bash 3.2 safe (no associative arrays). The manifest is the source of
# truth; everything else is generated from it. Supported subset (what Harbor
# emits and a human reasonably edits):
#   key: scalar            ->  manifest_get <file> key
#   key: "quoted scalar"
#   key: [a, b, c]         ->  manifest_list <file> key   (space-separated)
#   key: { k: v, k2: v2 }  ->  manifest_get <file> key.k
#   nested flow maps:      ->  manifest_get <file> multistore.stores.de
# Block-style nested maps/sequences are NOT supported — use flow style for nesting.

# --- low-level string helpers ------------------------------------------------
_mf_trim() { printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }

# strip a trailing " # comment" (space + hash). Leaves values like a#b intact.
_mf_decomment() { printf '%s' "$1" | sed -e 's/[[:space:]]#.*$//'; }

_mf_unquote() {
  local s="$1"
  case "$s" in
    \"*\") s="${s#\"}"; s="${s%\"}" ;;
    \'*\') s="${s#\'}"; s="${s%\'}" ;;
  esac
  printf '%s' "$s"
}

# inner of a flow value: { ... } or [ ... ]
_mf_inner() {
  local s; s="$(_mf_trim "$1")"
  case "$s" in
    \{*\}) s="${s#\{}"; s="${s%\}}" ;;
    \[*\]) s="${s#\[}"; s="${s%\]}" ;;
  esac
  _mf_trim "$s"
}

# split a flow body on top-level (depth-0, unquoted) commas; one item per line.
_mf_split_top() {
  local s="$1" i=0 depth=0 ch start=0 len item quote=""
  len=${#s}
  while [ "$i" -lt "$len" ]; do
    ch="${s:$i:1}"
    if [ -n "$quote" ]; then
      # inside a quoted run: only the matching quote char ends it
      [ "$ch" = "$quote" ] && quote=""
    else
      case "$ch" in
        '"'|"'") quote="$ch" ;;
        '{'|'[') depth=$((depth + 1)) ;;
        '}'|']') depth=$((depth - 1)) ;;
        ',')
          if [ "$depth" -eq 0 ]; then
            item="${s:$start:$((i - start))}"
            _mf_trim "$item"; printf '\n'
            start=$((i + 1))
          fi
          ;;
      esac
    fi
    i=$((i + 1))
  done
  item="${s:$start}"
  item="$(_mf_trim "$item")"
  [ -n "$item" ] && { printf '%s' "$item"; printf '\n'; }
}

# raw value (decommented, trimmed) for a top-level key in a file
_mf_raw() {
  local file="$1" key="$2" line
  line="$(grep -E "^${key}:" "$file" 2>/dev/null | head -1)" || return 1
  [ -n "$line" ] || return 1
  line="${line#*:}"
  _mf_trim "$(_mf_decomment "$line")"
}

# from a flow-map string, get the value for <key> (top-level only)
_mf_map_get() {
  local mapstr="$1" want="$2" inner item k v
  inner="$(_mf_inner "$mapstr")"
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    k="$(_mf_trim "${item%%:*}")"
    v="$(_mf_trim "${item#*:}")"
    if [ "$k" = "$want" ]; then printf '%s' "$v"; return 0; fi
  done <<EOF
$(_mf_split_top "$inner")
EOF
  return 1
}

# --- public API --------------------------------------------------------------
# manifest_get <file> <dotted.path> [default]
manifest_get() {
  local file="$1" path="$2" def="${3-}" top rest raw
  [ -f "$file" ] || { printf '%s' "$def"; return 0; }
  top="${path%%.*}"
  raw="$(_mf_raw "$file" "$top")" || { printf '%s' "$def"; return 0; }
  if [ "$top" = "$path" ]; then
    printf '%s' "$(_mf_unquote "$raw")"; return 0
  fi
  # descend through nested flow maps
  rest="${path#*.}"
  local cur="$raw" seg
  while [ -n "$rest" ]; do
    seg="${rest%%.*}"
    cur="$(_mf_map_get "$cur" "$seg")" || { printf '%s' "$def"; return 0; }
    if [ "$seg" = "$rest" ]; then break; fi
    rest="${rest#*.}"
  done
  printf '%s' "$(_mf_unquote "$cur")"
}

# manifest_list <file> <dotted.path>  -> space-separated items (flow list)
manifest_list() {
  local file="$1" path="$2" raw inner out=""
  raw="$(manifest_get "$file" "$path" "")"
  [ -n "$raw" ] || return 0
  inner="$(_mf_inner "$raw")"
  local item
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    item="$(_mf_unquote "$item")"
    if [ -z "$out" ]; then out="$item"; else out="$out $item"; fi
  done <<EOF
$(_mf_split_top "$inner")
EOF
  printf '%s' "$out"
}

# manifest_pairs <file> <dotted.path>  -> one "key=value" line per flow-map entry
# (parses the map once; keys and values are unquoted). Empty if not a map.
manifest_pairs() {
  local file="$1" path="$2" raw inner item k v
  raw="$(manifest_get "$file" "$path" "")"
  [ -n "$raw" ] || return 0
  inner="$(_mf_inner "$raw")"
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    k="$(_mf_unquote "$(_mf_trim "${item%%:*}")")"
    v="$(_mf_unquote "$(_mf_trim "${item#*:}")")"
    printf '%s=%s\n' "$k" "$v"
  done <<EOF
$(_mf_split_top "$inner")
EOF
}

# manifest_map_keys <file> <dotted.path>  -> keys of a flow map (space-separated)
manifest_map_keys() {
  local file="$1" path="$2" raw inner out="" item k
  raw="$(manifest_get "$file" "$path" "")"
  [ -n "$raw" ] || return 0
  inner="$(_mf_inner "$raw")"
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    k="$(_mf_trim "${item%%:*}")"
    if [ -z "$out" ]; then out="$k"; else out="$out $k"; fi
  done <<EOF
$(_mf_split_top "$inner")
EOF
  printf '%s' "$out"
}

manifest_has() { [ -n "$(manifest_get "$1" "$2" "")" ]; }

# manifest_key_present <file> <key> — is <key> present as a TOP-LEVEL line,
# regardless of its value? A true PRESENCE test, unlike manifest_has (a VALUE
# test: non-empty resolved value). A bare `services:` (nothing after the
# colon) is the natural hand-edit for "no services" — manifest_has reads it
# the same as an ABSENT key and a caller keying off it falls back to a
# framework default instead of "none", with no way to express "none" through
# the manifest at all. manifest_has is left alone (see manifest_set_line's
# callers) since changing its long-standing value semantics globally is
# riskier than adding this distinct, narrowly-scoped helper.
#
# Same top-level literal-anchored match as manifest_set_line/manifest_del_line
# (awk `index($0, k) == 1`), reused rather than a fresh regex for the same
# BRE/ERE-mismatch reason documented on manifest_set_line below.
manifest_key_present() {
  local file="$1" key="$2"
  [ -f "$file" ] || return 1
  MF_K="$key:" awk 'BEGIN { k = ENVIRON["MF_K"] }
      index($0, k) == 1 { found = 1 } END { exit !found }' "$file"
}

# manifest_raw_line <file> <key> — the exact TOP-LEVEL line for <key>,
# including any trailing comment, or empty if absent. Companion to
# manifest_key_present: this returns the verbatim bytes so a caller can
# snapshot a key and restore it later without reconstructing "key: value" —
# manifest_get can't be used for that, since it runs _mf_decomment and would
# silently drop a trailing "# comment" on restore.
manifest_raw_line() {
  local file="$1" key="$2"
  [ -f "$file" ] || return 0
  MF_K="$key:" awk 'BEGIN { k = ENVIRON["MF_K"] }
      index($0, k) == 1 { print; exit }' "$file"
}

# _mf_replace_or_append_line <file> <key> <line> — internal: replace a
# TOP-LEVEL key's line with the EXACT text <line>, appending it if the key is
# absent. Shared by manifest_set_line (which builds "<key>: <value>") and
# manifest_set_raw_line (an arbitrary verbatim line, e.g. one captured earlier
# by manifest_raw_line, comment and all). Every other byte of the file is
# preserved — the manifest is hand-editable and must survive a machine write.
#
# Matching is a LITERAL prefix test (awk `index($0, k) == 1`), not a regex —
# no escaping needed, and no dialect to get wrong. This used to build a
# regex-escaped key with sed and match it with `grep -q "^$kesc:"` (BRE) to
# decide replace-vs-append, then `awk '$0 ~ k'` (ERE) to do the replace. Those
# two dialects disagree on `+ ? | ( ) { }` — literal in BRE, metachars in ERE
# — so a key like "php+version" would take the replace branch (grep matches)
# but awk would never rewrite the line (ERE doesn't), silently dropping the
# write. `index()` does plain substring search regardless of key content, so
# that whole class of bug is gone rather than patched. `index($0, k) == 1`
# anchors to column 0 (awk `index` is 1-based), which is what makes this a
# TOP-LEVEL key match — a key nested inside a flow map never starts its line.
#
# Key/line are passed via ENVIRON, not `awk -v`: `-v name=value` runs `value`
# through awk's string-literal escape processing (`\b`, `\t`, `\\`, …), so a
# key containing a literal backslash would come out mangled. Environment
# variables are handed to awk as raw bytes with no such processing.
_mf_replace_or_append_line() {
  local file="$1" key="$2" line="$3" tmp
  tmp="$file.tmp.$$"
  if manifest_key_present "$file" "$key"; then
    MF_K="$key:" MF_LINE="$line" awk '
      BEGIN { k = ENVIRON["MF_K"]; line = ENVIRON["MF_LINE"] }
      index($0, k) == 1 { print line; next }
      { print }
    ' "$file" > "$tmp" && mv "$tmp" "$file"
  else
    if [ -s "$file" ] && [ -n "$(tail -c1 "$file")" ]; then printf '\n' >> "$file"; fi
    printf '%s\n' "$line" >> "$file"
  fi
}

# manifest_set_line <file> <key> <value> — set a TOP-LEVEL key's line to
# "<key>: <value>", replacing it in place or appending if absent. One line is
# enough because CLAUDE.md requires flow style for nesting, so a value like
# `services: { … }` never spans lines. See _mf_replace_or_append_line for the
# matching rationale.
manifest_set_line() {
  local file="$1" key="$2" value="$3"
  _mf_replace_or_append_line "$file" "$key" "$key: $value"
}

# manifest_set_raw_line <file> <key> <rawline> — like manifest_set_line, but
# writes <rawline> VERBATIM instead of building "<key>: <value>" — pairs with
# manifest_raw_line to restore a snapshotted line (including a trailing
# comment) byte-for-byte, rather than losing the comment through
# manifest_get's decommenting on the way to reconstructing the line.
manifest_set_raw_line() {
  local file="$1" key="$2" rawline="$3"
  _mf_replace_or_append_line "$file" "$key" "$rawline"
}

# manifest_del_line <file> <key> — remove a TOP-LEVEL key's line entirely
# (as opposed to manifest_set_line, which would leave a bare "<key>:" behind).
# A safe no-op when the key is absent. Every other byte is preserved.
#
# Needed to make a declined write a true no-op: if a key was absent before a
# manifest_set_line, restoring with manifest_set_line would leave a bare
# "<key>:" line — present-but-empty is a different state than absent even
# though manifest_get reads both the same way (manifest_has is what tells
# them apart). Same `index($0, k) == 1` top-level-anchored literal match as
# manifest_set_line, for the same reason (see its comment) — reused here
# rather than a regex so this can't independently regress into the BRE/ERE
# mismatch that once silently dropped a write.
manifest_del_line() {
  local file="$1" key="$2" tmp
  [ -f "$file" ] || return 0
  tmp="$file.tmp.$$"
  MF_K="$key:" awk '
    BEGIN { k = ENVIRON["MF_K"] }
    index($0, k) == 1 { next }
    { print }
  ' "$file" > "$tmp" && mv "$tmp" "$file"
}

manifest_path() { printf '%s' "$(project_harbor_dir "$1")/harbor.yml"; }

# setting_get <project> <manifest.path> <CONFIG_KEY> <builtin-default>
# precedence: project manifest -> global config -> builtin default
setting_get() {
  local name="$1" mpath="$2" ckey="$3" def="$4" v=""
  if [ -n "$name" ]; then
    v="$(manifest_get "$(manifest_path "$name")" "$mpath" "")"
  fi
  [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  printf '%s' "$(config_get "$ckey" "$def")"
}
