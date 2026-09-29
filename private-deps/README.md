# private-deps

Gives one CI step authenticated, read-only access to private GitHub git
dependencies (uv/pip and pnpm/npm git sources) without leaving the token behind
for later steps. A matching helper covers Docker BuildKit builds.

Supported: Linux and macOS runners, `github.com`. Not supported: Windows, GitHub
Enterprise Server, SSH-key auth.

## Usage

Token mode (PAT or fine-grained token with read access to the repositories):

```yaml
- uses: actions/checkout@<sha> # vX.Y.Z
  with:
    persist-credentials: false
- uses: imentiv/actions/private-deps@<sha> # v1.0.0
  with:
    token: ${{ secrets.PRIVATE_DEPS_TOKEN }}
    run: uv sync --locked
```

GitHub App mode (installation token, `contents: read` only):

```yaml
- uses: imentiv/actions/private-deps@<sha> # v1.0.0
  with:
    app-id: ${{ vars.APP_ID }}
    private-key: ${{ secrets.APP_PRIVATE_KEY }}
    owner: the-org-that-owns-the-repos
    repositories: |
      private-repo-one
      private-repo-two
    run: pnpm install --frozen-lockfile
```

Pin by full SHA with a version comment so Dependabot can bump it.

## Inputs

| Input | Description |
| --- | --- |
| `token` | PAT / fine-grained token. Mutually exclusive with `app-id`. |
| `app-id`, `private-key` | GitHub App mode. Both required together. |
| `owner` | Owner of the installation and repositories (App mode). Defaults to the **calling repository's owner**, so it must be set when the private repositories live in another org. |
| `repositories` | Newline-separated repository names. **Required in App mode**, no default; the minted token is limited to these repositories with `contents: read`. |
| `run` | Command(s) run under authentication, in this step only, as `bash -euo pipefail -c`. Optional: when empty the action only produces the `token` output. |
| `working-directory` | Directory for `run` (default `.`). |

## Outputs

| Output | Description |
| --- | --- |
| `token` | The masked token (the PAT, or the minted App token), for a BuildKit secret mount in the **same job**. Do not pass it through job outputs: GitHub drops masked values. |

## What "step-scoped" means

The token is handed to git through `GIT_ASKPASS` and exists only in the
environment of the `run` command. The action never writes git config, never
writes `~/.git-credentials`, and never writes the token to `$GITHUB_ENV`. The
wrapper sets, for the command only:

- `GIT_CONFIG_*` entries (appended after any you already set) rewriting
  `git@github.com:` and `ssh://git@github.com/` to `https://github.com/`
  (lockfiles often record git dependencies in SSH form), resetting inherited
  credential helpers (`credential.helper=`, so nothing is stored), and fixing
  the username to `x-access-token`;
- `GIT_ASKPASS`, a temp helper that answers only the `github.com` username and
  password prompts (with or without a repository path, so
  `credential.useHttpPath=true` works) and exits 1 for anything else (other hosts, lookalikes such
  as `github.com.example`, other ports). The token is never in a URL, so git
  error messages do not print it;
- `GIT_TERMINAL_PROMPT=0`.

The command runs in its own process group; if the wrapper receives `INT` or
`TERM`, the signal is sent to the whole group so no descendant outlives it
holding the token.

Afterwards a later step sees no `GIT_CONFIG_*`, no `GIT_ASKPASS`, no github.com
entry in `git config --global --list`, no `~/.git-credentials`, and nothing new
in `$GITHUB_ENV`. The `leak` job in `.github/workflows/test.yml` asserts this.

Why not `$GITHUB_ENV` or `git config --global`? Both expose the token to every
later step in the job (tests running PR code, image pushes, deploys). Wrapping
the command makes the scope a property of the action, not caller discipline.

### Threat model and limits

- The `run` command and every process it launches (including dependency
  install scripts) can read `PRIVATE_DEPS_TOKEN` while the step runs. Only run
  commands you trust with the token. Use the narrowest token you can.
- "No token for later steps" covers *ambient* env/config state. A later step in
  the same job can still read `steps.<id>.outputs.token` if the workflow passes
  it explicitly.
- The action cannot undo state that predates it: explicit `git -c` options, an
  existing `http.extraheader`, or credentials persisted by checkout. Use
  `persist-credentials: false` on `actions/checkout`.
- App tokens expire after about an hour; a longer step can outlive its token.
- Fork pull requests receive no secrets, so the action fails with an error that
  says so.

## Docker BuildKit

Dockerfiles cannot `uses:` an action. Vendor `with-github-token.sh` (a single
self-contained file) at a release tag and verify its sha256, published in the
release notes:

```dockerfile
COPY scripts/with-github-token.sh /usr/local/bin/with-github-token.sh
RUN --mount=type=secret,id=github_token,required=true \
    with-github-token.sh uv sync --locked
```

Pass the secret from a workflow using the action's output:

```yaml
- id: deps
  uses: imentiv/actions/private-deps@<sha> # v1.0.0
  with:
    token: ${{ secrets.PRIVATE_DEPS_TOKEN }}
- uses: docker/build-push-action@<sha>
  with:
    secrets: |
      github_token=${{ steps.deps.outputs.token }}
```

The helper reads `$PRIVATE_DEPS_TOKEN`, else the file `/run/secrets/github_token`
(override the path with `PRIVATE_DEPS_SECRET_FILE`). It requires `bash`, `mktemp`
and `git` in the image.

## Local use

```sh
PRIVATE_DEPS_TOKEN="$(gh auth token)" ./private-deps/with-github-token.sh uv sync
```

## Setting up a GitHub App for a caller in another org

1. Create a GitHub App (in the org that owns the private repositories) with the
   single repository permission **Contents: Read-only**, and no webhook.
2. Install it on the org, choosing **Only select repositories** and selecting
   just the repositories to read.
3. Store the App ID and generated private key as a variable and a secret in the
   caller repository (or org).
4. In the workflow set `app-id`, `private-key`, `owner` (the installing org) and
   `repositories`. The action mints a token limited to those repositories with
   `contents: read`, and revokes it when the job ends.

## Verifying a vendored helper

```sh
sha256sum private-deps/with-github-token.sh   # compare with the release notes
```

Maintainers: after tagging a release, put the helper's sha256 in the release
notes and move the major tag (`v1`).

## Tests

`private-deps/test/*.sh` are plain bash and need only `git`:
`for t in private-deps/test/*.sh; do bash "$t"; done`.
