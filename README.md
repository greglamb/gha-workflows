# gha-workflows

Reusable GitHub Actions workflows and bootstrap tooling for setting them up across repos.

Pin to a tag for stability — for example, `@v0.2605.0501`. Use `@main` only during initial rollout. See [Versioning](#versioning) for how releases are produced.

## Workflows

### `lib-security-review.yml` — Security scanning

Runs SAST, SCA, filesystem, and secret-history scans, uploading SARIF results to GitHub's code scanning UI.

| Job | Tool | Purpose |
|---|---|---|
| `semgrep` | [Semgrep](https://semgrep.dev/) | Static analysis (SAST) |
| `osv-scanner` | [OSV-Scanner](https://google.github.io/osv-scanner/) | Dependency vulnerabilities (SCA) |
| `trivy` | [Trivy](https://trivy.dev/) | Filesystem + IaC + secrets |
| `gitleaks` | [Gitleaks](https://github.com/gitleaks/gitleaks) | Secrets in git history |

#### Inputs

| Input | Type | Default | Description |
|---|---|---|---|
| `semgrep-extra-rules` | string | `""` | Extra Semgrep rule packs (e.g. `p/python p/django`) |
| `trivy-severity` | string | `CRITICAL,HIGH,MEDIUM` | Comma-separated Trivy severity levels |
| `enable-gitleaks` | boolean | `true` | Run gitleaks. Disable for org private repos without a license. |

#### Permissions

```yaml
permissions:
  contents: read
  security-events: write   # required to upload SARIF
  actions: read
  pull-requests: read
```

#### Example caller

```yaml
name: Security
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
  schedule:
    - cron: '0 6 * * 1'
  workflow_dispatch:

permissions:
  contents: read
  security-events: write
  actions: read
  pull-requests: read

jobs:
  security:
    uses: greglamb/gha-workflows/.github/workflows/lib-security-review.yml@v0.2605.0501
    permissions:
      contents: read
      security-events: write
      actions: read
      pull-requests: read
```

A ready-to-copy version lives at [`examples/security-review.yml`](examples/security-review.yml).

---

### `lib-sync-remote-branch.yml` — Mirror a remote branch

Mirrors a branch from an external repo into a target branch in this repo. Useful for tracking upstream projects, vendoring dependencies, or maintaining forks.

**What it does:**

1. Fetches the source ref from the remote repository
2. Force-pushes it to a target branch in your repo
3. Optionally renames, deletes, or keeps any `.github/workflows/*.yml` files from upstream
4. Optionally opens (or updates) a PR from the sync branch

#### Inputs

| Input | Type | Required | Default | Description |
|---|---|---|---|---|
| `source_repo` | string | yes | — | Git URL of the source repository |
| `source_ref` | string | yes | `main` | Branch, tag, or ref to mirror |
| `target_ref` | string | yes | `upstream` | Target branch name (created or overwritten) |
| `disable_workflows` | string | no | `rename` | How to handle upstream workflows: `rename`, `delete`, or `keep` |
| `rename_dir` | string | no | `.github/workflows-upstream` | Where to move renamed workflows |
| `create_pr` | boolean | no | `false` | Auto-create a PR after syncing |
| `pr_base` | string | no | `main` | Base branch for the auto-created PR |

#### Permissions

```yaml
permissions:
  contents: write
  pull-requests: write   # only if create_pr is true
```

#### Example caller

```yaml
name: Sync upstream
on:
  schedule:
    - cron: "0 2 * * 1"
  workflow_dispatch:

jobs:
  sync:
    uses: greglamb/gha-workflows/.github/workflows/lib-sync-remote-branch.yml@v0.2605.0501
    with:
      source_repo: https://github.com/org/repo.git
      source_ref: main
      target_ref: upstream/org
      disable_workflows: rename
      create_pr: true
    permissions:
      contents: write
      pull-requests: write
```

#### Workflow handling modes

- **`rename`** (default) — Moves upstream workflow files to `.github/workflows-upstream/` (or custom `rename_dir`) so they don't execute but remain available for reference.
- **`delete`** — Removes all upstream workflow files from the mirrored branch.
- **`keep`** — Leaves workflow files untouched. Use with caution — upstream workflows will run in your repo.

## Bootstrap tools

Scripts under [`tools/`](tools/) wire these workflows into a target repo. Run from inside the repo you want to set up. Both are idempotent.

### `bootstrap-security.sh`

Sets up the security workflow plus repo-level hygiene:

- Detects package ecosystems and writes `.github/dependabot.yml`
- Drops a caller stub at `.github/workflows/security.yml` that calls `lib-security-review.yml`
- Enables Dependabot alerts, Dependabot security updates, secret scanning, and push protection via the GitHub API
- Optionally applies branch protection on the default branch

```sh
# from inside the target repo
/path/to/gha-workflows/tools/bootstrap-security.sh \
  --workflow-ref v0.2605.0501 \
  --branch-protection
```

Useful flags: `--workflow-repo`, `--workflow-ref`, `--no-dependabot`, `--no-workflow`, `--no-settings`, `--branch-protection`, `--force`, `--dry-run`. Requires `gh` (authenticated) and `git`.

### `bootstrap-sync-remote-branch.sh`

Sets up upstream-mirror tracking for a private fork or vendored upstream:

- Adds a git remote pointing at the upstream URL
- Generates a caller workflow at `.github/workflows/sync-upstream.yml`
- Two modes:
  - `inline` (default) — downloads `lib-sync-remote-branch.yml` into the repo, no runtime dependency on this repo
  - `caller` — thin caller referencing `greglamb/gha-workflows@<ref>`, picks up upstream changes automatically

```sh
# from inside the target repo
/path/to/gha-workflows/tools/bootstrap-sync-remote-branch.sh \
  https://github.com/org/repo.git \
  --sync-branch upstream-org-repo \
  --auto-pr \
  --cron "0 6 * * 1"
```

Useful flags: `--mode`, `--branch`, `--sync-branch`, `--cron`, `--remote-name`, `--disable-workflows`, `--rename-dir`, `--workflows-repo`, `--caller-ref`, `--auto-pr`, `--pr-base`, `--dry-run`, `--update`, `--force`, `--no-remote`, `--no-workflow`.

## Versioning

This repo uses CalVer (`0.YYMM.DDBB`) tracked in `package.json`. Releases are tagged automatically by git hooks:

- **`.githooks/pre-commit`** — when staged changes touch `.github/workflows/`, bumps the version in `package.json` via [`shared/bumpCalver.sh`](shared/bumpCalver.sh) and re-stages it.
- **`.githooks/post-commit`** — if `package.json` changed in HEAD, creates a `v<version>` tag pointing at HEAD. Skips during rebase, cherry-pick, and merge.

Tags need an explicit push: `git push --tags` (or `git push --follow-tags`).

### Setup for contributors

After cloning, run once:

```sh
npm install
```

The `postinstall` script sets `core.hooksPath` to `.githooks` so the hooks are active. `jq` is required for the bump script (`brew install jq` / `apt install jq`).

To bump manually without a workflow change:

```sh
shared/bumpCalver.sh package.json version
```

## License

[MIT](LICENSE)
