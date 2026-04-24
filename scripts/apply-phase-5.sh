#!/usr/bin/env bash
#
# Apply Phase 5 (OpenSSF Scorecard workflow) of the Self-Host Repo
# Hardening Runbook to a target repository.
#
# Drops in .github/workflows/scorecard.yml with all action pins already
# set to commit SHAs — including the dereferenced commit SHA for the
# annotated-tag ossf/scorecard-action@v2.4.3 that Scorecard's own
# imposter-commit check requires (a plain tag-object SHA would be
# rejected).
#
# What the script does NOT do:
#   - Add the README badge. Badge placement depends on existing badge
#     order and README structure; do this by hand.
#   - Update CHANGELOG.md. Content-specific; do this by hand.
#   - Commit or push.
#
# Usage:
#   ./apply-phase-5.sh <path-to-target-repo>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNBOOK_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

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
mkdir -p .github/workflows

DEST=".github/workflows/scorecard.yml"

if [[ -f "$DEST" ]]; then
  echo "⚠  $DEST already exists. Diffing against the runbook template:"
  echo
  diff -u "$DEST" "$RUNBOOK_ROOT/templates/scorecard.yml" || true
  echo
  echo "If the existing file is older or drifts from the template, replace manually after review."
  exit 0
fi

cp "$RUNBOOK_ROOT/templates/scorecard.yml" "$DEST"
echo "✔ $DEST copied."

# Extract owner/repo from remote for the README-badge reminder.
REPO_URL="$(git config --get remote.origin.url || echo '')"
REPO="$(echo "$REPO_URL" | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')"

echo
echo "Remaining manual steps:"
echo "  1. Add the OpenSSF Scorecard badge to README.md between the"
echo "     Deployment Verification badge and the License badge:"
echo
echo "     [![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/$REPO/badge)](https://scorecard.dev/viewer/?uri=github.com/$REPO)"
echo
echo "  2. Update CHANGELOG.md [Unreleased] → Added with the Scorecard entry."
echo "  3. Commit and push as the Phase-5 PR."
