# Update pinned dependency versions

Update all pinned third-party versions in this `gha-workflows` repository to current stable releases, applying any workflow adaptations needed for breaking changes per release notes.

## Scope

**Modify these refs in `.github/workflows/lib-security-review.yml`:**

- GitHub Action `uses:` directives — both regular actions and reusable workflow refs (paths ending in `.yml@<tag>`)
- OpenGrep version: `inputs.opengrep-version.default` AND the matching `<VERSION>` segment in the `raw.githubusercontent.com/opengrep/opengrep/<VERSION>/install.sh` URL inside the install steps. **These must stay in sync.**
- Ubuntu runner: `inputs.runner-os.default`

**Do NOT modify:**

- `inputs.rules-ref.default` — intentionally tracks `main` for fresh rules; leave it alone.
- Any documentation comments (especially the ones explaining the opengrep-rules archive, license rationale, or supply-chain hardening notes).
- Workflow logic, job structure, step ordering, or input names.
- Pinning style — this repo uses tag pinning (`@v1.2.3`), not SHA pinning. Preserve.

## Procedure

### 1. Discover

Read the workflow file. List every pinned ref with its current value. Include:
- Action refs (`uses: owner/repo@<tag>`)
- Reusable workflow refs (`uses: owner/repo/.github/workflows/foo.yml@<tag>`)
- Runner OS (`inputs.runner-os.default`)
- OpenGrep version (both locations)

### 2. Resolve latest stable

For each GitHub-hosted ref, query upstream tags:

```bash
git ls-remote --tags --sort=-version:refname https://github.com/<owner>/<repo>.git \
  | grep -v "\^{}" \
  | head -10
```

Pick the highest tag that is **not** a pre-release. Skip anything with `-rc`, `-alpha`, `-beta`, `-pre`, `-next`, or similar suffixes.

For the Ubuntu runner, use web search to confirm the runner image is actually available on GitHub Actions before bumping. Runner image availability lags Ubuntu LTS releases by 4–6 months. Check `actions/runner-images` issues if uncertain.

### 3. Categorize each bump

- **patch** (1.2.3 → 1.2.4): apply silently.
- **minor** (1.2.3 → 1.3.0): apply, summarize in report.
- **major** (1.2.3 → 2.0.0): read release notes carefully (next step) before applying.

### 4. Read release notes for non-patch bumps

Fetch the GitHub release page for the new tag, and for **every intermediate tag** between current and new (skipped versions matter on jumps). Look specifically for:

- Breaking changes
- Renamed or removed inputs/outputs
- Changed defaults
- New required parameters
- Deprecation warnings that affect this workflow

If a release notes fetch fails, **skip that bump** and report it. Do not proceed blind.

### 5. Apply updates

- Edit the workflow file in place.
- Update version tags. Preserve every comment, including trailing version comments if any.
- For OpenGrep: update **both** the `default:` and the `install.sh` URL in lockstep.
- For breaking changes affecting this workflow: adapt the relevant `with:`, `env:`, or step block to match the new version's API. Be minimal — no refactoring beyond what's necessary.

### 6. Validate

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/lib-security-review.yml'))" \
  && echo "YAML OK"
```

If YAML parsing fails, revert and report.

### 7. Report

Output a markdown summary:

```markdown
## Version updates applied

| Component | Old | New | Type | Notes |
|---|---|---|---|---|
| actions/checkout | v4.2.2 | v4.3.0 | patch | |
| trufflesecurity/trufflehog | v3.82.13 | v3.95.0 | minor | New `--results=verified-only` flag (already using equivalent) |
| ... |

## Major bumps requiring review (NOT applied)

- `actions/checkout` v4.x → v6.0.2: removes `persist-credentials: true` default. Workflow doesn't rely on this — safe to bump in a follow-up PR.

## Adaptations made

- (none) | (description of any breaking-change accommodations)

## Final state

- YAML validation: ✅
- Files changed: 1
```

## Arguments

`$ARGUMENTS` controls bump aggressiveness:

- *(no args)*: patch and minor only — the default safe mode.
- `--include-major`: also apply major version bumps when release notes show no breaking changes affecting this workflow.
- `--dry-run`: report what would change but do not modify any files.
- `--only <name>`: only update the named ref (e.g., `--only trufflehog` or `--only opengrep`).

## Constraints

- One workflow file in scope by default (`.github/workflows/lib-security-review.yml`). If others exist, ask before touching them.
- Do not bump pre-release versions ever.
- Do not introduce non-version changes (no refactoring, no rule additions, no comment cleanup).
- If anything is ambiguous (e.g., an action has multiple "latest" tags floating across major versions), STOP and ask the user rather than guessing.
- Verify the OpenGrep `install.sh` URL still uses the new version after the update — easy to miss the second location.
