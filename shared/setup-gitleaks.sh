#!/usr/bin/env bash
# setup-gitleaks.sh — install gitleaks as a pre-commit hook in the current repo.
# Bash 3.2.57+ compatible (macOS default).
#
# Usage:
#   cd /path/to/your/project
#   ./setup-gitleaks.sh
#
# Behaviour:
#   - installs the gitleaks binary if missing (brew preferred, otherwise
#     downloads a pinned release tarball into ~/.local/bin)
#   - sets `core.hooksPath` to `.githooks` if unset (so the hook is shared
#     with anyone who clones the repo + runs the project's bootstrap)
#   - writes / updates a marker-bounded gitleaks block in
#     .githooks/pre-commit, leaving any existing hook content alone
#   - creates .gitleaks.toml with an empty allowlist if missing
#   - runs an initial scan against the working tree
#   - if the index is clean, commits the two config files
#
# No Python, no pre-commit framework, no .pre-commit-config.yaml.
#
# ─── Updating gitleaks ───────────────────────────────────────────────────────
# 1. Read the gitleaks release notes:
#      https://github.com/gitleaks/gitleaks/releases
#    Past minors have included breaking config changes (e.g. composite rules
#    in v8.28.0) — review before bumping.
# 2. Bump GITLEAKS_VERSION below.
# 3. Re-run this script. The check at the top warns if the installed version
#    no longer matches the pin; on macOS with brew you may need
#    `brew upgrade gitleaks` (brew can't pin to a specific version).
# 4. Verify against your codebase: `gitleaks dir . --no-banner`.
# 5. Commit the script change.
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail
IFS=$'\n\t'

# ---- pinned versions ----
GITLEAKS_VERSION="8.30.1"

# ---- logging helpers ----
gl::info()  { printf '\033[1;34m[gitleaks-setup]\033[0m %s\n' "$*"; }
gl::warn()  { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
gl::error() { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }
gl::die()   { gl::error "$*"; exit 1; }

# ---- preflight ----
[ -d .git ] || gl::die "current directory is not a git repository (cd into your project root or run 'git init' first)"

# ---- 1. ensure the gitleaks binary is available ----
gl::ensure_gitleaks() {
  if command -v gitleaks >/dev/null 2>&1; then
    local installed
    # `gitleaks version` prints just the version string on its own line.
    installed=$(gitleaks version 2>/dev/null | awk 'NR==1{print $1}')
    if [ "$installed" = "$GITLEAKS_VERSION" ]; then
      gl::info "gitleaks already installed: $installed (matches pin)"
    else
      gl::warn "gitleaks installed at $installed; pinned target is $GITLEAKS_VERSION"
      gl::warn "(continuing with installed version; bump or upgrade to align)"
    fi
    return 0
  fi

  gl::info "gitleaks not found; installing v$GITLEAKS_VERSION..."

  if command -v brew >/dev/null 2>&1; then
    gl::warn "brew cannot pin to a specific version; will install whatever the formula provides"
    brew install gitleaks
    return 0
  fi

  # Fall back to a direct download from the GitHub release.
  local os arch tarball url tmp dest
  os=$(uname -s | tr 'A-Z' 'a-z')
  case "$os" in darwin|linux) ;; *) gl::die "unsupported OS: $os — install gitleaks manually" ;; esac
  arch=$(uname -m)
  case "$arch" in
    x86_64|amd64)    arch=x64 ;;
    aarch64|arm64)   arch=arm64 ;;
    armv7l)          arch=armv7 ;;
    *) gl::die "unsupported arch: $arch — install gitleaks manually" ;;
  esac

  tarball="gitleaks_${GITLEAKS_VERSION}_${os}_${arch}.tar.gz"
  url="https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/${tarball}"
  dest="${HOME}/.local/bin"
  mkdir -p "$dest"
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' RETURN

  gl::info "downloading $url"
  curl --fail --silent --show-error --location -o "$tmp/$tarball" "$url" \
    || gl::die "failed to download $url"
  tar -xzf "$tmp/$tarball" -C "$dest" gitleaks
  chmod 755 "$dest/gitleaks"

  if ! command -v gitleaks >/dev/null 2>&1; then
    gl::warn "installed to $dest/gitleaks but it's not on PATH"
    gl::warn "add to your shell profile: export PATH=\"\$HOME/.local/bin:\$PATH\""
    gl::warn "(continuing — re-run after adjusting PATH if subsequent steps fail)"
  fi
}

# ---- 2. ensure core.hooksPath = .githooks ----
gl::ensure_hookspath() {
  local current
  current=$(git config --get core.hooksPath 2>/dev/null || true)

  if [ -z "$current" ]; then
    git config core.hooksPath .githooks
    gl::info "set core.hooksPath = .githooks"
  elif [ "$current" = ".githooks" ]; then
    gl::info "core.hooksPath already = .githooks"
  else
    gl::die "core.hooksPath is set to '$current' (expected '.githooks' or unset). Refusing to override — adjust manually if intentional."
  fi

  mkdir -p .githooks
}

# ---- 3. write or update the gitleaks block in .githooks/pre-commit ----
gl::install_hook_block() {
  local hook=".githooks/pre-commit"
  local marker_start="# ── gitleaks (managed by setup-gitleaks.sh) ──"
  local marker_end="# ── /gitleaks ──"
  # Note: the leading shebang in the hook ensures `set -euo pipefail` is in
  # scope; the block below relies on `set -e` to propagate gitleaks' exit code.
  local block_body='if command -v gitleaks >/dev/null 2>&1; then
  gitleaks git --pre-commit --staged --redact --no-banner
fi'

  # Stage the new block in a temp file so awk can splice it in via getline.
  # BSD awk (macOS default) rejects embedded newlines in -v assignments, so
  # we cannot pass the multi-line block as an awk variable.
  local tmp_block
  tmp_block=$(mktemp)
  trap 'rm -f "$tmp_block"' RETURN
  {
    printf '%s\n' "$marker_start"
    printf '%s\n' "$block_body"
    printf '%s\n' "$marker_end"
  } > "$tmp_block"

  if [ ! -f "$hook" ]; then
    gl::info "creating $hook"
    {
      printf '%s\n' '#!/usr/bin/env bash'
      printf '%s\n' 'set -euo pipefail'
      printf '\n'
      cat "$tmp_block"
    } > "$hook"
    chmod 755 "$hook"
    return 0
  fi

  if grep -qF -- "$marker_start" "$hook"; then
    gl::info "updating gitleaks block in $hook"
    awk -v start="$marker_start" -v end="$marker_end" -v block_file="$tmp_block" '
      $0 == start {
        while ((getline line < block_file) > 0) print line
        close(block_file)
        in_block = 1
        next
      }
      in_block && $0 == end { in_block = 0; next }
      !in_block { print }
    ' "$hook" > "$hook.tmp"
    mv "$hook.tmp" "$hook"
  else
    gl::info "appending gitleaks block to $hook"
    # Ensure file ends with newline before appending.
    if [ -n "$(tail -c1 "$hook" 2>/dev/null)" ]; then
      printf '\n' >> "$hook"
    fi
    {
      printf '\n'
      cat "$tmp_block"
    } >> "$hook"
  fi
  chmod 755 "$hook"
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

# ---- 5. initial scan against the working tree ----
gl::initial_scan() {
  gl::info "running gitleaks against the working tree"
  if gitleaks dir . --no-banner --redact; then
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

# ---- 6. commit the two config files (if the index is clean) ----
gl::commit_config() {
  # Refuse to commit if the user already has other staged changes — `git
  # commit` without paths commits the entire index, so we'd bundle their
  # work into our "add gitleaks hook" commit. Bail out and let them stage
  # the gitleaks pieces themselves.
  if ! git diff --cached --quiet; then
    gl::warn "staging area is not clean — skipping auto-commit of gitleaks setup"
    gl::warn "(other staged changes would have been bundled into the commit)"
    gl::warn "to commit them yourself once your index is clean:"
    gl::warn "  git add .gitleaks.toml .githooks/pre-commit"
    gl::warn "  git commit -m 'chore: add gitleaks pre-commit hook for secret detection'"
    return 0
  fi

  gl::info "staging .gitleaks.toml and .githooks/pre-commit"
  git add .gitleaks.toml .githooks/pre-commit

  if git diff --cached --quiet; then
    gl::info "no staged changes — config and hook were already committed"
    return 0
  fi

  git commit -m "chore: add gitleaks pre-commit hook for secret detection"
  gl::info "committed gitleaks config"
}

# ---- main ----
gl::ensure_gitleaks
gl::ensure_hookspath
gl::write_gitleaks_config
gl::install_hook_block
gl::initial_scan
gl::commit_config

gl::info "done. gitleaks will run on every commit via .githooks/pre-commit."
