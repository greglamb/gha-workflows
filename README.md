# gha-workflows

Reusable GitHub Actions workflows and bootstrap tooling for setting them up across repos.

Pin to a tag for stability — see [Releases](https://github.com/greglamb/gha-workflows/releases) for the current latest. Examples below use `@<latest>` as a placeholder; substitute the actual tag. Use `@main` only during initial rollout. See [Versioning](#versioning) for how releases are produced.

## Workflows

### `lib-security-review.yml` — Security scanning

Runs SAST, SCA, filesystem, and secret scans. Uploads SARIF to the Code Scanning UI when available (requires public repo or GitHub Advanced Security) and **always** archives SARIF as workflow artifacts. A final `summary` job aggregates findings into a markdown table on the workflow run page — useful for private repos without GHAS.

| Job | Tool | Purpose |
|---|---|---|
| `opengrep` | [OpenGrep](https://github.com/opengrep/opengrep) | SAST — LGPL fork of Semgrep CE; restores cross-function taint analysis |
| `opengrep-generic` | OpenGrep (generic mode) | SAST for languages OpenGrep doesn't natively parse — opt-in via `opengrep-generic-rules` |
| `osv-scanner` | [OSV-Scanner](https://google.github.io/osv-scanner/) | Dependency vulnerabilities (SCA) |
| `trivy` | [Trivy](https://trivy.dev/) | Filesystem + IaC + secrets |
| `trufflehog-diff` | [TruffleHog](https://github.com/trufflesecurity/trufflehog) | Verified secrets, PR-diff mode (PRs only) |
| `trufflehog-history` | TruffleHog | Verified secrets, full git history (push/schedule) |
| `summary` | — | Aggregates SARIF findings into a markdown summary on the run page |

#### Inputs

| Input | Type | Default | Description |
|---|---|---|---|
| `runner-os` | string | `ubuntu-24.04` | GitHub-hosted runner image. Pin explicitly; do not use `ubuntu-latest`. |
| `opengrep-version` | string | `v1.16.0` | OpenGrep release tag. The install script is also pinned to this tag. |
| `rules-ref` | string | `main` | Git ref of `semgrep/semgrep-rules`. Pin to a SHA in callers needing reproducibility. |
| `opengrep-extra-configs` | string | `""` | Space-separated extra rule paths/files in the consuming repo (e.g. `./security/rules ./opengrep/cfml.yml`) |
| `opengrep-generic-rules` | string | `""` | Space-separated paths to YAML rules using OpenGrep's generic mode. Empty disables. |
| `trivy-severity` | string | `CRITICAL,HIGH,MEDIUM` | Comma-separated Trivy severity levels |
| `enable-trufflehog` | boolean | `true` | Run TruffleHog secret verification scans |

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
    uses: greglamb/gha-workflows/.github/workflows/lib-security-review.yml@<latest>
    permissions:
      contents: read
      security-events: write
      actions: read
      pull-requests: read
    # Optional overrides:
    # with:
    #   runner-os: "ubuntu-24.04"
    #   opengrep-version: "v1.16.0"
    #   rules-ref: "<sha>"                 # semgrep-rules SHA for reproducibility
    #   opengrep-extra-configs: "./security/rules"
    #   opengrep-generic-rules: "./opengrep/generic"
    #   trivy-severity: "CRITICAL,HIGH"
    #   enable-trufflehog: false
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
    uses: greglamb/gha-workflows/.github/workflows/lib-sync-remote-branch.yml@<latest>
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

A ready-to-copy version lives at [`examples/sync-upstream.yml`](examples/sync-upstream.yml).

#### Workflow handling modes

- **`rename`** (default) — Moves upstream workflow files to `.github/workflows-upstream/` (or custom `rename_dir`) so they don't execute but remain available for reference.
- **`delete`** — Removes all upstream workflow files from the mirrored branch.
- **`keep`** — Leaves workflow files untouched. Use with caution — upstream workflows will run in your repo.

## Bootstrap tools

Scripts under [`tools/`](tools/) wire these workflows into a target repo. Run from inside the repo you want to set up. Both are idempotent — re-running skips files that already exist (use `--force` to overwrite). Both auto-resolve the workflow pin to the latest release of `greglamb/gha-workflows` via `gh` if you don't pass `--workflow-ref` / `--caller-ref` explicitly.

Both support two strategies:

- **`caller`** (default) — generated stub references `greglamb/gha-workflows/.github/workflows/<lib>.yml@<ref>`. Smaller footprint; picks up upstream changes when you bump the pin.
- **`inline`** — downloads the reusable workflow into the consumer's `.github/workflows/`. Self-contained; no runtime dependency on this repo.

### `bootstrap-security.sh`

Sets up the security workflow plus repo-level hygiene:

- Detects package ecosystems and writes `.github/dependabot.yml`
- Drops a caller stub at `.github/workflows/security.yml` that calls `lib-security-review.yml`
- Enables Dependabot alerts, Dependabot security updates, secret scanning, and push protection via the GitHub API
- Runs [`shared/setup-gitleaks.sh`](shared/setup-gitleaks.sh) to install a local `pre-commit` gitleaks hook (gitleaks runs locally only — not in CI)
- Optionally applies branch protection on the default branch

```sh
# from inside the target repo
/path/to/gha-workflows/tools/bootstrap-security.sh --branch-protection
```

Useful flags: `--mode inline|caller`, `--workflow-repo`, `--workflow-ref`, `--no-dependabot`, `--no-workflow`, `--no-settings`, `--no-gitleaks`, `--branch-protection`, `--force`, `--dry-run`. Requires `gh` (authenticated) and `git`.

### `bootstrap-sync-remote-branch.sh`

Sets up upstream-mirror tracking for a private fork or vendored upstream:

- Adds a git remote pointing at the upstream URL
- Generates a caller workflow at `.github/workflows/sync-upstream.yml`
- In `inline` mode, also downloads `lib-sync-remote-branch.yml` into the consumer's repo

```sh
# from inside the target repo
/path/to/gha-workflows/tools/bootstrap-sync-remote-branch.sh \
  https://github.com/org/repo.git \
  --sync-branch upstream-org-repo \
  --auto-pr \
  --cron "0 6 * * 1"
```

Useful flags: `--mode inline|caller`, `--branch`, `--sync-branch`, `--cron`, `--remote-name`, `--disable-workflows`, `--rename-dir`, `--workflows-repo`, `--caller-ref`, `--auto-pr`, `--pr-base`, `--dry-run`, `--update`, `--force`, `--no-remote`, `--no-workflow`.

## Versioning

This repo uses CalVer (`0.YYMM.DDBB`) tracked in `package.json`. Releases are tagged automatically by git hooks:

- **`.githooks/pre-commit`** — when staged changes touch `.github/workflows/`, bumps the version in `package.json` via [`shared/bumpCalver.sh`](shared/bumpCalver.sh) and re-stages it.
- **`.githooks/post-commit`** — if `package.json`'s `version` field differs between HEAD and HEAD~1, creates an annotated `v<version>` tag pointing at HEAD. After `git commit --amend`, the tag is force-moved to the new HEAD. Skips during rebase, cherry-pick, and merge.

Tags publish automatically with `git push --follow-tags` since they're annotated.

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
