# gha-workflows

Reusable GitHub Actions workflows.

## Workflows

### Sync Branch to Remote

Mirrors a branch from an external repository into a local branch. Useful for tracking upstream projects, vendoring dependencies, or maintaining forks.

```
greglamb/gha-workflows/.github/workflows/sync-branch-to-remote.yml@main
```

**What it does:**

1. Fetches the source ref from a remote repository
2. Force-pushes it to a target branch in your repo
3. Optionally handles upstream workflow files (rename, delete, or keep)
4. Optionally creates a PR from the sync branch

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

The calling workflow must grant:

```yaml
permissions:
  contents: write
  pull-requests: write  # only if using create_pr
```

#### Example

```yaml
name: Sync upstream

on:
  schedule:
    - cron: "0 2 * * 1"  # weekly on Monday at 2 AM UTC
  workflow_dispatch:
    inputs:
      source_repo:
        description: "Git URL of source repo"
        required: true
        default: "https://github.com/org/repo.git"

jobs:
  sync:
    uses: greglamb/gha-workflows/.github/workflows/sync-branch-to-remote.yml@main
    with:
      source_repo: ${{ inputs.source_repo || 'https://github.com/org/repo.git' }}
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

## License

[MIT](LICENSE)
