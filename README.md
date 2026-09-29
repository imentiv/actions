# actions

Public GitHub composite actions for Imentiv repos (no secrets; callers pass their own tokens).

## Public-safe code only

This repository is public. It holds **only public-safe code**: no secrets, no
internal repository names, no vendor endpoints, no internal hostnames. Callers
supply their own credentials as inputs. Keep it that way in code, commit
messages, issues, and pull requests.

## Actions

| Action | Purpose |
| --- | --- |
| [`private-deps`](private-deps/README.md) | Step-scoped, read-only git auth for private GitHub git dependencies (PAT or GitHub App token), plus a helper for Docker BuildKit builds. |

## Development

CI runs `actionlint`, `shellcheck`, and every `*/test/*.sh` on each pull request.
Third-party actions are pinned by full commit SHA.
