#!/usr/bin/env bash
#
# Resolve an image reference (e.g. `postgres:16`, `traefik:3.2`,
# `quay.io/keycloak/keycloak:26.2.5`, `ghcr.io/owner/image:tag`) to its
# `sha256:...` manifest digest via the registry v2 API.
#
# Usage:
#   ./resolve-image-digest.sh IMAGE[:TAG]
#
# Examples:
#   ./resolve-image-digest.sh postgres:16
#   ./resolve-image-digest.sh traefik:3.2
#   ./resolve-image-digest.sh quay.io/keycloak/keycloak:26.2.5
#   ./resolve-image-digest.sh ghcr.io/owner/image:tag
#
# Returns the multi-arch manifest index digest (not a platform-specific
# manifest). Multi-arch pulls continue to work on amd64 and arm64.
set -euo pipefail

if [ $# -ne 1 ]; then
  echo "Usage: $0 IMAGE[:TAG]" >&2
  exit 2
fi

REF="$1"
TAG="${REF##*:}"
REPO="${REF%:*}"

# If no tag was provided, default to "latest".
if [ "$REF" = "$REPO" ]; then
  TAG="latest"
fi

case "$REPO" in
  */*)
    # Registry-qualified or user/org-qualified reference.
    if [[ "$REPO" == quay.io/* ]]; then
      REGISTRY="quay.io"
      REPO_PATH="${REPO#quay.io/}"
      TOKEN=""
    elif [[ "$REPO" == ghcr.io/* ]]; then
      REGISTRY="ghcr.io"
      REPO_PATH="${REPO#ghcr.io/}"
      # GHCR public packages accept anonymous token; fetch one.
      TOKEN=$(curl -fsSL "https://ghcr.io/token?scope=repository:${REPO_PATH}:pull" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin).get("token",""))')
    else
      # owner/repo on Docker Hub (e.g., `bitnami/keycloak:latest`).
      REGISTRY="registry-1.docker.io"
      REPO_PATH="$REPO"
      TOKEN=$(curl -fsSL "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${REPO_PATH}:pull" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')
    fi
    ;;
  *)
    # Bare repo name → Docker Hub library (e.g., `postgres:16`).
    REGISTRY="registry-1.docker.io"
    REPO_PATH="library/${REPO}"
    TOKEN=$(curl -fsSL "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${REPO_PATH}:pull" \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')
    ;;
esac

AUTH_HEADER=""
if [ -n "$TOKEN" ]; then
  AUTH_HEADER="Authorization: Bearer ${TOKEN}"
fi

DIGEST=$(curl -sS -I \
  ${AUTH_HEADER:+-H "$AUTH_HEADER"} \
  -H "Accept: application/vnd.oci.image.index.v1+json" \
  -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json" \
  -H "Accept: application/vnd.oci.image.manifest.v1+json" \
  -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
  "https://${REGISTRY}/v2/${REPO_PATH}/manifests/${TAG}" \
  | awk 'tolower($0) ~ /^docker-content-digest:/ { print $2 }' \
  | tr -d '\r\n')

if [ -z "$DIGEST" ]; then
  echo "ERROR: no docker-content-digest returned for ${REF}" >&2
  echo "       Check the image reference is correct and the registry is reachable." >&2
  exit 1
fi

echo "${DIGEST}"
