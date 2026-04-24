#!/usr/bin/env bash
#
# Apply Phase 1 (community files + scaffolding) of the Self-Host Repo
# Hardening Runbook to a target repository.
#
# What the script does automatically:
#   - LICENSE: copies LICENSE.mit.tmpl with {{YEAR_RANGE}} substituted
#     from the target repo's first-commit year through the current year.
#   - SECURITY.md: copies SECURITY.md.tmpl verbatim if one does not exist
#     (placeholders for content-dependent fields are left in place with
#     {{PLACEHOLDER}} markers for manual fill).
#   - CHANGELOG.md: copies CHANGELOG.md.tmpl with {{REPO}}, {{SERVICE}},
#     and {{FIRST_COMMIT_YEAR}} substituted. Does NOT overwrite an
#     existing CHANGELOG.md.
#   - .github/dependabot.yml: drop-in copy (overwrites if present —
#     grouping + docker ecosystem are the new features).
#   - .github/FUNDING.yml: git-rm if present.
#
# What the script does NOT do:
#   - Commit or push. Leaves working tree dirty for human review.
#   - Fill content-dependent placeholders (upstream image list, unreleased
#     changelog entries, historical-advisory text). Those require per-repo
#     knowledge the script can't derive.
#
# Usage:
#   ./apply-phase-1.sh <path-to-target-repo>
#
# Example:
#   ./apply-phase-1.sh ~/repos/nextcloud-traefik-letsencrypt-docker-compose

set -euo pipefail

# --- Resolve script + runbook root ---

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNBOOK_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATES="$RUNBOOK_ROOT/templates"

# --- Args ---

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <path-to-target-repo>" >&2
  exit 2
fi

TARGET="$1"

if [[ ! -d "$TARGET/.git" ]]; then
  echo "Error: $TARGET is not a git repository" >&2
  exit 1
fi

cd "$TARGET"

# --- Derive substitution values from the target repo ---

FIRST_YEAR="$(git log --reverse --format=%ai | head -1 | cut -d- -f1)"
CURRENT_YEAR="$(date +%Y)"
YEAR_RANGE="${FIRST_YEAR}-${CURRENT_YEAR}"

REPO_URL="$(git config --get remote.origin.url || echo '')"
if [[ -z "$REPO_URL" ]]; then
  echo "Error: remote.origin.url not set on $TARGET" >&2
  exit 1
fi
# Strip both https:// and git@ forms, drop .git suffix → owner/repo
REPO="$(echo "$REPO_URL" | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')"
REPO_NAME="$(basename "$REPO")"
# Service slug: first dash-separated token (e.g. "nextcloud" from
# "nextcloud-traefik-letsencrypt-docker-compose").
SERVICE_SLUG="${REPO_NAME%%-*}"
# Capitalise first letter (portable to bash 3 / macOS default shell).
SERVICE_CAP="$(echo "$SERVICE_SLUG" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')"

echo "Target:       $TARGET"
echo "Repo:         $REPO"
echo "Service:      $SERVICE_CAP"
echo "Year range:   $YEAR_RANGE (first commit: $FIRST_YEAR)"
echo

# --- LICENSE ---

echo "→ LICENSE (copy + substitute {{YEAR_RANGE}})"
sed "s/{{YEAR_RANGE}}/$YEAR_RANGE/g" "$TEMPLATES/LICENSE.mit.tmpl" > LICENSE

# --- SECURITY.md ---

if [[ -f SECURITY.md ]]; then
  echo "→ SECURITY.md (exists — skipped to avoid overwriting)"
else
  echo "→ SECURITY.md (drop-in — {{UPSTREAM_IMAGES}} and other placeholders left for manual fill)"
  cp "$TEMPLATES/SECURITY.md.tmpl" SECURITY.md
fi

# --- CHANGELOG.md ---

if [[ -f CHANGELOG.md ]]; then
  echo "→ CHANGELOG.md (exists — skipped to avoid overwriting history)"
else
  echo "→ CHANGELOG.md (copy + substitute {{REPO}} / {{SERVICE}} / {{FIRST_COMMIT_YEAR}})"
  # Use # as delimiter so URLs with / don't need escaping.
  sed \
    -e "s#{{REPO}}#$REPO_NAME#g" \
    -e "s#{{FIRST_COMMIT_YEAR}}#$FIRST_YEAR#g" \
    -e "s#{{SERVICE}}#$SERVICE_CAP#g" \
    "$TEMPLATES/CHANGELOG.md.tmpl" > CHANGELOG.md
fi

# --- .github/dependabot.yml ---

mkdir -p .github
if [[ -f .github/dependabot.yml ]]; then
  echo "→ .github/dependabot.yml (overwriting — new version adds grouping + docker ecosystem)"
else
  echo "→ .github/dependabot.yml (drop-in)"
fi
cp "$TEMPLATES/dependabot.yml" .github/dependabot.yml

# --- FUNDING.yml removal ---

if [[ -f .github/FUNDING.yml ]]; then
  echo "→ .github/FUNDING.yml (removed via git rm)"
  git rm .github/FUNDING.yml
fi

# --- Done ---

echo
echo "✔ Phase 1 files applied."
echo
echo "Manual follow-ups before committing:"
echo "  1. SECURITY.md — fill {{SUPPORTED_VERSIONS_NOTE}}, {{UPSTREAM_IMAGES}},"
echo "     and {{HISTORICAL_ISSUE_OR_OMIT}} with service-specific content."
echo "  2. CHANGELOG.md — replace {{UNRELEASED_ENTRIES_OR_PLACEHOLDER}} with the"
echo "     Phase-1 change summary and {{YEAR_SPAN_MINOR}} with the project's"
echo "     iterative-update year span."
echo "  3. Verify the new .github/dependabot.yml reconciles against any prior"
echo "     local customisations (the template adds grouping + docker ecosystem)."
echo "  4. Commit and push as the Phase-1 PR."
echo
echo "See RUNBOOK.md → Phase 1 for the commit-message template."
