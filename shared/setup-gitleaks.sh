#!/usr/bin/env bash
# setup-gitleaks.sh — install gitleaks as a pre-commit hook in the current repo.
# Bash 3.2.57+ compatible (macOS default).
#
# Run with --help for full usage. No Python, no pre-commit framework,
# no .pre-commit-config.yaml.
#
# ─── Updating gitleaks ───────────────────────────────────────────────────────
# 1. Read the gitleaks release notes:
#      https://github.com/gitleaks/gitleaks/releases
#    Past minors have included breaking config changes (e.g. composite rules
#    in v8.28.0) — review before bumping.
# 2. Bump GITLEAKS_VERSION below (or pass --gitleaks-version on the CLI).
# 3. Re-run this script. The check at the top warns if the installed version
#    no longer matches the pin; on macOS with brew you may need
#    `brew upgrade gitleaks` (brew can't pin to a specific version).
# 4. Verify against your codebase: `gitleaks dir . --no-banner`.
# 5. Commit the script change.
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail
IFS=$'\n\t'

# ---- defaults ----
GITLEAKS_VERSION="8.30.1"
APPLY_COMMIT=1
APPLY_SCAN=1
FORCE=0

# ---- logging helpers ----
gl::info()  { printf '\033[1;34m[gitleaks-setup]\033[0m %s\n' "$*"; }
gl::warn()  { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
gl::error() { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }
gl::die()   { gl::error "$*"; exit 1; }

# ---- usage ----
gl::usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Install gitleaks as a pre-commit hook in the current git repo.

Options:
  --no-commit                Don't auto-commit .gitleaks.toml and the hook
  --no-scan                  Skip the initial gitleaks scan of the working tree
  --force                    Overwrite .gitleaks.toml if it exists
  --gitleaks-version <ver>   Pin the gitleaks binary version
                               (default: ${GITLEAKS_VERSION})
  -h, --help                 Show this help

Behavior:
  - Installs gitleaks if missing (brew preferred, otherwise downloads
    a pinned release tarball into ~/.local/bin).
  - Sets core.hooksPath to .githooks if unset; refuses to override if
    it points elsewhere.
  - Splices a marker-bounded gitleaks block into .githooks/pre-commit,
    leaving any existing hook content alone.
  - Creates .gitleaks.toml if missing (use --force to overwrite).
  - Runs an initial scan; aborts before committing if it finds anything.
  - Auto-commits the two config files only if the index is otherwise
    clean (so unrelated staged work is never bundled in).
EOF
}

# ---- parse args ----
while [ $# -gt 0 ]; do
  case "$1" in
    --no-commit)         APPLY_COMMIT=0; shift ;;
    --no-scan)           APPLY_SCAN=0; shift ;;
    --force)             FORCE=1; shift ;;
    --gitleaks-version)
      [ $# -ge 2 ] || gl::die "--gitleaks-version requires an argument"
      GITLEAKS_VERSION="$2"; shift 2 ;;
    -h|--help)           gl::usage; exit 0 ;;
    *) gl::die "unknown flag: $1 (try --help)" ;;
  esac
done

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
    gl::error "core.hooksPath is set to '$current' (expected '.githooks' or unset)."
    gl::error "Refusing to override — hooks under '$current' would silently deactivate."
    gl::error ""
    gl::error "To proceed, choose one and re-run this script:"
    gl::error "  - unset (this script will then set it to .githooks):"
    gl::error "      git config --unset core.hooksPath"
    gl::error "  - or override and migrate any hooks from '$current' to .githooks:"
    gl::error "      git config core.hooksPath .githooks"
    exit 1
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
  if [ -f .gitleaks.toml ] && [ "$FORCE" != 1 ]; then
    gl::info ".gitleaks.toml already exists; leaving as-is (use --force to overwrite)"
    return 0
  fi
  if [ -f .gitleaks.toml ]; then
    gl::warn "overwriting existing .gitleaks.toml (--force)"
  else
    gl::info "creating .gitleaks.toml"
  fi
  # Minimal valid config — gitleaks ships with built-in rules, so the only
  # thing this file needs to do is exist (so gitleaks finds it and treats
  # the repo root as the project root for allowlist paths). Allowlist
  # entries are commented out: gitleaks 8.28+ rejects empty allowlist
  # blocks, so we only add one when the user actually has something to
  # allow. Uncomment and fill in as needed.
  cat > .gitleaks.toml <<'TOML'
title = "Gitleaks config"

# Inherit gitleaks' built-in default rules so we don't have to redeclare them.
[extend]
useDefault = true

# Path-based allowlist for common dependency / build directories.
# Findings inside these paths are almost always noise (third-party code,
# vendored deps, lockfile hashes mistaken for credentials, etc.). Add
# more paths here as you discover them in your repo.
[[allowlists]]
  description = "Dependency and build directories"
  paths = [
    '^node_modules/',
  ]

# Add more allowlist entries below as needed. Each [[allowlists]] entry
# must include at least one non-empty check (commits, paths, regexes, or
# stopwords) or gitleaks will refuse to load the config.
#
# [[allowlists]]
#   description = "Skip vendored test fixtures"
#   paths = ['^tests/fixtures/']
#
# [[allowlists]]
#   description = "Known false positives in this repo"
#   regexes = ['EXAMPLE_API_KEY_NOT_REAL']
#
# [[allowlists]]
#   description = "Pre-cleanup history audited and accepted"
#   commits = ['abc123def456']
TOML
}

# ---- 5. initial scan against the working tree ----
gl::initial_scan() {
  # Report path lives under .git/ so it never accidentally gets committed.
  # Unredacted on purpose: the user needs the actual matched content to
  # triage false positives. The console output is still safe — gitleaks
  # v8.30 prints only the summary by default (no per-finding detail unless
  # --verbose is passed).
  local report=".git/gitleaks-report.json"
  gl::info "running gitleaks against the working tree (report -> $report)"

  if gitleaks dir . --no-banner --report-format json --report-path "$report"; then
    gl::info "no secrets found"
    rm -f "$report"
    return 0
  fi

  local count=""
  if command -v jq >/dev/null 2>&1 && [ -f "$report" ]; then
    count=$(jq 'length' "$report" 2>/dev/null || true)
  fi

  gl::error "gitleaks reported${count:+ $count} potential finding(s)."
  gl::error "Full unredacted report: $report"
  gl::error ""
  gl::error "Inspect findings:"
  gl::error "  jq -r '.[] | \"\\(.File):\\(.StartLine)  \\(.Description)  \\(.Match)\"' $report | less"
  gl::error ""
  gl::error "If they are false positives, allowlist them in .gitleaks.toml:"
  gl::error "  [[allowlists]]"
  gl::error "    description = \"…\""
  gl::error "    paths   = [ '^tests/fixtures/' ]      # OR"
  gl::error "    regexes = [ 'KNOWN_DUMMY_VALUE' ]     # OR"
  gl::error "    stopwords = [ 'example', 'fake' ]     # OR"
  gl::error "    commits = [ 'abc123…' ]"
  gl::error "  (each entry needs at least one of those four)"
  gl::error ""
  gl::error "If they are real secrets: rotate them and clean history"
  gl::error "(git filter-repo / BFG), then re-run this script to confirm."
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
if [ "$APPLY_SCAN" = 1 ]; then
  gl::initial_scan
else
  gl::info "skipping initial scan (--no-scan)"
fi

if [ "$APPLY_COMMIT" = 1 ]; then
  gl::commit_config
else
  gl::info "skipping auto-commit (--no-commit)"
fi

gl::info "done. gitleaks will run on every commit via .githooks/pre-commit."
