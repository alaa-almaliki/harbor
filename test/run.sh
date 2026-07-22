#!/usr/bin/env bash
# test/run.sh — discover and run Harbor's pure-bash unit tests.
#
# Runs every test_*.sh in this dir in its own process (isolation) and renders a
# compact two-column grid — one cell per file, `✓ <n>` when all its assertions
# pass, `✗ <failed>/<total>` when some don't — with every failure expanded in a
# FAILURES block below. Exits nonzero if any assertion failed or any file
# crashed. No dependencies, no host mutation.
#
#   ./test/run.sh            # run all
#   ./test/run.sh manifest   # run only files whose name contains "manifest"
#
# Each file's lib.sh emits a compact marker stream (SOH-prefixed) because we set
# HARBOR_TEST_STREAM below; run standalone (`bash test/test_x.sh`) the same
# helpers print readable ok/FAIL lines instead.
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARBOR_ROOT="$(cd -P "$HERE/.." && pwd)"
export HARBOR_ROOT
export HARBOR_TEST_DIR="$HERE"
export HARBOR_TEST_STREAM=1

# Colors only when stdout is a terminal, so piping to a file / CI log stays clean.
if [ -t 1 ]; then
  c_grn="$(printf '\033[32m')"; c_red="$(printf '\033[31m')"
  c_ylw="$(printf '\033[33m')"; c_dim="$(printf '\033[2m')"
  c_bold="$(printf '\033[1m')"; c_rst="$(printf '\033[0m')"
else
  c_grn=""; c_red=""; c_ylw=""; c_dim=""; c_bold=""; c_rst=""
fi
SOH="$(printf '\001')"

NAME_W=16          # left-pad for the short name (longest is search_replace = 14)
COL_W=28           # display width of a whole cell, so column 2 lines up

# Live "testing <part>…" spinner — only on a terminal (a redirected run stays
# clean, no carriage-return spam in logs). HARBOR_TEST_SPINNER forces it on/off;
# HARBOR_TEST_SPIN_DELAY tunes the frame delay (0 = no sleep, for tests).
spin_frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
spin_delay="${HARBOR_TEST_SPIN_DELAY:-0.08}"
spinner=0; [ -t 1 ] && spinner=1
case "${HARBOR_TEST_SPINNER:-}" in 1) spinner=1 ;; 0) spinner=0 ;; esac

total_pass=0
total_fail=0
files=0
skipped=0
failfile="$(mktemp)"
notesfile="$(mktemp)"
runout="$(mktemp)"
trap 'rm -f "$failfile" "$notesfile" "$runout"' EXIT

# run_file <path> <short> — run one test file, capturing its output into $out and
# its status into $rc. On a terminal it animates a spinner while the file runs
# (the file goes to the background so we can); otherwise it just runs, silent.
run_file() {
  if [ "$spinner" = 0 ]; then
    if out="$(bash "$1" 2>&1)"; then rc=0; else rc=$?; fi
    return
  fi
  local pid i=0 nf="${#spin_frames[@]}"
  bash "$1" > "$runout" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r%s%s testing %s…%s\033[K' "$c_dim" "${spin_frames[$((i % nf))]}" "$2" "$c_rst"
    i=$((i + 1))
    sleep "$spin_delay"
  done
  wait "$pid"; rc=$?
  out="$(cat "$runout")"
  printf '\r\033[K'                 # wipe the spinner line before the grid
}

# Grid cells accumulate here (printed two-per-row after the loop). Parallel
# arrays: the colored text to print, and its DISPLAY width (bytes minus the 2
# extra bytes a ✓/✗ glyph costs), so padding to COL_W stays correct.
n_cells=0
cell_text=(); cell_disp=()

add_cell() {  # <colored-text> <display-width>
  cell_text[n_cells]="$1"; cell_disp[n_cells]="$2"; n_cells=$((n_cells + 1))
}

for f in "$HERE"/test_*.sh; do
  [ -e "$f" ] || continue
  if [ "$#" -gt 0 ]; then
    case "${f##*/}" in *"$1"*) ;; *) continue ;; esac
  fi
  files=$((files + 1))
  name="${f##*/}"
  short="${name#test_}"; short="${short%.sh}"

  run_file "$f" "$short"

  # Parse the marker stream for failure DETAIL and stray output. Counts come from
  # __TALLY__ below, not from tallying dots. `in_fail` routes non-marker lines to
  # the open failure block verbatim (so multiline expected/actual survives);
  # anything outside a failure is stray output we surface, never hide.
  # Stray (non-marker) output is held per file and only surfaced below if the
  # file DIDN'T crash — a crash dumps its full output anyway, so emitting the
  # same lines under NOTES too would just duplicate them.
  in_fail=0; ff=0; filenotes=""
  while IFS= read -r line; do
    case "$line" in
      "${SOH}P")   in_fail=0 ;;
      "${SOH}F "*) in_fail=1; ff=$((ff + 1))
                   [ "$ff" -eq 1 ] && printf '\n  %s%s%s\n' "$c_bold" "$name" "$c_rst" >> "$failfile"
                   printf '    %s\n' "${line#"${SOH}F "}" >> "$failfile" ;;
      "${SOH}S "*) : ;;
      __TALLY__*)  : ;;
      "${SOH}"*)   : ;;
      *)           if [ "$in_fail" = 1 ]; then printf '      %s%s%s\n' "$c_dim" "$line" "$c_rst" >> "$failfile"
                   elif [ -n "$line" ]; then filenotes="$filenotes  $short: ${c_dim}${line}${c_rst}
"; fi ;;
    esac
  done <<EOF
$out
EOF

  tally="$(printf '%s\n' "$out" | grep '^__TALLY__' | tail -1)"
  pad_name="$(printf '%-*s' "$NAME_W" "$short")"

  if [ -z "$tally" ]; then                       # crashed before report()
    total_fail=$((total_fail + 1))
    add_cell "$pad_name ${c_red}✗ CRASH${c_rst}" $((NAME_W + 8))
    printf '\n  %s%s%s\n    crashed (rc=%s) — output:\n' "$c_bold" "$name" "$c_rst" "$rc" >> "$failfile"
    printf '%s\n' "$out" | grep -v "^$SOH" | sed "s/^/      ${c_dim}/; s/\$/${c_rst}/" >> "$failfile"
    continue
  fi
  p="$(printf '%s' "$tally" | awk '{print $2}')"; p="${p:-0}"
  q="$(printf '%s' "$tally" | awk '{print $3}')"; q="${q:-0}"
  total_pass=$((total_pass + p)); total_fail=$((total_fail + q))
  [ -n "$filenotes" ] && printf '%s' "$filenotes" >> "$notesfile"

  # skip_all yields a zero tally plus a skip marker.
  if [ "$p" -eq 0 ] && [ "$q" -eq 0 ] && printf '%s\n' "$out" | grep -q "^${SOH}S "; then
    skipped=$((skipped + 1))
    add_cell "$pad_name ${c_ylw}SKIP${c_rst}" $((NAME_W + 5))
  elif [ "$q" -gt 0 ]; then
    info="$q/$((p + q))"
    add_cell "$pad_name ${c_red}✗ $info${c_rst}" $((NAME_W + 3 + ${#info}))
  else
    add_cell "$pad_name ${c_grn}✓ $p${c_rst}" $((NAME_W + 3 + ${#p}))
  fi
done

# Two cells per row; pad the left cell (by its display width) so the right aligns.
i=0
while [ "$i" -lt "$n_cells" ]; do
  if [ $((i + 1)) -lt "$n_cells" ]; then
    pad=$((COL_W - ${cell_disp[$i]})); [ "$pad" -lt 1 ] && pad=1
    printf '%s%*s%s\n' "${cell_text[$i]}" "$pad" "" "${cell_text[$((i + 1))]}"
  else
    printf '%s\n' "${cell_text[$i]}"
  fi
  i=$((i + 2))
done

[ -s "$notesfile" ] && { printf '\n%sNOTES%s\n' "$c_dim" "$c_rst"; cat "$notesfile"; }
[ -s "$failfile" ]  && { printf '\n%sFAILURES%s\n' "$c_red" "$c_rst"; cat "$failfile"; }

printf '%s\n' "────────────────────────────────────────"
if [ "$total_fail" -eq 0 ]; then
  printf '%s%d passed%s, %d failed  (%d files' "$c_grn" "$total_pass" "$c_rst" "$total_fail" "$files"
else
  printf '%d passed, %s%d failed%s  (%d files' "$total_pass" "$c_red" "$total_fail" "$c_rst" "$files"
fi
[ "$skipped" -gt 0 ] && printf ', %d skipped' "$skipped"
printf ')\n'

[ "$total_fail" -eq 0 ]
