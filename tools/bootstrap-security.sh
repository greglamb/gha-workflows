#!/usr/bin/env bash
# bootstrap-security.sh — set up per-repo security hygiene
#
# Bash 3.2.57+ compatible. Do not use Bash 4+ features.
#
# Run from inside a git repo with `gh` authenticated. The script:
#   1. Detects package ecosystems and writes .github/dependabot.yml
#   2. Drops in .github/workflows/security.yml caller stub
#   3. Enables Dependabot alerts, Dependabot security updates,
#      secret scanning, and push protection via the GitHub API
#   4. Optionally applies a branch-protection rule on the default branch
#
# Idempotent: re-running is safe. Skips existing files unless --force.

set -euo pipefail
IFS=$'\n\t'

# ---------- Defaults (override via flags) ----------

WORKFLOW_REPO="greglamb/gha-workflows"
WORKFLOW_REF=""  # Resolved to latest release via gh if empty after arg parsing
REUSABLE_WORKFLOW=".github/workflows/lib-security-review.yml"
MODE="caller"
APPLY_DEPENDABOT=1
APPLY_WORKFLOW=1
APPLY_SETTINGS=1
APPLY_GITLEAKS=1
APPLY_BRANCH_PROTECTION=0
FORCE=0
DRY_RUN=0

# ---------- Logging ----------

if [ -t 2 ]; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_RED=$'\033[31m'; C_BLUE=$'\033[34m'
else
  C_RESET=''; C_DIM=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_BLUE=''
fi

log::info() { printf '%s[INFO]%s  %s\n' "$C_BLUE"   "$C_RESET" "$*" >&2; }
log::ok()   { printf '%s[OK]%s    %s\n' "$C_GREEN"  "$C_RESET" "$*" >&2; }
log::warn() { printf '%s[WARN]%s  %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
log::err()  { printf '%s[ERR]%s   %s\n' "$C_RED"    "$C_RESET" "$*" >&2; }
log::dim()  { printf '%s%s%s\n'         "$C_DIM"    "$*"        "$C_RESET" >&2; }
log::die()  { log::err "$@"; exit 1; }

# ---------- Helpers ----------

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Bootstraps DevSecOps hygiene on the current repo.

Options:
  --workflow-repo OWNER/REPO  Reusable workflow source repo
                                (default: ${WORKFLOW_REPO})
  --workflow-ref REF          Tag/branch/SHA to pin caller to
                                (default: latest release via gh)
  -m, --mode inline|caller    Workflow strategy (default: caller)
  --no-dependabot             Skip writing .github/dependabot.yml
  --no-workflow               Skip writing .github/workflows/security.yml
  --no-settings               Skip gh api calls (no setting changes)
  --no-gitleaks               Skip local gitleaks pre-commit hook setup
  --branch-protection         Apply branch protection on default branch
  --force                     Overwrite existing files
  --dry-run                   Show actions without executing
  -h, --help                  Show this help

Modes:
  caller   (default) Thin caller to remote reusable workflow at
           <workflow-repo>@<ref>. Smaller footprint, auto-picks up upstream
           workflow changes when the pin is bumped.
  inline   Downloads lib-security-review.yml into the repo. Self-contained,
           no external dependency at runtime.

Requires: gh (GitHub CLI), authenticated; run from inside a git repo.
EOF
}

run() {
  if [ "$DRY_RUN" = 1 ]; then
    log::dim "DRY: $*"
  else
    "$@"
  fi
}

write_file() {
  local path="$1" content="$2"
  if [ -f "$path" ] && [ "$FORCE" != 1 ]; then
    log::warn "skip: $path exists (use --force to overwrite)"
    return 0
  fi
  if [ "$DRY_RUN" = 1 ]; then
    log::dim "DRY: write $path ($(printf '%s' "$content" | wc -l | tr -d ' ') lines)"
    return 0
  fi
  mkdir -p "$(dirname "$path")"
  printf '%s' "$content" > "$path"
  log::ok "wrote $path"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || log::die "missing required command: $1"
}

# Look up the latest release tag of WORKFLOW_REPO via gh.
# Prefers `gh release view` (GitHub Releases). Falls back to the highest
# CalVer-shaped tag (v0.YYMM.DDBB) if no Releases exist. Returns empty on
# any failure — caller is responsible for surfacing a clear error.
fetch_latest_ref() {
  local repo="$1"
  command -v gh >/dev/null 2>&1 || return 0
  local ref
  ref=$(gh release view --repo "$repo" --json tagName -q .tagName 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "$ref"
    return 0
  fi
  ref=$(gh api --paginate "/repos/$repo/tags" --jq '.[].name' 2>/dev/null \
    | grep -E '^v0\.[0-9]{4}\.[0-9]+$' \
    | sort -V \
    | tail -1)
  [ -n "$ref" ] && echo "$ref"
  # Explicit return: a trailing `&&` chain whose left side fails leaves
  # the function with a non-zero exit code, which under `set -e` would
  # make the call site silently exit even though we mean "no result".
  return 0
}

# Download the reusable workflow into the consuming repo (inline mode).
# Uses gh for auth automatically — works for private gha-workflows repos.
download_reusable_workflow() {
  local dest=".github/workflows/$(basename "$REUSABLE_WORKFLOW")"

  if [ -f "$dest" ] && [ "$FORCE" != 1 ]; then
    log::warn "skip: $dest exists (use --force to overwrite)"
    return 0
  fi
  if [ "$DRY_RUN" = 1 ]; then
    log::dim "DRY: download ${WORKFLOW_REPO}@${WORKFLOW_REF}:${REUSABLE_WORKFLOW} -> $dest"
    return 0
  fi

  mkdir -p "$(dirname "$dest")"
  log::info "downloading ${REUSABLE_WORKFLOW} from ${WORKFLOW_REPO}@${WORKFLOW_REF}"
  gh api "/repos/${WORKFLOW_REPO}/contents/${REUSABLE_WORKFLOW}?ref=${WORKFLOW_REF}" \
    --jq '.content' \
    | base64 -d \
    > "$dest" \
    || log::die "failed to download ${REUSABLE_WORKFLOW} from ${WORKFLOW_REPO}@${WORKFLOW_REF}"
  log::ok "wrote $dest"
}

# ---------- Preflight ----------

preflight::check() {
  require_cmd gh
  require_cmd git
  git rev-parse --git-dir >/dev/null 2>&1 || log::die "not inside a git repo"
  gh auth status >/dev/null 2>&1 || log::die "gh is not authenticated (run: gh auth login)"
}

repo::nwo() {
  gh repo view --json nameWithOwner -q .nameWithOwner
}

repo::default_branch() {
  gh repo view --json defaultBranchRef -q .defaultBranchRef.name
}

# ---------- Ecosystem detection ----------

DETECTED=""

detect::add() {
  case "$DETECTED" in
    *"$1"*) ;;
    *) DETECTED="${DETECTED}${1}"$'\n' ;;
  esac
}

detect::ecosystems() {
  if [ -d .github/workflows ] || [ "$APPLY_WORKFLOW" = 1 ]; then
    detect::add "github-actions"
  fi

  [ -f package.json ]    && detect::add "npm"
  [ -f pnpm-lock.yaml ]  && detect::add "npm"
  [ -f yarn.lock ]       && detect::add "npm"

  if ls -1 ./*.csproj ./*.sln ./*.fsproj 2>/dev/null | grep -q .; then
    detect::add "nuget"
  fi
  if find . -maxdepth 4 -type f \( -name '*.csproj' -o -name '*.fsproj' -o -name '*.sln' \) \
       -not -path './node_modules/*' -not -path './.git/*' 2>/dev/null | grep -q .; then
    detect::add "nuget"
  fi

  [ -f Dockerfile ]      && detect::add "docker"
  [ -f Containerfile ]   && detect::add "docker"
  ls -1 docker-compose*.y*ml 2>/dev/null | grep -q . && detect::add "docker"

  [ -f requirements.txt ] && detect::add "pip"
  [ -f pyproject.toml ]   && detect::add "pip"
  [ -f Pipfile ]          && detect::add "pip"

  [ -f go.mod ]        && detect::add "gomod"
  [ -f Gemfile ]       && detect::add "bundler"
  [ -f Cargo.toml ]    && detect::add "cargo"
  [ -f composer.json ] && detect::add "composer"
  [ -f pom.xml ]       && detect::add "maven"
  ls -1 build.gradle* 2>/dev/null | grep -q . && detect::add "gradle"
  # Explicit return: under `set -e`, errexit is suspended for the left
  # side of an `&&` chain, but if the chain is the LAST statement of a
  # function its non-zero exit code becomes the function's return code,
  # and the call site silently exits. Trip-wire for repos that don't
  # match the last detector (e.g. no Gradle files in a TypeScript repo).
  return 0
}

# ---------- File generation ----------

dependabot::yaml() {
  local eco
  printf '%s\n' "# .github/dependabot.yml — generated by repo-security-bootstrap"
  printf '%s\n' "version: 2"
  printf '%s\n' "updates:"
  printf '%s' "$DETECTED" | while IFS= read -r eco; do
    [ -z "$eco" ] && continue
    printf '  - package-ecosystem: %s\n' "$eco"
    printf '    directory: "/"\n'
    printf '    schedule:\n'
    printf '      interval: weekly\n'
    printf '    open-pull-requests-limit: 10\n'
  done
}

workflow::yaml() {
  local uses_path
  if [ "$MODE" = "inline" ]; then
    uses_path="./${REUSABLE_WORKFLOW}"
  else
    uses_path="${WORKFLOW_REPO}/${REUSABLE_WORKFLOW}@${WORKFLOW_REF}"
  fi
  cat <<EOF
# .github/workflows/security.yml — generated by bootstrap-security.sh
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
    uses: ${uses_path}
    permissions:
      contents: read
      security-events: write
      actions: read
      pull-requests: read
EOF
}

# ---------- Local pre-commit hook (gitleaks) ----------

# Invoke shared/setup-gitleaks.sh against the consumer's repo (cwd).
# Located relative to this script; if missing (e.g. script was curled
# without the rest of the repo), warn and skip rather than fail.
setup_gitleaks_local() {
  local self_dir gitleaks_setup
  self_dir="$(cd "$(dirname "$0")" && pwd)"
  gitleaks_setup="${self_dir}/../shared/setup-gitleaks.sh"

  if [ ! -x "$gitleaks_setup" ]; then
    log::warn "shared/setup-gitleaks.sh not found at $gitleaks_setup — skipping local gitleaks setup"
    log::warn "(clone the gha-workflows repo and re-run, or invoke setup-gitleaks.sh directly)"
    return 0
  fi

  if [ "$DRY_RUN" = 1 ]; then
    log::dim "DRY: $gitleaks_setup"
    return 0
  fi

  log::info "running shared/setup-gitleaks.sh for local pre-commit hook"
  "$gitleaks_setup"
}

# ---------- GitHub API actions ----------

settings::enable_dependabot_alerts() {
  local nwo="$1"
  log::info "enabling Dependabot alerts on $nwo"
  run gh api --silent -X PUT "/repos/${nwo}/vulnerability-alerts"
}

settings::enable_dependabot_fixes() {
  local nwo="$1"
  log::info "enabling Dependabot security updates on $nwo"
  run gh api --silent -X PUT "/repos/${nwo}/automated-security-fixes"
}

settings::enable_secret_scanning() {
  local nwo="$1"
  log::info "enabling secret scanning + push protection on $nwo"
  run gh api --silent -X PATCH "/repos/${nwo}" \
    -F 'security_and_analysis[secret_scanning][status]=enabled' \
    -F 'security_and_analysis[secret_scanning_push_protection][status]=enabled' \
    || log::warn "secret scanning enable failed (expected on org private repos without GHAS)"
}

settings::apply_branch_protection() {
  local nwo="$1" branch="$2"
  log::info "applying branch protection to ${nwo}@${branch}"
  # Solo-dev-friendly rule: require linear history, no force push, no deletion,
  # require status checks to pass. PR reviews not required (would block self).
  # The status check name must match the job name in the reusable workflow.
  # SAST engine is OpenGrep (LGPL fork of Semgrep CE).
  run gh api --silent -X PUT "/repos/${nwo}/branches/${branch}/protection" \
    -F 'required_status_checks[strict]=true' \
    -F 'required_status_checks[contexts][]=security / OpenGrep (SAST)' \
    -F 'enforce_admins=false' \
    -F 'required_pull_request_reviews=' \
    -F 'restrictions=' \
    -F 'allow_force_pushes=false' \
    -F 'allow_deletions=false' \
    -F 'required_linear_history=true' \
    || log::warn "branch protection failed (check status check names match your workflow)"
}

# ---------- Main ----------

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --workflow-repo) WORKFLOW_REPO="$2"; shift 2 ;;
      --workflow-ref)  WORKFLOW_REF="$2";  shift 2 ;;
      -m|--mode)       MODE="$2";          shift 2 ;;
      --no-dependabot) APPLY_DEPENDABOT=0; shift ;;
      --no-workflow)   APPLY_WORKFLOW=0;   shift ;;
      --no-settings)   APPLY_SETTINGS=0;   shift ;;
      --no-gitleaks)   APPLY_GITLEAKS=0;   shift ;;
      --branch-protection) APPLY_BRANCH_PROTECTION=1; shift ;;
      --force)   FORCE=1;   shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) log::die "unknown flag: $1 (try --help)" ;;
    esac
  done

  case "$MODE" in
    inline|caller) ;;
    *) log::die "--mode must be 'inline' or 'caller' (got: $MODE)" ;;
  esac
}

main() {
  parse_args "$@"
  preflight::check

  if [ -z "$WORKFLOW_REF" ]; then
    WORKFLOW_REF="$(fetch_latest_ref "$WORKFLOW_REPO" || true)"
    if [ -z "$WORKFLOW_REF" ]; then
      log::die "could not resolve latest release of $WORKFLOW_REPO via gh — pass --workflow-ref <tag> explicitly"
    fi
    log::info "resolved --workflow-ref to latest release: $WORKFLOW_REF"
  fi

  local nwo branch
  nwo="$(repo::nwo)"
  branch="$(repo::default_branch)"
  log::info "repo: $nwo (default branch: $branch)"
  [ "$DRY_RUN" = 1 ] && log::warn "DRY RUN — no changes will be made"

  detect::ecosystems
  log::info "detected ecosystems: $(printf '%s' "$DETECTED" | tr '\n' ' ')"

  if [ "$APPLY_DEPENDABOT" = 1 ]; then
    write_file ".github/dependabot.yml" "$(dependabot::yaml)"
  fi

  if [ "$APPLY_WORKFLOW" = 1 ]; then
    if [ "$MODE" = "inline" ]; then
      download_reusable_workflow
    fi
    write_file ".github/workflows/security.yml" "$(workflow::yaml)"
  fi

  if [ "$APPLY_SETTINGS" = 1 ]; then
    settings::enable_dependabot_alerts "$nwo"
    settings::enable_dependabot_fixes  "$nwo"
    settings::enable_secret_scanning   "$nwo"
  fi

  if [ "$APPLY_BRANCH_PROTECTION" = 1 ]; then
    settings::apply_branch_protection "$nwo" "$branch"
  fi

  if [ "$APPLY_GITLEAKS" = 1 ]; then
    setup_gitleaks_local
  fi

  log::ok "done. Review and commit any new files in .github/"
}

main "$@"
