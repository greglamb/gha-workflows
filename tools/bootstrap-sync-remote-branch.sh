#!/usr/bin/env bash
set -euo pipefail

# Defaults
BRANCH="main"
SYNC_BRANCH="upstream-sync"
CRON=""
REMOTE_NAME="upstream"
MODE="caller"
CALLER_REF=""  # Resolved to latest release via gh if empty after arg parsing
WORKFLOWS_REPO="greglamb/gha-workflows"
REUSABLE_WORKFLOW=".github/workflows/lib-sync-remote-branch.yml"
DISABLE_WORKFLOWS="rename"
RENAME_DIR=".github/workflows-upstream"
AUTO_PR=false
PR_BASE="main"
NO_REMOTE=false
NO_WORKFLOW=false
DRY_RUN=false
UPDATE=false
FORCE=false
UPSTREAM_URL=""

# Track explicit overrides for summary display
_SET_MODE=false _SET_BRANCH=false _SET_SYNC_BRANCH=false _SET_CRON=false
_SET_REMOTE_NAME=false _SET_WORKFLOWS_REPO=false _SET_CALLER_REF=false
_SET_DISABLE_WF=false _SET_RENAME_DIR=false _SET_AUTO_PR=false _SET_PR_BASE=false

usage() {
  local self
  self="$(basename "$0")"
  cat <<EOF
${self} — set up GitHub Actions upstream sync for private repo mirrors

Usage: ${self} <upstream-url> [options]

Syncs a public upstream repo into a dedicated branch in your private repo.
Adds a git remote and generates a GitHub Actions workflow. PR from the
sync branch into main to review changes on your terms.

Options:
  -m, --mode <inline|caller>           Workflow strategy (default: caller)
  -b, --branch <name>                  Upstream branch to track (default: main)
  -s, --sync-branch <name>             Local sync branch (default: upstream-sync)
  -c, --cron <expr>                    Cron schedule (default: off, dispatch only)
  -r, --remote-name <name>             Git remote name (default: upstream)
  -d, --disable-workflows <mode>       rename|delete|keep (default: rename)
  --rename-dir <path>                  Rename destination (default: .github/workflows-upstream)
  --workflows-repo <owner/repo>        Reusable workflow source (default: greglamb/gha-workflows)
  --caller-ref <ref>                   Workflow repo ref (default: latest release via gh)
  --auto-pr                            Auto-create PR after sync (default: off)
  --pr-base <branch>                   PR target branch (default: main)
  --dry-run                            Preview output without writing files
  --update                             Re-download reusable workflow only (inline mode)
  --force                              Overwrite existing files
  --no-remote                          Skip adding git remote
  --no-workflow                        Skip creating workflow file
  -h, --help                           Show this help

Modes:
  caller   (default) Thin caller to remote reusable workflow at
           <workflows-repo>@<ref>. Smaller footprint, auto-picks up upstream
           workflow changes when the pin is bumped.
  inline   Downloads lib-sync-remote-branch.yml into the repo. Self-contained,
           no external dependency at runtime. Update with --update --force.

Caller ref resolution:
  When --caller-ref is omitted, the script queries GitHub for the latest
  release of <workflows-repo> using \`gh\`. Requires \`gh\` to be installed
  and authenticated. Pass --caller-ref explicitly to skip the lookup.

Environment:
  GH_TOKEN / GITHUB_TOKEN   Authenticates private repo downloads (inline mode)

Examples:
  ${self} https://github.com/ZStud/reef.git -s upstream-ZStud-reef
  ${self} https://github.com/org/repo.git -m caller -c "0 6 * * 1"
  ${self} https://github.com/org/repo.git --auto-pr --pr-base develop
  ${self} https://github.com/org/repo.git -d delete
  ${self} https://github.com/org/repo.git --dry-run
  ${self} https://github.com/org/repo.git --update --force
  ${self} https://github.com/org/repo.git --workflows-repo myorg/wf --caller-ref main
EOF
}

# Look up the latest release tag of WORKFLOWS_REPO via gh.
# Prefers `gh release view` (GitHub Releases). Falls back to the highest
# CalVer-shaped tag (v0.YYMM.DDBB) if no Releases exist. Returns empty on
# any failure — caller is responsible for surfacing a clear error.
fetch_latest_ref() {
  local repo="$1"
  command -v gh >/dev/null 2>&1 || return 0
  local ref
  ref=$(gh release view --repo "$repo" --json tagName -q .tagName 2>/dev/null || true)
  if [[ -n "$ref" ]]; then
    echo "$ref"
    return 0
  fi
  ref=$(gh api --paginate "/repos/$repo/tags" --jq '.[].name' 2>/dev/null \
    | grep -E '^v0\.[0-9]{4}\.[0-9]+$' \
    | sort -V \
    | tail -1)
  [[ -n "$ref" ]] && echo "$ref"
}

# --- Workflow generators ---

generate_caller_workflow() {
  local uses_path="$1"  # remote or local path
  local pr_inputs=""
  local pr_with=""
  local schedule_block=""

  if [[ "$AUTO_PR" == true ]]; then
    # Each block starts with a leading newline so it appends cleanly after
    # the prior line's content; empty values inject nothing.
    pr_inputs=$'\n'"      create_pr:
        description: \"Auto-create PR from sync branch into pr_base\"
        required: false
        type: boolean
        default: true
      pr_base:
        description: \"Base branch for auto-created PR\"
        required: false
        default: \"${PR_BASE}\""
    pr_with=$'\n'"      create_pr: \${{ inputs.create_pr == '' && true || inputs.create_pr }}
      pr_base: \${{ inputs.pr_base || '${PR_BASE}' }}"
  fi

  if [[ -n "$CRON" ]]; then
    schedule_block=$'\n'"  schedule:
    - cron: '${CRON}'"
  fi

  cat <<YAML
name: Sync Upstream

on:
  workflow_dispatch:
    inputs:
      source_repo:
        description: "Git URL of source repo"
        required: true
        default: "${UPSTREAM_URL}"
      source_ref:
        description: "Source branch or ref to mirror"
        required: true
        default: "${BRANCH}"
      target_ref:
        description: "Target branch (created/overwritten)"
        required: true
        default: "${SYNC_BRANCH}"
      disable_workflows:
        description: "How to handle upstream workflows: rename, delete, or keep"
        required: true
        type: choice
        options:
          - rename
          - delete
          - keep
        default: "${DISABLE_WORKFLOWS}"
      rename_dir:
        description: "Destination directory for renamed workflows (rename mode only)"
        required: false
        default: "${RENAME_DIR}"${pr_inputs}${schedule_block}

permissions:
  contents: write
  pull-requests: write

jobs:
  call-sync:
    uses: ${uses_path}
    with:
      source_repo: \${{ inputs.source_repo || '${UPSTREAM_URL}' }}
      source_ref: \${{ inputs.source_ref || '${BRANCH}' }}
      target_ref: \${{ inputs.target_ref || '${SYNC_BRANCH}' }}
      disable_workflows: \${{ inputs.disable_workflows || '${DISABLE_WORKFLOWS}' }}
      rename_dir: \${{ inputs.rename_dir || '${RENAME_DIR}' }}${pr_with}
YAML
}

download_reusable_workflow() {
  local raw_url="https://raw.githubusercontent.com/${WORKFLOWS_REPO}/${CALLER_REF}/${REUSABLE_WORKFLOW}"
  local dest=".github/workflows/$(basename "$REUSABLE_WORKFLOW")"

  if [[ "$DRY_RUN" == true ]]; then
    echo "# [dry-run] Would download: $raw_url"
    echo "# [dry-run] To: $dest"
    return 0
  fi

  if [[ -f "$dest" && "$FORCE" == false ]]; then
    echo "⏭  $dest already exists — skipping (use --force to overwrite)."
    return 0
  fi

  # Build curl auth header if token is available
  local auth_header=()
  local token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  if [[ -n "$token" ]]; then
    auth_header=(-H "Authorization: token ${token}")
    echo "⬇  Downloading reusable workflow from ${WORKFLOWS_REPO}@${CALLER_REF} (authenticated)..."
  else
    echo "⬇  Downloading reusable workflow from ${WORKFLOWS_REPO}@${CALLER_REF}..."
  fi

  local http_code
  http_code=$(curl -sL "${auth_header[@]+"${auth_header[@]}"}" -w "%{http_code}" -o /tmp/_ghpss_reusable.yml "$raw_url")

  if [[ "$http_code" != "200" ]]; then
    echo "Error: Failed to download workflow (HTTP $http_code)" >&2
    echo "  URL: $raw_url" >&2
    if [[ -z "$token" ]]; then
      echo "  Hint: Set GH_TOKEN or GITHUB_TOKEN for private repo access." >&2
    fi
    exit 1
  fi

  mkdir -p "$(dirname "$dest")"
  mv /tmp/_ghpss_reusable.yml "$dest"
  echo "✓ Downloaded $(basename "$dest") → $dest"
}

# --- Main ---

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--mode)                MODE="$2"; _SET_MODE=true; shift 2 ;;
    -b|--branch)              BRANCH="$2"; _SET_BRANCH=true; shift 2 ;;
    -s|--sync-branch)         SYNC_BRANCH="$2"; _SET_SYNC_BRANCH=true; shift 2 ;;
    -c|--cron)                CRON="$2"; _SET_CRON=true; shift 2 ;;
    -r|--remote-name)         REMOTE_NAME="$2"; _SET_REMOTE_NAME=true; shift 2 ;;
    --workflows-repo)         WORKFLOWS_REPO="$2"; _SET_WORKFLOWS_REPO=true; shift 2 ;;
    --caller-ref)             CALLER_REF="$2"; _SET_CALLER_REF=true; shift 2 ;;
    -d|--disable-workflows)   DISABLE_WORKFLOWS="$2"; _SET_DISABLE_WF=true; shift 2 ;;
    --rename-dir)             RENAME_DIR="$2"; _SET_RENAME_DIR=true; shift 2 ;;
    --auto-pr)                AUTO_PR=true; _SET_AUTO_PR=true; shift ;;
    --pr-base)                PR_BASE="$2"; _SET_PR_BASE=true; shift 2 ;;
    --no-remote)              NO_REMOTE=true; shift ;;
    --no-workflow)            NO_WORKFLOW=true; shift ;;
    --dry-run)                DRY_RUN=true; shift ;;
    --update)                 UPDATE=true; shift ;;
    --force)                  FORCE=true; shift ;;
    -h|--help)                usage; exit 0 ;;
    -*)                       echo "Unknown option: $1" >&2; usage; exit 1 ;;
    *)
      if [[ -z "$UPSTREAM_URL" ]]; then
        UPSTREAM_URL="$1"; shift
      else
        echo "Unexpected argument: $1" >&2; usage; exit 1
      fi
      ;;
  esac
done

if [[ -z "$UPSTREAM_URL" ]]; then
  usage
  exit 1
fi

if [[ "$MODE" != "inline" && "$MODE" != "caller" ]]; then
  echo "Error: --mode must be 'inline' or 'caller'." >&2
  exit 1
fi

if [[ "$DISABLE_WORKFLOWS" != "rename" && "$DISABLE_WORKFLOWS" != "delete" && "$DISABLE_WORKFLOWS" != "keep" ]]; then
  echo "Error: --disable-workflows must be 'rename', 'delete', or 'keep'." >&2
  exit 1
fi

if [[ "$UPDATE" == true && "$MODE" != "inline" ]]; then
  echo "Error: --update only works with --mode inline." >&2
  exit 1
fi

if [[ ! -d .git && "$DRY_RUN" == false ]]; then
  echo "Error: Not a git repository. Run this from your repo root." >&2
  exit 1
fi

# Resolve CALLER_REF if user didn't pin one explicitly.
if [[ -z "$CALLER_REF" ]]; then
  CALLER_REF=$(fetch_latest_ref "$WORKFLOWS_REPO" || true)
  if [[ -z "$CALLER_REF" ]]; then
    echo "Error: could not resolve latest release of $WORKFLOWS_REPO via gh." >&2
    echo "  Hint: install/authenticate gh, or pass --caller-ref <tag> explicitly." >&2
    exit 1
  fi
  echo "ℹ  Resolved --caller-ref to latest release: $CALLER_REF"
fi

# --update implies --no-remote and skips caller generation
if [[ "$UPDATE" == true ]]; then
  NO_REMOTE=true
fi

# Add remote
if [[ "$NO_REMOTE" == false && "$DRY_RUN" == false ]]; then
  if git remote | grep -qx "$REMOTE_NAME"; then
    echo "⏭  Remote \"$REMOTE_NAME\" already exists — skipping."
  else
    git remote add "$REMOTE_NAME" "$UPSTREAM_URL"
    echo "✓ Added remote \"$REMOTE_NAME\" → $UPSTREAM_URL"
  fi
elif [[ "$NO_REMOTE" == false && "$DRY_RUN" == true ]]; then
  echo "# [dry-run] Would add remote \"$REMOTE_NAME\" → $UPSTREAM_URL"
fi

# --update: only re-download the reusable workflow
if [[ "$UPDATE" == true ]]; then
  download_reusable_workflow
  echo ""
  echo "✓ Updated reusable workflow from $WORKFLOWS_REPO@$CALLER_REF"
  exit 0
fi

# Create workflow
if [[ "$NO_WORKFLOW" == false ]]; then
  WORKFLOW_DIR=".github/workflows"
  WORKFLOW_FILE="$WORKFLOW_DIR/sync-upstream.yml"

  # Determine uses path
  local_uses_path=""
  if [[ "$MODE" == "inline" ]]; then
    local_uses_path="./${REUSABLE_WORKFLOW}"
  else
    local_uses_path="${WORKFLOWS_REPO}/${REUSABLE_WORKFLOW}@${CALLER_REF}"
  fi

  if [[ "$DRY_RUN" == true ]]; then
    echo ""
    echo "# [dry-run] Caller workflow: $WORKFLOW_FILE"
    echo "# ─────────────────────────────────────────"
    generate_caller_workflow "$local_uses_path"
    echo ""
  else
    mkdir -p "$WORKFLOW_DIR"

    # Download reusable workflow for inline mode (skips if already present
    # unless --force).
    if [[ "$MODE" == "inline" ]]; then
      download_reusable_workflow
    fi

    if [[ -f "$WORKFLOW_FILE" && "$FORCE" == false ]]; then
      echo "⏭  $WORKFLOW_FILE already exists — skipping (use --force to overwrite)."
    else
      generate_caller_workflow "$local_uses_path" > "$WORKFLOW_FILE"
      echo "✓ Created $WORKFLOW_FILE (mode: $MODE)"
    fi
  fi
fi

# Summary
# Helper: append "(default)" when not explicitly set
_d() { [[ "$1" == false ]] && echo " (default)" || echo ""; }

echo ""
echo "✓ Setup complete!$( [[ "$DRY_RUN" == true ]] && echo " (dry-run — no files written)" )"
echo ""
echo "  Mode:            $MODE$(_d "$_SET_MODE")"
echo "  Upstream:        $UPSTREAM_URL"
echo "  Branch:          $BRANCH$(_d "$_SET_BRANCH")"
echo "  Sync branch:     $SYNC_BRANCH$(_d "$_SET_SYNC_BRANCH")"
if [[ -n "$CRON" ]]; then
  echo "  Schedule:        $CRON$(_d "$_SET_CRON")"
else
  echo "  Schedule:        off — manual dispatch only$(_d "$_SET_CRON")"
fi
echo "  Remote name:     $REMOTE_NAME$(_d "$_SET_REMOTE_NAME")"
echo "  Workflows repo:  $WORKFLOWS_REPO@$CALLER_REF$( [[ "$_SET_WORKFLOWS_REPO" == false && "$_SET_CALLER_REF" == false ]] && echo " (default)" || echo "" )"
echo "  Upstream WFs:    $DISABLE_WORKFLOWS$(_d "$_SET_DISABLE_WF")"
if [[ "$DISABLE_WORKFLOWS" == "rename" ]]; then
  echo "  Rename dir:      $RENAME_DIR$(_d "$_SET_RENAME_DIR")"
fi
if [[ "$AUTO_PR" == true ]]; then
  echo "  Auto PR:         $SYNC_BRANCH → $PR_BASE$(_d "$_SET_PR_BASE")"
else
  echo "  Auto PR:         off$(_d "$_SET_AUTO_PR")"
fi
echo ""
echo "  Run manually: gh workflow run sync-upstream.yml"