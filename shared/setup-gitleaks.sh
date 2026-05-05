#!/usr/bin/env bash
# setup-gitleaks.sh — install and configure the gitleaks pre-commit hook on the current repo.
# Bash 3.2.57+ compatible (macOS default).
#
# Usage:
#   cd /path/to/your/project
#   ./setup-gitleaks.sh
#
# Behaviour:
#   - installs `pre-commit` if missing (uv → pipx → brew)
#   - creates or merges .pre-commit-config.yaml (does not modify existing hooks)
#   - validates the resulting YAML with `pre-commit validate-config`
#   - creates .gitleaks.toml with an empty allowlist if missing
#   - registers the git hook and runs an initial all-files scan
#   - if findings exist, reports and stops (no auto-removal)
#   - otherwise commits the two config files
#
# Reproducibility note:
#   The pinned `rev:` is intentional and is NOT auto-bumped. To update later,
#   see the "Updating gitleaks" section below.
#
# ─── Updating gitleaks ───────────────────────────────────────────────────────
# When you want to bump the version, do this from the repo root:
#
#   1. Read the gitleaks release notes between your current rev and latest:
#        https://github.com/gitleaks/gitleaks/releases
#      Past minors have included breaking config changes (e.g. composite rules
#      in v8.28.0) — review before bumping.
#
#   2. Bump (always pass `--repo` — bare `autoupdate` bumps every hook in the
#      file, not just gitleaks):
#        pre-commit autoupdate --repo https://github.com/gitleaks/gitleaks
#        # OR pin to an immutable commit SHA (preferred for compliance work):
#        pre-commit autoupdate --freeze --repo https://github.com/gitleaks/gitleaks
#
#   3. Verify it works against your codebase:
#        pre-commit run gitleaks --all-files
#
#   4. Review and commit:
#        git diff .pre-commit-config.yaml      # confirm the rev change
#        git add .pre-commit-config.yaml
#        git commit -m "chore(deps): bump gitleaks pre-commit hook"
#
# Pin form trade-off: tag pins (`rev: v8.30.1`) are readable but mutable —
# a maintainer or attacker with repo write access can re-point a tag.
# SHA pins (`rev: <40-char-sha>`) are immutable but opaque; add a trailing
# comment with the corresponding tag for human review.
#
# ─── Pinned versions ─────────────────────────────────────────────────────────
# Two version pins live in this script — both intentional, both manually bumped:
#
#   PRECOMMIT_VERSION below — the pre-commit framework itself (PyPI)
#   `rev:` in .pre-commit-config.yaml — the gitleaks hook (see "Updating gitleaks")
#
# To bump pre-commit:
#   1. Read the changelog: https://github.com/pre-commit/pre-commit/blob/main/CHANGELOG.md
#   2. Edit PRECOMMIT_VERSION below.
#   3. Reinstall on your machine:
#        uv tool install --force "pre-commit==<new-version>"     # or pipx upgrade
#   4. Commit the script change.
#
# Note: `brew install pre-commit` cannot pin to an exact version — it installs
# whatever the current Homebrew formula provides. If brew is used and the
# resulting version differs from PRECOMMIT_VERSION, the script warns but
# continues. Use uv or pipx for a strictly reproducible install.
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail
IFS=$'\n\t'

# ---- pinned versions ----
PRECOMMIT_VERSION="4.6.0"

# ---- logging helpers ----
gl::info()  { printf '\033[1;34m[gitleaks-setup]\033[0m %s\n' "$*"; }
gl::warn()  { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
gl::error() { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }
gl::die()   { gl::error "$*"; exit 1; }

# ---- preflight ----
[ -d .git ] || gl::die "current directory is not a git repository (cd into your project root or run 'git init' first)"

# ---- 1. ensure pre-commit is installed at the pinned version ----
gl::ensure_pre_commit() {
  if command -v pre-commit >/dev/null 2>&1; then
    local installed
    installed=$(pre-commit --version 2>/dev/null | awk '{print $2}')
    if [ "$installed" = "$PRECOMMIT_VERSION" ]; then
      gl::info "pre-commit already installed: $installed (matches pin)"
    else
      gl::warn "pre-commit installed at $installed; pinned target is $PRECOMMIT_VERSION"
      gl::warn "to align: uv tool install --force pre-commit==$PRECOMMIT_VERSION"
      gl::warn "(continuing with installed version)"
    fi
    return 0
  fi

  gl::info "pre-commit not found; installing version $PRECOMMIT_VERSION..."
  if command -v uv >/dev/null 2>&1; then
    gl::info "installing via uv tool"
    uv tool install "pre-commit==$PRECOMMIT_VERSION"
  elif command -v pipx >/dev/null 2>&1; then
    gl::info "installing via pipx"
    pipx install "pre-commit==$PRECOMMIT_VERSION"
  elif command -v brew >/dev/null 2>&1; then
    gl::warn "brew cannot pin to a specific version; will install whatever the formula provides"
    gl::info "installing via brew"
    brew install pre-commit
  else
    gl::die "no installer available — install one of: uv, pipx, or brew, then re-run."
  fi

  command -v pre-commit >/dev/null 2>&1 \
    || gl::die "pre-commit installation appears to have failed (not on PATH)"

  local installed
  installed=$(pre-commit --version 2>/dev/null | awk '{print $2}')
  if [ "$installed" = "$PRECOMMIT_VERSION" ]; then
    gl::info "installed: pre-commit $installed (matches pin)"
  else
    gl::warn "installed pre-commit $installed; pinned target was $PRECOMMIT_VERSION"
    gl::warn "(likely a brew install or a transitive resolver decision; continuing)"
  fi
}

# ---- 2. create or merge .pre-commit-config.yaml ----
gl::write_precommit_config() {
  local config=".pre-commit-config.yaml"
  local block='  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.30.1
    hooks:
      - id: gitleaks'

  if [ -f "$config" ]; then
    if grep -q 'gitleaks/gitleaks' "$config"; then
      gl::info "$config already references gitleaks; leaving as-is"
      return 0
    fi
    gl::info "appending gitleaks entry to existing $config"
    # ensure the file ends with a newline before appending
    if [ -n "$(tail -c1 "$config" 2>/dev/null)" ]; then
      printf '\n' >> "$config"
    fi
    printf '%s\n' "$block" >> "$config"
  else
    gl::info "creating $config"
    cat > "$config" <<'YAML'
repos:
  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.30.1
    hooks:
      - id: gitleaks
YAML
  fi
}

# ---- 3. validate the resulting YAML ----
gl::validate_config() {
  gl::info "validating .pre-commit-config.yaml"
  pre-commit validate-config .pre-commit-config.yaml \
    || gl::die "pre-commit validate-config failed — inspect .pre-commit-config.yaml manually"
}

# ---- 4. create .gitleaks.toml with an empty allowlist if missing ----
gl::write_gitleaks_config() {
  if [ -f .gitleaks.toml ]; then
    gl::info ".gitleaks.toml already exists; leaving as-is"
    return 0
  fi
  gl::info "creating .gitleaks.toml"
  cat > .gitleaks.toml <<'TOML'
title = "Gitleaks config"

[allowlist]
  description = "Allowlisted patterns"
  paths = []
TOML
}

# ---- 5. register the git hook ----
gl::install_hook() {
  gl::info "registering pre-commit hook in .git/hooks/"
  pre-commit install
}

# ---- 6. initial scan ----
gl::initial_scan() {
  gl::info "running gitleaks against all files (first run will download the hook env)"
  if pre-commit run gitleaks --all-files; then
    gl::info "no secrets found"
    return 0
  fi
  gl::error "gitleaks reported potential secrets above."
  gl::error "this script will NOT auto-remove or rewrite history."
  gl::error "review findings, rotate any leaked credentials, and either:"
  gl::error "  - clean the repo (e.g. git filter-repo / BFG), or"
  gl::error "  - add justified false-positives to the allowlist in .gitleaks.toml"
  gl::error "stopping before commit."
  exit 1
}

# ---- 7. commit the two config files ----
gl::commit_config() {
  # Refuse to commit if the user already has other staged changes — `git
  # commit` without paths commits the entire index, so we'd bundle their
  # work into our "add gitleaks hook" commit. Bail out and let them stage
  # the gitleaks configs themselves.
  if ! git diff --cached --quiet; then
    gl::warn "staging area is not clean — skipping auto-commit of gitleaks configs"
    gl::warn "(other staged changes would have been bundled into the commit)"
    gl::warn "to commit them yourself once your index is clean:"
    gl::warn "  git add .pre-commit-config.yaml .gitleaks.toml"
    gl::warn "  git commit -m 'chore: add gitleaks pre-commit hook for secret detection'"
    return 0
  fi

  gl::info "staging .pre-commit-config.yaml and .gitleaks.toml"
  git add .pre-commit-config.yaml .gitleaks.toml

  if git diff --cached --quiet; then
    gl::info "no staged changes — config files were already committed"
    return 0
  fi

  git commit -m "chore: add gitleaks pre-commit hook for secret detection"
  gl::info "committed gitleaks config"
}

# ---- main ----
gl::ensure_pre_commit
gl::write_precommit_config
gl::validate_config
gl::write_gitleaks_config
gl::install_hook
gl::initial_scan
gl::commit_config

gl::info "done."
