#!/usr/bin/env bash
# Tests for with-github-token.sh. Plain bash, isolated HOME, canary token.
# shellcheck disable=SC2016  # single quotes are intentional: expanded by the inner bash
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helper="$here/../with-github-token.sh"
canary="ghp_CANARY0123456789abcdefghijklmnopqrstuv"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export HOME="$work/home" TMPDIR="$work/tmp" GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME" "$TMPDIR"
unset PRIVATE_DEPS_TOKEN PRIVATE_DEPS_SECRET_FILE GIT_CONFIG_COUNT GIT_ASKPASS
export GITHUB_ENV="$work/github_env"
: >"$GITHUB_ENV"

fails=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails + 1)); }
check() { # check <name> <command...>
  local name="$1"; shift
  if "$@"; then pass "$name"; else fail "$name"; fi
}
run() { # run the helper with the canary token; capture stdout/stderr/rc
  PRIVATE_DEPS_TOKEN="$canary" "$helper" "$@" >"$work/out" 2>"$work/err"
  rc=$?
}
ask() { # ask <prompt>: invoke the askpass helper from inside the wrapper
  PRIVATE_DEPS_TOKEN="$canary" "$helper" bash -c '"$GIT_ASKPASS" "$1"' _ "$1" 2>"$work/err"
}
absent() { ! grep -qF -- "$1" "$2"; } # absent <needle> <file>

# --- askpass answers ---
check "username prompt answered" \
  test "$(ask "Username for 'https://github.com': ")" = "x-access-token"
check "password prompt answered (with user)" \
  test "$(ask "Password for 'https://x-access-token@github.com': ")" = "$canary"
check "password prompt answered (bare host)" \
  test "$(ask "Password for 'https://github.com': ")" = "$canary"

check "password prompt answered (path-qualified)" \
  test "$(ask "Password for 'https://x-access-token@github.com/owner/repo.git': ")" = "$canary"
check "password prompt answered (bare host, path-qualified)" \
  test "$(ask "Password for 'https://github.com/owner/repo.git': ")" = "$canary"
check "username prompt answered (path-qualified)" \
  test "$(ask "Username for 'https://github.com/owner/repo.git': ")" = "x-access-token"

# --- lookalike / foreign hosts refused ---
for p in \
  "Username for 'https://evil.example': " \
  "Password for 'https://x-access-token@evil.example': " \
  "Username for 'https://github.com.evil.example': " \
  "Password for 'https://x-access-token@github.com.evil.example': " \
  "Password for 'https://github.com.evil.example': " \
  "Username for 'https://github.com:8443': " \
  "Password for 'https://x-access-token@github.com:8443': " \
  "Password for 'https://attacker@github.com': " \
  "Password for 'https://x-access-token@github.com@evil.example': " \
  "Username for 'http://github.com': " \
  "Password for 'https://x-access-token@github.com.evil.example/owner/repo.git': " \
  "Password for 'https://x-access-token@github.comevil/owner/repo.git': " \
  "Password for 'https://github.com:8443/owner/repo.git': " \
  "Password for 'http://x-access-token@github.com/owner/repo.git': " \
  "Username for 'https://gist.github.com': " \
  "Passphrase for key '/home/x/.ssh/id_rsa': " \
  ""; do
  out="$(ask "$p")"; r=$?
  if [[ $r -ne 0 && -z $out ]]; then pass "refused: ${p:-<empty prompt>}"; else fail "refused: ${p:-<empty prompt>}"; fi
done

# --- token resolution ---
env -u PRIVATE_DEPS_TOKEN "$helper" true >"$work/out" 2>"$work/err"; rc=$?
check "missing token exits non-zero" test "$rc" -ne 0
check "missing token message" \
  grep -qF "with-github-token: no token (set PRIVATE_DEPS_TOKEN or mount BuildKit secret github_token)" "$work/err"

printf '%s\n' "$canary" >"$work/secret"
got="$(env -u PRIVATE_DEPS_TOKEN PRIVATE_DEPS_SECRET_FILE="$work/secret" "$helper" bash -c '"$GIT_ASKPASS" "Password for '"'https://x-access-token@github.com'"': "')"
check "BuildKit secret file fallback" test "$got" = "$canary"

"$helper" >/dev/null 2>&1; rc=$?
check "no command exits 2" test "$rc" -eq 2

# --- exit status, stdin, cleanup ---
run bash -c 'exit 7'; check "child exit status propagated" test "$rc" -eq 7
run bash -c 'printf hello'; check "child stdout passed through" test "$(cat "$work/out")" = hello
got="$(printf 'piped' | PRIVATE_DEPS_TOKEN="$canary" "$helper" cat)"
check "stdin inherited" test "$got" = piped

run bash -c 'echo "$GIT_ASKPASS" >"$0"' "$work/askpass_path"
ap="$(cat "$work/askpass_path")"
check "askpass helper existed inside" test -n "$ap"
check "askpass removed after success" test ! -e "$ap"
check "temp dir empty after success" test -z "$(ls -A "$TMPDIR")"
run bash -c 'exit 3'
check "temp dir empty after failure" test -z "$(ls -A "$TMPDIR")"
PRIVATE_DEPS_TOKEN="$canary" "$helper" nonexistent-command-xyz >/dev/null 2>&1
check "temp dir empty after command-not-found" test -z "$(ls -A "$TMPDIR")"

# termination: the signal reaches the child and its descendants; temp dir is removed
PRIVATE_DEPS_TOKEN="$canary" "$helper" bash -c 'echo $$ >"$0"; sleep 30 & echo $! >"$1"; wait' "$work/childpid" "$work/grandchildpid" >/dev/null 2>&1 &
wpid=$!
for _ in $(seq 100); do [[ -s $work/grandchildpid ]] && break; sleep 0.1; done
cpid="$(cat "$work/childpid" 2>/dev/null || true)"
gpid="$(cat "$work/grandchildpid" 2>/dev/null || true)"
kill -TERM "$wpid"
wait "$wpid" 2>/dev/null; rc=$?
check "SIGTERM: wrapper exits non-zero" test "$rc" -ne 0
check "SIGTERM: child terminated" bash -c '! kill -0 "$1" 2>/dev/null' _ "$cpid"
sleep 0.2
check "SIGTERM: descendant terminated" bash -c '[[ -n $1 ]] && ! kill -0 "$1" 2>/dev/null' _ "$gpid"
check "SIGTERM: temp dir removed" test -z "$(ls -A "$TMPDIR")"

# --- environment handling ---
run bash -c 'printf "%s\n" "$GIT_TERMINAL_PROMPT" "$GIT_CONFIG_COUNT"'
check "GIT_TERMINAL_PROMPT=0" test "$(sed -n 1p "$work/out")" = 0
check "config entries appended (4)" test "$(sed -n 2p "$work/out")" = 4

got="$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=user.name GIT_CONFIG_VALUE_0=Preexisting PRIVATE_DEPS_TOKEN="$canary" \
  "$helper" bash -c 'git config user.name; echo "$GIT_CONFIG_COUNT"')"
check "existing GIT_CONFIG_* preserved" test "$(sed -n 1p <<<"$got")" = Preexisting
check "existing GIT_CONFIG_COUNT extended" test "$(sed -n 2p <<<"$got")" = 5

got="$(PRIVATE_DEPS_TOKEN="$canary" "$helper" git config --get-all url.https://github.com/.insteadOf)"
check "ssh scp-form rewritten" grep -qxF "git@github.com:" <<<"$got"
check "ssh:// form rewritten" grep -qxF "ssh://git@github.com/" <<<"$got"

# --- real git credential selection (offline) ---
mkdir -p "$work/bin"
cat >"$work/bin/git-credential-evil" <<'HELPER'
#!/bin/sh
[ "$1" = get ] && printf 'username=evil\npassword=evil-helper-secret\n'
exit 0
HELPER
chmod +x "$work/bin/git-credential-evil"
git config --global credential.helper "$work/bin/git-credential-evil"
git config --global credential.username preexisting
before="$(git config --global --list | sort)"

fill() { # fill <host>
  printf 'protocol=https\nhost=%s\n\n' "$1" |
    PRIVATE_DEPS_TOKEN="$canary" "$helper" git credential fill 2>"$work/err"
}
out="$(fill github.com)"
check "git credential fill: github.com gets x-access-token" grep -qx 'username=x-access-token' <<<"$out"
check "git credential fill: github.com gets the token" grep -qx "password=$canary" <<<"$out"
check "git credential fill: inherited helper bypassed" bash -c '! grep -q evil-helper-secret <<<"$1"' _ "$out"
git config --global credential.useHttpPath true
out="$(printf 'protocol=https\nhost=github.com\npath=owner/repo.git\n\n' |
  PRIVATE_DEPS_TOKEN="$canary" "$helper" git credential fill 2>"$work/err")"
check "git credential fill (useHttpPath): token supplied" grep -qx "password=$canary" <<<"$out"
check "git credential fill (useHttpPath): inherited helper bypassed" bash -c '! grep -q evil-helper-secret <<<"$1"' _ "$out"
out="$(printf 'protocol=https\nhost=github.com.evil.example\npath=owner/repo.git\n\n' |
  PRIVATE_DEPS_TOKEN="$canary" "$helper" git credential fill 2>"$work/err")"
check "git credential fill (useHttpPath): lookalike host gets no token" bash -c '! grep -qF "$2" <<<"$1"' _ "$out" "$canary"
git config --global --unset credential.useHttpPath
out="$(fill github.com.evil.example)"
check "git credential fill: lookalike host gets no token" bash -c '! grep -qF "$2" <<<"$1"' _ "$out" "$canary"
out="$(fill evil.example)"
check "git credential fill: foreign host gets no token" bash -c '! grep -qF "$2" <<<"$1"' _ "$out" "$canary"

# --- no residue, no leakage ---
check "global git config unchanged" test "$(git config --global --list | sort)" = "$before"
check "no ~/.git-credentials" test ! -e "$HOME/.git-credentials"
check "GITHUB_ENV untouched" test ! -s "$GITHUB_ENV"
run bash -c 'git config --get-all url.https://github.com/.insteadOf >/dev/null; "$GIT_ASKPASS" "Password for '"'https://x-access-token@github.com'"': " >/dev/null'
check "canary not on stdout" absent "$canary" "$work/out"
check "canary not on stderr" absent "$canary" "$work/err"
run bash -c 'cat "$GIT_ASKPASS"'
check "canary not in helper script text" absent "$canary" "$work/out"
check "canary not in any file under HOME" bash -c '! grep -rqF "$1" "$2"' _ "$canary" "$HOME"

echo
if ((fails)); then echo "$fails failure(s)"; exit 1; fi
echo "all passed"
