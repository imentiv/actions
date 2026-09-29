#!/usr/bin/env bash
# Validate private-deps inputs. Reads TOKEN, APP_ID, PRIVATE_KEY, REPOSITORIES
# from the environment; prints ::error:: annotations and exits 1 on problems.
# Values are never printed, only input names.
set -euo pipefail

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  printf '%s' "${s%"${s##*[![:space:]]}"}"
}

token="$(trim "${TOKEN:-}")"
app_id="$(trim "${APP_ID:-}")"
private_key="$(trim "${PRIVATE_KEY:-}")"
repositories="$(trim "${REPOSITORIES:-}")"
fork_note="Secrets are not available to workflows triggered by pull requests from forks."

fail() {
  echo "::error::private-deps: $*"
  exit 1
}

if [[ -n $token && ( -n $app_id || -n $private_key ) ]]; then
  fail "'token' is mutually exclusive with 'app-id'/'private-key'; set one mode only."
fi

if [[ -n $token ]]; then
  exit 0
fi

if [[ -z $app_id && -z $private_key ]]; then
  fail "no credentials: set 'token', or 'app-id' and 'private-key'. If the value comes from a secret it is empty. $fork_note"
fi
[[ -n $app_id ]] || fail "'app-id' is empty (App mode needs both 'app-id' and 'private-key'). $fork_note"
[[ -n $private_key ]] || fail "'private-key' is empty (App mode needs both 'app-id' and 'private-key'). $fork_note"
[[ -n $repositories ]] || fail "'repositories' is required in App mode (least privilege); list the repositories to grant contents:read on."
