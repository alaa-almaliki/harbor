#!/usr/bin/env bash
# test/run.sh — discover and run Harbor's pure-bash unit tests.
#
# Runs every test_*.sh in this dir in its own process (isolation), prints each
# file's ok/FAIL lines, and sums the per-file __TALLY__ line. Exits nonzero if
# any assertion failed or any file crashed. No dependencies, no host mutation.
#
#   ./test/run.sh            # run all
#   ./test/run.sh manifest   # run only test_manifest.sh
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARBOR_ROOT="$(cd -P "$HERE/.." && pwd)"
export HARBOR_ROOT
export HARBOR_TEST_DIR="$HERE"

total_pass=0
total_fail=0
files=0

for f in "$HERE"/test_*.sh; do
  [ -e "$f" ] || continue
  # Optional filter: only run files whose name contains the given argument.
  if [ "$#" -gt 0 ]; then
    case "${f##*/}" in *"$1"*) ;; *) continue ;; esac
  fi
  files=$((files + 1))
  printf '\n\033[1m%s\033[0m\n' "${f##*/}"

  if out="$(bash "$f" 2>&1)"; then rc=0; else rc=$?; fi
  printf '%s\n' "$out" | grep -v '^__TALLY__'

  tally="$(printf '%s\n' "$out" | grep '^__TALLY__' | tail -1)"
  if [ -z "$tally" ]; then
    printf '  \033[31mERROR: file crashed with no tally (rc=%s)\033[0m\n' "$rc"
    total_fail=$((total_fail + 1))
    continue
  fi
  p="$(printf '%s' "$tally" | awk '{print $2}')"
  q="$(printf '%s' "$tally" | awk '{print $3}')"
  total_pass=$((total_pass + ${p:-0}))
  total_fail=$((total_fail + ${q:-0}))
done

printf '\n=========================================\n'
if [ "$total_fail" -eq 0 ]; then
  printf '\033[32m%d passed\033[0m, %d failed  (%d files)\n' "$total_pass" "$total_fail" "$files"
else
  printf '%d passed, \033[31m%d failed\033[0m  (%d files)\n' "$total_pass" "$total_fail" "$files"
fi

[ "$total_fail" -eq 0 ]
