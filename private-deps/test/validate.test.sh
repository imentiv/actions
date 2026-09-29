#!/usr/bin/env bash
# Tests for validate-inputs.sh: every input combination and error text.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
v="$here/../validate-inputs.sh"
fails=0

# expect <name> <rc> <output-substring> [VAR=val...]
expect() {
  local name="$1" want_rc="$2" want_msg="$3"; shift 3
  local out rc
  out="$(env -i PATH="$PATH" "$@" "$v" 2>&1)"; rc=$?
  if [[ $rc -eq $want_rc && $out == *"$want_msg"* ]] &&
     { [[ $want_rc -eq 0 && -z $out ]] || [[ $want_rc -ne 0 && $out == "::error::"* ]]; }; then
    echo "ok   - $name"
  else
    echo "FAIL - $name (rc=$rc out=$out)"; fails=$((fails + 1))
  fi
}

expect "token only" 0 "" TOKEN=abc
expect "app mode complete" 0 "" APP_ID=123 PRIVATE_KEY=key REPOSITORIES=$'repo-a\nrepo-b'
expect "app mode with owner" 0 "" APP_ID=123 PRIVATE_KEY=key REPOSITORIES=repo-a OWNER=other-org
expect "nothing set" 1 "no credentials"
expect "nothing set mentions forks" 1 "forks"
expect "whitespace token is empty" 1 "no credentials" TOKEN=$'  \n'
expect "token + app-id" 1 "mutually exclusive" TOKEN=abc APP_ID=1 PRIVATE_KEY=k REPOSITORIES=r
expect "token + private-key" 1 "mutually exclusive" TOKEN=abc PRIVATE_KEY=k
expect "token + app-id only" 1 "mutually exclusive" TOKEN=abc APP_ID=1
expect "app-id without key" 1 "'private-key' is empty" APP_ID=1 REPOSITORIES=r
expect "app-id without key mentions forks" 1 "forks" APP_ID=1 REPOSITORIES=r
expect "key without app-id" 1 "'app-id' is empty" PRIVATE_KEY=k REPOSITORIES=r
expect "app mode missing repositories" 1 "'repositories' is required" APP_ID=1 PRIVATE_KEY=k
expect "app mode whitespace repositories" 1 "'repositories' is required" APP_ID=1 PRIVATE_KEY=k REPOSITORIES=$' \n\t\n'

out="$(env -i PATH="$PATH" TOKEN=SECRETVALUE APP_ID=1 PRIVATE_KEY=KEYVALUE "$v" 2>&1)"
if [[ $out != *SECRETVALUE* && $out != *KEYVALUE* ]]; then
  echo "ok   - error output has no values"
else
  echo "FAIL - error output leaks values"; fails=$((fails + 1))
fi

echo
if ((fails)); then echo "$fails failure(s)"; exit 1; fi
echo "all passed"
