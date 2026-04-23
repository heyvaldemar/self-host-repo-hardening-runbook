#!/usr/bin/env bash
#
# Resolve a GitHub action reference like `ossf/scorecard-action@v2.4.3` to
# the underlying commit SHA, transparently dereferencing annotated tags.
#
# Usage:
#   ./dereference-github-tag.sh OWNER/REPO TAG
#
# Examples:
#   ./dereference-github-tag.sh actions/checkout v6
#     → actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6
#   ./dereference-github-tag.sh ossf/scorecard-action v2.4.3
#     → ossf/scorecard-action@4eaacf0543bb3f2c246792bd56e8cdeffafb205a # v2.4.3
#
# Why this script exists:
#   GitHub's /git/refs/tags/<tag> API returns a tag-object SHA for annotated
#   tags. Pinning that SHA in a workflow's `uses:` line causes Scorecard's
#   imposter-commit check to fail (since the tag-object SHA doesn't appear in
#   the action's commit history). This script dereferences automatically.
#
# Requires: gh CLI authenticated against github.com.
set -euo pipefail

if [ $# -ne 2 ]; then
  echo "Usage: $0 OWNER/REPO TAG" >&2
  echo "Example: $0 ossf/scorecard-action v2.4.3" >&2
  exit 2
fi

REPO="$1"
TAG="$2"

if ! command -v gh >/dev/null 2>&1; then
  echo "ERROR: 'gh' CLI is required but not installed." >&2
  echo "       Install: https://cli.github.com/" >&2
  exit 1
fi

# Step 1: look up the ref.
REF_JSON=$(gh api "repos/${REPO}/git/refs/tags/${TAG}" 2>/dev/null) || {
  echo "ERROR: tag ${TAG} not found on ${REPO}" >&2
  exit 1
}

OBJ_SHA=$(printf '%s' "$REF_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["object"]["sha"])')
OBJ_TYPE=$(printf '%s' "$REF_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["object"]["type"])')

# Step 2: dereference if the tag is annotated.
if [ "$OBJ_TYPE" = "tag" ]; then
  # Annotated tag → fetch the tag object, extract its commit SHA.
  TAG_OBJ_JSON=$(gh api "repos/${REPO}/git/tags/${OBJ_SHA}")
  COMMIT_SHA=$(printf '%s' "$TAG_OBJ_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["object"]["sha"])')
  FINAL_TYPE=$(printf '%s' "$TAG_OBJ_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["object"]["type"])')
  if [ "$FINAL_TYPE" != "commit" ]; then
    echo "ERROR: annotated tag dereferenced to '$FINAL_TYPE', expected 'commit'" >&2
    exit 1
  fi
elif [ "$OBJ_TYPE" = "commit" ]; then
  # Lightweight tag → the ref SHA IS the commit SHA.
  COMMIT_SHA="$OBJ_SHA"
else
  echo "ERROR: unexpected object type '$OBJ_TYPE' for ${REPO}@${TAG}" >&2
  exit 1
fi

# Output the `uses:` line ready to paste into a workflow.
printf '%s@%s # %s\n' "$REPO" "$COMMIT_SHA" "$TAG"
