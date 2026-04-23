# The Runbook — Step by Step

Six phases. One PR each. Merge between phases so CI stays green and history is readable.

## Contents

- [Pre-flight (once per repo)](#pre-flight-once-per-repo)
- [Phase 0 — Security audit + .env hygiene](#phase-0--security-audit--env-hygiene)
- [Phase 1 — Community files + scaffolding](#phase-1--community-files--scaffolding)
- [Phase 2 — CI workflow hardening](#phase-2--ci-workflow-hardening)
- [Phase 3 — Upstream image digest pinning](#phase-3--upstream-image-digest-pinning)
- [Phase 4 — README rewrite](#phase-4--readme-rewrite)
- [Phase 5 — OpenSSF Scorecard](#phase-5--openssf-scorecard)
- [Verification gates](#verification-gates)
- [Common pitfalls](#common-pitfalls)

---

## Pre-flight (once per repo)

```bash
cd ~/repos
git clone https://github.com/<owner>/<service>-traefik-letsencrypt-docker-compose
cd <service>-traefik-letsencrypt-docker-compose

# Confirm on main, clean tree
git status
git branch --show-current

# Get the first-commit year — you'll need it for LICENSE
git log --reverse --format=%ai | head -1 | cut -d- -f1

# Read the current state. Look for:
# - .env: is it tracked in git? If yes, Phase 0 is a blocker.
# - docker-compose.yml: which upstream images does it reference?
# - .github/workflows/: any existing workflow? Usually there's one
#   called something like `00-deployment-verification.yml`.
# - .github/FUNDING.yml: exists? Phase 1 removes it.
# - .github/dependabot.yml: what ecosystems?
# - README.md: typically the pre-Phase-1.5 voice needing rewrite.
# - LICENSE / SECURITY.md / CHANGELOG.md: usually absent.
git ls-files | grep -E '^\.env$'
ls LICENSE SECURITY.md CHANGELOG.md 2>&1
find .github -type f
head -5 README.md
```

Record upstream image tags from the compose file — you'll pin them in Phase 3.

---

## Phase 0 — Security audit + .env hygiene

**Goal:** remove any credentials committed to git. Replace with placeholder `.env.example`. Make compose fail fast when required vars are missing.

**Branch:** `fix/rotate-credentials-and-env-hygiene`

### Steps

1. **Audit `.env` for real credentials:**
   ```bash
   cat .env
   ```
   Anything that looks like a password, hash, API key, or admin credential → must be rotated and removed from the tracked file.

2. **Create `.env.example`** (see `templates/deployment-verification.yml.tmpl` — actually the `.env.example` structure is in Phase 3 below; use the one from [keycloak `.env.example`](https://github.com/heyvaldemar/keycloak-traefik-letsencrypt-docker-compose/blob/main/.env.example) as the shape reference). Key requirements:
   - Image tags as real values (not secrets).
   - Each credential variable as `change_me_*` placeholder.
   - Inline comment above each credential with the generation command:
     ```
     # REQUIRED — generate with:
     #     openssl rand -base64 24 | tr -d '/+=' | head -c 32
     RCON_PASSWORD=change_me_before_first_start
     ```

3. **Untrack `.env`:**
   ```bash
   git rm --cached .env
   ```

4. **Append `.env` to `.gitignore`:**
   ```
   ### Project-specific ###
   # Environment file — contains secrets. Users copy .env.example → .env
   # locally and fill in real values. Never commit the real .env.
   .env
   ```

5. **Update docker-compose.yml — add `:?error` syntax to required vars:**
   ```yaml
   environment:
     POSTGRES_PASSWORD: ${DB_PASSWORD:?set in .env - see .env.example}
   ```
   Note: the error message **must not contain colons** — YAML parses them as mapping separators.

6. **Update any CI workflow that depends on `.env`** — generate ephemeral values:
   ```yaml
   - name: Generate test .env with ephemeral credentials
     run: |
       cat > .env <<EOF
       IMAGE_TAG=service:tag@sha256:digest
       DB_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)
       ADMIN_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)
       EOF
   ```

7. **Update the README** — one paragraph change:
   ```markdown
   ❗ Copy `.env.example` to `.env` and set `<required vars>` before first start.

   > ⚠️ **Security advisory.** Before this change, `.env` shipped with
   > hardcoded credentials in git history. Anyone who deployed using the
   > committed defaults should rotate those credentials immediately.
   ```

8. **Verify**, commit, push, PR. See [Verification gates → Phase 0](#phase-0-1).

### Commit message template

```
fix(security): untrack .env, add .env.example, enforce required vars at compose up

The repo's `.env` was tracked in git with hardcoded credentials:
- <list each credential>

Any user who followed the README literally and deployed without editing
`.env` ran their stack with those exact, publicly-known credentials.
This PR rotates the pattern so real credentials cannot live in the repo.

Changes:
- `.env` removed from tracking (git rm --cached). Old committed values
  remain in git history but are no longer referenced by any live code.
- `.env.example` (new) documents every variable with generation commands.
- docker-compose uses ${VAR:?} syntax for required vars — compose fails
  fast with a helpful error if user runs up without proper env.
- CI workflow generates ephemeral credentials (no committed .env).
- .gitignore explicit .env exclusion.
- README updated to describe cp .env.example .env workflow.

Anyone who deployed with the previous configuration should rotate
their production credentials.
```

---

## Phase 1 — Community files + scaffolding

**Goal:** `LICENSE`, `SECURITY.md`, `CHANGELOG.md`, upgraded Dependabot config, `FUNDING.yml` removed.

**Branch:** `chore/community-files-and-scaffolding`

### Steps

1. **Copy templates** from `templates/` in this runbook:
   ```bash
   RUNBOOK=~/repos/self-host-repo-hardening-runbook
   TARGET=~/repos/<target-repo>

   # LICENSE — replace {{YEAR_RANGE}} with e.g. "2021-2026"
   cp $RUNBOOK/templates/LICENSE.mit.tmpl $TARGET/LICENSE
   YEAR=$(cd $TARGET && git log --reverse --format=%ai | head -1 | cut -d- -f1)
   sed -i.bak "s/{{YEAR_RANGE}}/${YEAR}-2026/" $TARGET/LICENSE
   rm $TARGET/LICENSE.bak

   # SECURITY.md — adapt Supply Chain Trust section per repo
   cp $RUNBOOK/templates/SECURITY.md.tmpl $TARGET/SECURITY.md
   # then edit: replace {{UPSTREAM_IMAGES}} block with actual images

   # CHANGELOG.md — adapt Project-history paragraph
   cp $RUNBOOK/templates/CHANGELOG.md.tmpl $TARGET/CHANGELOG.md
   # then edit: replace {{REPO}} and {{YEAR_SPAN}}
   ```

2. **Replace `.github/dependabot.yml`** — identical across all repos:
   ```bash
   cp $RUNBOOK/templates/dependabot.yml $TARGET/.github/dependabot.yml
   ```

3. **Delete `.github/FUNDING.yml`:**
   ```bash
   git rm .github/FUNDING.yml
   ```

4. **Verify**, commit, push, PR. See [Verification gates → Phase 1](#phase-1-1).

### Commit message template

```
chore: add community health files + Dependabot grouping + docker ecosystem

Lands the scaffolding files and Dependabot config that the upcoming
workflow hardening and README rewrite PRs will depend on. No runtime
behaviour change.

Added:
- LICENSE (MIT, Copyright <YEAR_RANGE>)
- SECURITY.md (disclosure policy + supply-chain trust statement)
- CHANGELOG.md (Keep-a-Changelog format)

Changed:
- .github/dependabot.yml: added groups for both ecosystems; added
  docker ecosystem to track upstream image digest bumps.

Removed:
- .github/FUNDING.yml: sponsor discovery moves to heyvaldemar.com.
```

---

## Phase 2 — CI workflow hardening

**Goal:** pinned SHAs, per-job permissions, timeouts, concurrency, weekly cron, no-prefix filenames.

**Branch:** `ci/pinned-shas-and-workflow-hardening`

### Steps

1. **Rename the workflow** if it has a `00-` or similar prefix:
   ```bash
   git mv .github/workflows/00-deployment-verification.yml \
          .github/workflows/deployment-verification.yml
   ```

2. **Apply hardening template** — use `templates/deployment-verification.yml.tmpl` as the starting point. Preserve all the repo-specific `env:` block values (NETWORK names, hostnames, compose filename, project name).

3. **Pin every `uses:` line to a commit SHA** with a `# vX.Y.Z` comment. Use `scripts/dereference-github-tag.sh`:
   ```bash
   $RUNBOOK/scripts/dereference-github-tag.sh actions/checkout v6
   # → actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6
   ```

   **Critical:** some actions (notably `ossf/scorecard-action` and `github/codeql-action`) use **annotated tags** where `gh api /git/refs/tags/vX.Y.Z` returns a tag-object SHA. Scorecard's own imposter-commit check rejects tag-object SHAs. Use the dereference script — it handles this transparently.

4. **Update README badge URL** if the workflow was renamed:
   ```
   https://github.com/<owner>/<repo>/actions/workflows/deployment-verification.yml/badge.svg?branch=main
   ```

5. **Verify**, commit, push, PR. See [Verification gates → Phase 2](#phase-2-1).

### Commit message template

```
ci: pin SHAs + per-job permissions + timeouts + concurrency + weekly rebuild

Brings the CI workflow in line with the supply-chain hardening baseline.
No change to the workflow's logic — verification job still runs the
same docker compose stack.

Changes:
- Pinned <action> to commit SHA <sha> with # <version> comment.
  Tag references can be moved silently; commit SHAs cannot.
- Workflow-level permissions: contents: read. Per-job identical scope.
- timeout-minutes: 15 on the job.
- concurrency group keyed per-ref; cancel-in-progress only for PRs.
- Weekly cron (0 6 * * 1) to catch upstream image drift.
- workflow_dispatch trigger for manual runs.
- Renamed 00-deployment-verification.yml → deployment-verification.yml
  via git mv (history preserved).
- README badge URL updated to the new filename.
```

---

## Phase 3 — Upstream image digest pinning

**Goal:** pin every upstream image reference to `tag@sha256:...` so Dependabot can auto-open weekly bump PRs.

**Branch:** `feat/pin-upstream-image-digests`

### Steps

1. **Enumerate upstream images** from `.env.example`:
   ```bash
   grep -E '_IMAGE_TAG=' .env.example
   ```

2. **Resolve each digest** using `scripts/resolve-image-digest.sh`:
   ```bash
   $RUNBOOK/scripts/resolve-image-digest.sh traefik:3.2
   # → sha256:e561a37f8710d9cf41c78bdf421d822b2c0b48267ec0552e644565fb55466ea9

   $RUNBOOK/scripts/resolve-image-digest.sh postgres:16
   $RUNBOOK/scripts/resolve-image-digest.sh quay.io/keycloak/keycloak:26.2.5
   ```
   The script auto-detects Docker Hub (`library/...`), Quay.io, and GHCR.

3. **Update `.env.example`** — append `@sha256:<digest>` to each image tag:
   ```diff
   - TRAEFIK_IMAGE_TAG=traefik:3.2
   + TRAEFIK_IMAGE_TAG=traefik:3.2@sha256:e561a37f8710d9cf41c78bdf421d822b2c0b48267ec0552e644565fb55466ea9
   ```
   Also update the comment above each variable to mention Dependabot auto-bump:
   ```
   # <Service> image — pinned by tag + sha256 digest for reproducible deployments.
   # Dependabot's `docker` ecosystem auto-opens a PR weekly when the upstream
   # digest changes.
   ```

4. **Update CI workflow's ephemeral `.env` heredoc** — use the same digest-pinned values:
   ```yaml
   cat > .env <<EOF
   TRAEFIK_IMAGE_TAG=traefik:3.2@sha256:e561a37f...
   ...
   EOF
   ```

5. **Update CHANGELOG** — document the digest pins in `[Unreleased] → Changed`.

6. **Verify**:
   ```bash
   # docker compose should resolve each service with the full @sha256: reference
   docker compose --env-file .env.example.filled \
     -f <compose-file> config | grep "image:"
   ```

7. **Commit, push, PR.** See [Verification gates → Phase 3](#phase-3-1).

### Commit message template

```
feat(supply-chain): pin upstream images by sha256 digest (Dependabot auto-bumps)

Upgrades this deployment template from pinned-by-tag to pinned-by-tag-
plus-sha256-digest for the N upstream images it orchestrates:

- image-one:X.Y@sha256:<digest>
- image-two:X@sha256:<digest>
- <...>

Why: a tag can be silently re-pushed to a different manifest. A digest
cannot. Two users deploying this repo on different days now get
byte-identical image manifests regardless of upstream repushes.

Zero friction to stay current: Dependabot's `docker` ecosystem (added
in prior PR) auto-opens a weekly PR when any upstream digest changes.

No change to the compose file itself — it already uses ${VAR} references.
```

---

## Phase 4 — README rewrite

**Goal:** evaluator-first structure. Zero affiliate links, zero guru voice, zero crypto wallets. Preserve operationally valuable content (Backups, Restore, etc.).

**Branch:** `docs/readme-top-tier-rewrite`

### Steps

1. **Copy README skeleton:**
   ```bash
   cp $RUNBOOK/templates/README.md.tmpl $TARGET/README.md
   ```

2. **Fill the placeholders** (in order of appearance):
   - `{{TITLE}}` — "Keycloak + Traefik + Let's Encrypt — Docker Compose"
   - `{{SERVICE}}` — main service name (e.g. Keycloak, Nextcloud, Zabbix)
   - `{{SHORT_DESCRIPTION}}` — one-paragraph opener about what the stack is
   - `{{BLOG_LINK}}` — blog post URL if one exists
   - `{{COMPARISON_TABLE}}` — Why-this-stack table; service-specific row content, standard column headers
   - `{{FEATURES_LIST}}` — 8-12 bullets of what's in the stack
   - `{{USE_CASES}}` — 3-5 concrete scenarios (homelab, small team, dev sandbox, enterprise starting point, etc.)
   - `{{UPSTREAM_IMAGES}}` — 2-4 links (Docker Hub / Quay.io / GHCR) for images the stack orchestrates
   - `{{PRODUCTION_CHECKLIST}}` — 5-8 boxes; copy the Keycloak checklist shape and adapt per service
   - `{{OPS_CONTENT}}` — preserved Backups / Restore / Upgrade sections from the prior README; cleaned up prose but same functionality
   - `{{SECURITY_NOTES_BULLETS}}` — 4-6 bullets; include pre-rotation advisory if Phase 0 found committed credentials

3. **Strip the legacy content** — the pre-hardening README typically has:
   - "hey everyone" / "cutting my teeth" / "super detailed (seriously, they're foolproof!)" / "I'm stoked" / "Let's do this together!"
   - "My 2D Portfolio" (sre.gg), "My Courses" (Udemy affiliate), "My Services", "Patreon Exclusives"
   - "My Recommendations" kit.co affiliate links
   - "Follow Me" social-network wall (10+ links)
   - "Community of IT Experts" Discord invite
   - "Refill My Coffee Supplies" (PayPal / Patreon / BMC / Ko-fi / GitHub Sponsors)
   - BTC / ETH / BNB / LTC wallet addresses
   - "Show some 💜 by starring" + octocat GIF
   - Footer SVG

   All of it → **delete**. The compact `About the maintainer` footer from the skeleton replaces it.

4. **Verify** no legacy strings remain:
   ```bash
   grep -iEc "patreon|kit\.co|buymeacoffee|bc1q|0x76C|octocat|footer SVG|cutting my teeth|let's do this together|I'm stoked|My dream" README.md
   # Expected: 0
   ```

5. **Commit, push, PR.** See [Verification gates → Phase 4](#phase-4-1).

### Commit message template

Long form — the README rewrite is the most substantive PR. Use the [keycloak PR #16 commit message](https://github.com/heyvaldemar/keycloak-traefik-letsencrypt-docker-compose/pull/16) as the shape template.

---

## Phase 5 — OpenSSF Scorecard

**Goal:** weekly automated Scorecard run, results published to scorecard.dev viewer, SARIF uploaded to GitHub Security tab, badge in README.

**Branch:** `feat/openssf-scorecard-workflow`

### Steps

1. **Drop in the workflow** — `templates/scorecard.yml` is identical across all repos:
   ```bash
   cp $RUNBOOK/templates/scorecard.yml $TARGET/.github/workflows/scorecard.yml
   ```

2. **Add Scorecard badge to README** — between Deployment Verification and License badges:
   ```markdown
   [![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/<owner>/<repo>/badge)](https://scorecard.dev/viewer/?uri=github.com/<owner>/<repo>)
   ```

3. **Update CHANGELOG** — `[Unreleased] → Added` entry.

4. **Verify**, commit, push, PR. See [Verification gates → Phase 5](#phase-5-1).

### Commit message template

```
feat(ci): add OpenSSF Scorecard workflow + README badge

OpenSSF Scorecard scores public OSS repos on supply-chain security
posture. Runs weekly, publishes to scorecard.dev viewer, uploads SARIF
to GitHub Security tab.

Closes the 6-PR standards-alignment series for this repo.

Workflow:
- .github/workflows/scorecard.yml — matches heyvaldemar baseline.
- All four action pins are commit-SHA based with # vX.Y.Z comments.
- ossf/scorecard-action pinned to dereferenced commit SHA (not
  tag-object SHA) — Scorecard's imposter-commit check rejects the
  latter.

README: Scorecard badge between Deployment Verification and License.
```

---

## Verification gates

Run these checks after each phase, before merging. Each is a hard gate — if it fails, fix before merge.

### Phase 0

```bash
# .env not tracked
git ls-files | grep -E '^\.env$'  # expected: empty

# .env.example exists and is tracked
git ls-files | grep -E '^\.env\.example$'  # expected: .env.example

# compose fails fast without required vars
docker compose --env-file /dev/null -f <compose-file> config 2>&1 | grep -i "required variable"
# expected: matches — means :? enforcement works

# CI workflow no longer depends on committed .env
grep -c "cat > .env" .github/workflows/*.yml  # expected: 1 (the ephemeral-.env heredoc)
```

### Phase 1

```bash
# LICENSE exists and is ~1KB (canonical MIT)
wc -c LICENSE  # expected: ~1070-1100 bytes

# SECURITY.md + CHANGELOG.md tracked
git ls-files | grep -E '^(SECURITY|CHANGELOG)\.md$'  # expected: both

# FUNDING.yml gone
test -f .github/FUNDING.yml && echo "still present" || echo "removed"  # expected: removed

# Dependabot config parses and has both ecosystems
python3 -c "
import yaml
d = yaml.safe_load(open('.github/dependabot.yml'))
ecos = {u['package-ecosystem'] for u in d['updates']}
assert 'github-actions' in ecos, 'github-actions missing'
assert 'docker' in ecos, 'docker missing'
print('OK — both ecosystems present')
"
```

### Phase 2

```bash
# All uses: lines have commit-SHA pins with # comment
grep -E "uses:" .github/workflows/*.yml | grep -v '@[0-9a-f]\{40\}.*#.*v'
# expected: empty — no unpinned or comment-less uses

# Per-job permissions present
grep -c "permissions:" .github/workflows/deployment-verification.yml
# expected: >= 2 (workflow-level + job-level)

# timeout + concurrency + cron
grep -E "timeout-minutes|concurrency:|- cron:" .github/workflows/deployment-verification.yml
# expected: all three
```

### Phase 3

```bash
# All _IMAGE_TAG= values in .env.example contain @sha256:
awk -F= '/_IMAGE_TAG=/{print $2}' .env.example | grep -vc "@sha256:"
# expected: 0 (all image tags are digest-pinned)

# CI ephemeral .env has the same digests
grep "@sha256:" .github/workflows/deployment-verification.yml | wc -l
# expected: matches count in .env.example

# compose resolves with digest-pinned .env
cp .env.example /tmp/test.env
# fill in placeholders then:
docker compose --env-file /tmp/test.env -f <compose-file> config | grep "image:.*@sha256:"
# expected: every service shows image@sha256
```

### Phase 4

```bash
# No legacy guru voice / affiliate content
grep -iEc "patreon|kit\.co|buymeacoffee|bc1q|0x76C|octocat|footer SVG|cutting my teeth|let's do this together|I'm stoked|My dream|super detailed|seriously, they're foolproof" README.md
# expected: 0

# Has the canonical section structure
grep -c "^## " README.md  # expected: 8-12 top-level sections

# Compact footer, not full bio
grep -c "^### \(My 2D Portfolio\|My Courses\|My Services\|Patreon\|Recommendations\|Follow Me\|Refill\)" README.md
# expected: 0

# Blog link preserved (if applicable)
grep -c "heyvaldemar.com" README.md  # expected: >= 1
```

### Phase 5

```bash
# Scorecard workflow present + parses
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/scorecard.yml'))"
# expected: no error

# Scorecard badge in README between Deployment Verification and License
grep -A1 "Deployment Verification.*badge.svg" README.md | tail -1 | grep "OpenSSF Scorecard"
# expected: match

# All four scorecard.yml action pins are commit SHAs
grep "uses:" .github/workflows/scorecard.yml | grep -vc '@[0-9a-f]\{40\}'
# expected: 0
```

---

## Common pitfalls

### Pitfall 1 — Annotated tag SHA vs commit SHA

GitHub's `/git/refs/tags/vX.Y.Z` API returns the SHA of whatever the ref points at. For **lightweight tags**, that's a commit SHA. For **annotated tags**, that's a *tag object* SHA — which then points at the commit.

Scorecard's own imposter-commit check rejects tag-object SHAs. Pin a tag-object SHA and Scorecard refuses to publish results.

**Actions with annotated tags (require dereferencing):**

- `ossf/scorecard-action`
- `github/codeql-action` (and its sub-paths like `upload-sarif`)
- `actions/attest-build-provenance`
- `sigstore/cosign-installer`

**Actions with lightweight tags (SHA is direct):**

- `actions/checkout`
- `actions/upload-artifact`
- `docker/setup-qemu-action`
- `docker/setup-buildx-action`
- `docker/login-action`
- `docker/build-push-action`
- `docker/metadata-action`
- `hadolint/hadolint-action`
- `aquasecurity/trivy-action`
- `peter-evans/dockerhub-description`

**Use `scripts/dereference-github-tag.sh`** — it handles both cases transparently.

### Pitfall 2 — Colons in docker-compose `${VAR:?error}` messages

Compose error messages inside `${VAR:?message}` can't contain colons (YAML parser interprets them as mapping separators). Write messages like:

```
${VAR:?set in .env - see .env.example}
```

Not:

```
${VAR:?KEYCLOAK_DB_PASSWORD: generate via openssl rand: see .env.example}
```

### Pitfall 3 — Badge order matters

Recommended badge order (left-to-right):

```
Deployment Verification | OpenSSF Scorecard | License
```

For image-publishing repos add `Docker Pulls | Image Size | Cosign Verified` between Build Status and License.

Putting License first or last is conventional (CNCF repos use last). Security badges before legal.

### Pitfall 4 — `.env.example` as placeholder vs as canonical config

`.env.example` should ship **real, non-secret values** for things like image tags and URLs, but **`change_me_*` placeholders** for credentials. Not:

```
# Good
KEYCLOAK_IMAGE_TAG=quay.io/keycloak/keycloak:26.2.5@sha256:4883...
KEYCLOAK_ADMIN_PASSWORD=change_me_before_first_start
```

```
# Bad — no default image, forces extra research
KEYCLOAK_IMAGE_TAG=change_me_see_quay_io
```

```
# Bad — placeholder credential can silently ship to prod
KEYCLOAK_ADMIN_PASSWORD=admin123
```

The entrypoint / compose `${VAR:?}` enforcement catches the `change_me_*` case at runtime.

### Pitfall 5 — `git filter-repo` for credential vacuuming

If you find tracked credentials in Phase 0, the question is whether to rewrite git history. **Default answer: no.**

- Force-pushing rewritten history breaks every existing fork and local clone.
- Old committed values are cached in every mirror (GitHub, GH Archive, forks).
- The practical security gain is near-zero if you also rotated the live credential (which you must).

**Just rotate the live credential** and document the advisory in SECURITY.md + the Phase 0 PR body. Move on.

Use `git filter-repo` only if (a) the credential is still in active use somewhere hard to rotate, or (b) you have a disclosure obligation (e.g., GDPR-protected data was accidentally committed). Neither usually applies to homelab self-host templates.

---

## Rollout strategy

After the first repo (keycloak) takes ~10-12 hours, the second should take ~6 hours. By the fifth repo it's 3-4 hours each. The compounding factor is fluency — the first time you resolve three digests for the compose file is slow; the tenth time is a 30-second script invocation.

Recommended rollout order (highest-impact first):

1. Top 3-5 by stars — keycloak ✓, nextcloud, zabbix, gitlab, gitea
2. Next tier 6-15 — outline, minecraft, rocketchat, jira, grafana, ollama, confluence, vaultwarden, mattermost, ghost
3. Long tail — everything else. Consider archiving repos with <5 stars + no push in >2 years instead of hardening them.

Maintain the first 5 actively (merge Dependabot PRs weekly). The long tail can be tier-2 — apply this runbook's Phase 0-2 only (security + community + CI hardening) and skip Phases 3-5 on repos that don't warrant the ongoing Dependabot / Scorecard maintenance.
