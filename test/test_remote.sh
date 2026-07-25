#!/usr/bin/env bash
# test_remote.sh — remote `db pull` helpers (lib/remote.sh): safe shell-quoting,
# the argv-safe password transport, password resolution order, and the gitignore
# guard. Pure logic only: `ssh` is stubbed, so nothing touches a network or host.
set -uo pipefail
. "$HARBOR_TEST_DIR/lib.sh"
harbor_load common remote

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export HARBOR_PROJECTS="$tmp/projects"
mkdir -p "$(project_harbor_dir demo)"

# --- _shq: single-quoting round-trips arbitrary values -----------------------
# eval of the quoted form must reproduce the original — quotes, $, backslash,
# spaces, shell metacharacters and all — or a password could break/inject.
for s in "plain" "a'b" 'a$b' 'a\b' "a b" "a;b|c&d" 'a"b'; do
  got="$(eval "v=$(_shq "$s"); printf %s \"\$v\"")"
  assert_eq "_shq round-trips [$s]" "$s" "$got"
done

# --- _remote_dump: password goes via MYSQL_PWD in the script, never in argv ---
SSH_ARGV="$tmp/argv"; SSH_IN="$tmp/in"
ssh() { printf '%s\n' "$*" > "$SSH_ARGV"; cat > "$SSH_IN"; }   # stub: record argv + stdin

pass="p@ss'W\$RD"                                              # quote + dollar in it
_remote_dump "ploi@host" "drahem" "dbuser" "$pass"
argv="$(cat "$SSH_ARGV")"; script="$(cat "$SSH_IN")"

assert_eq       "user: ssh argv carries no credentials" "ploi@host bash -s" "$argv"
assert_contains "user: script exports MYSQL_PWD"        "export MYSQL_PWD=" "$script"
assert_contains "user: script dumps the remote db"      "'drahem'"          "$script"
assert_contains "user: mysqldump gets -u user"          "-u 'dbuser'"       "$script"
# the password must not appear anywhere in what `ps` would show (the argv)
case "$argv" in *"$pass"*) hit=1 ;; *) hit=0 ;; esac
assert_eq "user: password never in ssh argv" "0" "$hit"
# and it must round-trip intact out of the MYSQL_PWD line the remote runs
got="$(eval "$(printf '%s\n' "$script" | grep '^export MYSQL_PWD='); printf %s \"\$MYSQL_PWD\"")"
assert_eq "user: MYSQL_PWD round-trips the password" "$pass" "$got"

# no user -> defer to the remote's own auth: still via `bash -s` (so `set -o
# pipefail` is honored on any login shell), dump runs, but NO credentials
: > "$SSH_ARGV"; : > "$SSH_IN"
_remote_dump "ploi@host" "drahem" </dev/null
argv="$(cat "$SSH_ARGV")"; script="$(cat "$SSH_IN")"
assert_eq       "no-user: still runs via bash -s (login shell not trusted)" "ploi@host bash -s" "$argv"
assert_contains "no-user: script sets pipefail"     "set -o pipefail" "$script"
assert_contains "no-user: script dumps the db"      "'drahem'"        "$script"
case "$script" in *MYSQL_PWD*) hit=1 ;; *) hit=0 ;; esac
assert_eq "no-user: no MYSQL_PWD (deferred auth)" "0" "$hit"
case "$script" in *"-u "*) hit=1 ;; *) hit=0 ;; esac
assert_eq "no-user: no -u user (deferred auth)"   "0" "$hit"

# db_host -> mysqldump connects over TCP with -h (fixes the localhost/socket
# grant mismatch: a TCP-granted app user can't match the socket's @localhost)
: > "$SSH_ARGV"; : > "$SSH_IN"
_remote_dump "ploi@host" "drahem" "dbuser" "pw" "127.0.0.1"
script="$(cat "$SSH_IN")"
assert_contains "db_host: user path adds -h host"  "-h '127.0.0.1'" "$script"
: > "$SSH_ARGV"; : > "$SSH_IN"
_remote_dump "ploi@host" "drahem" "" "" "127.0.0.1" </dev/null
script="$(cat "$SSH_IN")"
assert_contains "db_host: no-user path also honors -h" "-h '127.0.0.1'" "$script"
# no db_host -> no -h (defer to socket / remote default)
: > "$SSH_ARGV"; : > "$SSH_IN"
_remote_dump "ploi@host" "drahem" "dbuser" "pw"
script="$(cat "$SSH_IN")"
case "$script" in *"-h "*) hit=1 ;; *) hit=0 ;; esac
assert_eq "db_host: omitted -> no -h flag" "0" "$hit"

# --- _ensure_gitignored: appends once, idempotent ----------------------------
gi="$(project_harbor_dir demo)/.gitignore"
rm -f "$gi"
_ensure_gitignored demo "remote.env" 2>/dev/null
assert_ok "gitignore: creates file with the line" grep -qxF "remote.env" "$gi"
n1="$(grep -cxF "remote.env" "$gi")"
_ensure_gitignored demo "remote.env" 2>/dev/null
n2="$(grep -cxF "remote.env" "$gi")"
assert_eq "gitignore: idempotent, no duplicate line" "$n1" "$n2"

# a hand-edited .gitignore with NO trailing newline must not glue the entry onto
# the last line ("bin/remote.env"), and must stay idempotent afterward
printf 'bin/' > "$gi"          # note: no trailing newline
_ensure_gitignored demo "remote.env" 2>/dev/null
assert_ok "gitignore: line lands on its own row (no-newline file)" grep -qxF "remote.env" "$gi"
assert_ok "gitignore: prior last line preserved" grep -qxF "bin/" "$gi"
_ensure_gitignored demo "remote.env" 2>/dev/null
assert_eq "gitignore: still idempotent after newline fixup" "1" "$(grep -cxF "remote.env" "$gi")"

# --- _remote_db_password: env -> file -> (prompt, not tested here) ------------
# The prompt branch needs a /dev/tty and is out of scope for the pure suite.
export HARBOR_REMOTE_DB_PASSWORD="env-secret"
_remote_db_password demo dbuser ploi@host
assert_eq "password: env var supplies it" "env-secret" "$_RPASS"

unset HARBOR_REMOTE_DB_PASSWORD
# the file uses the SAME name as the env var (this is what bit a real user who
# put HARBOR_REMOTE_DB_PASSWORD in remote.env and still got prompted)
printf 'HARBOR_REMOTE_DB_PASSWORD=file-secret\n' > "$(project_harbor_dir demo)/remote.env"
_remote_db_password demo dbuser ploi@host 2>/dev/null
assert_eq "password: HARBOR_REMOTE_DB_PASSWORD key in remote.env works" "file-secret" "$_RPASS"

export HARBOR_REMOTE_DB_PASSWORD="env-wins"
_remote_db_password demo dbuser ploi@host 2>/dev/null
assert_eq "password: exported env var beats the file" "env-wins" "$_RPASS"
unset HARBOR_REMOTE_DB_PASSWORD

report
