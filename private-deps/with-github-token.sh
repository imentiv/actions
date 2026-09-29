#!/usr/bin/env bash
# Run a command with step-scoped, read-only git authentication for github.com.
#
#   with-github-token.sh <command> [args...]
#
# The token is taken from $PRIVATE_DEPS_TOKEN, else from the BuildKit secret
# file (default /run/secrets/github_token, override with
# $PRIVATE_DEPS_SECRET_FILE). It is handed to git through GIT_ASKPASS, so it is
# never placed in a URL or written to any git config file. All state lives in
# the environment of the child command and a temp directory removed on exit.
set -euo pipefail

if (($# == 0)); then
  echo "usage: with-github-token.sh <command> [args...]" >&2
  exit 2
fi

token="${PRIVATE_DEPS_TOKEN:-}"
if [[ -z $token ]]; then
  secret_file="${PRIVATE_DEPS_SECRET_FILE:-/run/secrets/github_token}"
  if [[ -r $secret_file ]]; then
    token="$(<"$secret_file")"
  fi
fi
if [[ -z $token ]]; then
  echo "with-github-token: no token (set PRIVATE_DEPS_TOKEN or mount BuildKit secret github_token)" >&2
  exit 1
fi
export PRIVATE_DEPS_TOKEN="$token"
unset token

tmp="$(mktemp -d "${TMPDIR:-/tmp}/with-github-token.XXXXXX")"
child=""
# shellcheck disable=SC2317,SC2329  # invoked via trap
cleanup() { rm -rf "$tmp"; }
# The child leads its own process group (set -m below), so a signal reaches
# everything it spawned, not just the direct child.
# shellcheck disable=SC2317,SC2329  # invoked via trap
forward() {
  if [[ -n $child ]]; then kill -TERM -- "-$child" 2>/dev/null || true; fi
}
trap cleanup EXIT
trap forward INT TERM

# The scheme and authority are matched exactly and must be followed by "/" or
# the closing quote, so lookalike hosts such as github.com.evil.example or
# github.com:8443 are refused. A path may follow the host (credential.useHttpPath).
cat >"$tmp/askpass" <<'ASKPASS'
#!/bin/sh
case "$1" in
  "Username for 'https://github.com'" | "Username for 'https://github.com':" | "Username for 'https://github.com': " | \
  "Username for 'https://github.com/"*"'" | "Username for 'https://github.com/"*"':" | "Username for 'https://github.com/"*"': ")
    printf '%s\n' x-access-token ;;
  "Password for 'https://x-access-token@github.com'" | "Password for 'https://x-access-token@github.com':" | "Password for 'https://x-access-token@github.com': " | \
  "Password for 'https://x-access-token@github.com/"*"'" | "Password for 'https://x-access-token@github.com/"*"':" | "Password for 'https://x-access-token@github.com/"*"': " | \
  "Password for 'https://github.com'" | "Password for 'https://github.com':" | "Password for 'https://github.com': " | \
  "Password for 'https://github.com/"*"'" | "Password for 'https://github.com/"*"':" | "Password for 'https://github.com/"*"': ")
    printf '%s\n' "$PRIVATE_DEPS_TOKEN" ;;
  *) exit 1 ;;
esac
ASKPASS
chmod 700 "$tmp/askpass"

# Append to, never clobber, any GIT_CONFIG_* the caller already set.
n="${GIT_CONFIG_COUNT:-0}"
[[ $n =~ ^[0-9]+$ ]] || n=0
add_config() {
  export "GIT_CONFIG_KEY_$n=$1" "GIT_CONFIG_VALUE_$n=$2"
  n=$((n + 1))
}
add_config url.https://github.com/.insteadOf "git@github.com:"
add_config url.https://github.com/.insteadOf "ssh://git@github.com/"
# Reset inherited credential helpers so git asks us and nothing is stored.
add_config credential.helper ""
add_config credential.https://github.com.username x-access-token
export GIT_CONFIG_COUNT="$n"
export GIT_ASKPASS="$tmp/askpass"
export GIT_TERMINAL_PROMPT=0

# Run as a child (not exec) so the EXIT trap can remove the helper. Job
# control puts it in its own process group so signals can reach descendants.
set -m
"$@" <&0 &
child=$!
rc=0
wait "$child" || rc=$?
# A forwarded signal interrupts the first wait; reap the child for its status.
while kill -0 "$child" 2>/dev/null; do
  wait "$child" || rc=$?
done
exit "$rc"
