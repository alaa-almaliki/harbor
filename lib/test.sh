#!/usr/bin/env bash
# test.sh — run Harbor's own pure-bash unit suite (test/).
#
# Thin wrapper over test/run.sh so the suite is discoverable from the CLI.
# Any argument is a name filter passed through:  harbor test manifest
# Exits with the runner's status (nonzero if any assertion failed).

cmd_test() {
  local runner="$HARBOR_ROOT/test/run.sh"
  [ -f "$runner" ] || die "test suite not found at $runner"
  bash "$runner" "$@"
}
