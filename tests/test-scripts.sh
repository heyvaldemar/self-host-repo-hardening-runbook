#!/bin/bash
# What the runbook's scripts promise, with the network and GitHub replaced by
# fakes on PATH and the target repositories made in a temporary directory:
#   dereference-github-tag.sh  an annotated tag resolves to its COMMIT, not to
#                              the tag object Scorecard would reject
#   resolve-image-digest.sh    the manifest URL, the default tag, the token
#                              per registry, and the multi-arch index asked for
#   apply-phase-1.sh           the licence's year range from the first commit;
#                              an existing CHANGELOG is never overwritten;
#                              nothing is committed
#   apply-phase-5.sh           an existing scorecard.yml is never overwritten
#   templates/                 every action pinned by a 40-character commit SHA
# tests/plant-violations.py breaks each promise in a copy and requires this to
# notice.
#
#   ./tests/test-scripts.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASSED=0; FAILED=0
check() { if [ "$1" = "$2" ]; then echo "  PASS: $3"; PASSED=$((PASSED+1)); else echo "  FAIL: $3 (got '$1', wanted '$2')"; FAILED=$((FAILED+1)); fi; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/fixtures"

# --- fakes -------------------------------------------------------------------
# gh api <path>: the fixture named after the path, or exit 1 (not found).
cat > "$WORK/bin/gh" <<'SH'
#!/bin/bash
f="$FIXTURES/$(printf '%s' "$2" | tr '/' '_')"
[ -f "$f" ] || exit 1
cat "$f"
SH
# curl: records its arguments; a token URL answers a token, a HEAD answers a
# digest header unless NO_DIGEST is set.
cat > "$WORK/bin/curl" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$CALLS"
case "$*" in
  *"/token"*) echo '{"token":"t0ken"}' ;;
  *" -I "*|*"-I "*) [ -n "${NO_DIGEST:-}" ] || printf 'HTTP/1.1 200 OK\r\ndocker-content-digest: sha256:%064d\r\n' 7 ;;
esac
SH
chmod +x "$WORK/bin/gh" "$WORK/bin/curl"
export PATH="$WORK/bin:$PATH" FIXTURES="$WORK/fixtures" CALLS="$WORK/calls"
C40="c0ffee0000000000000000000000000000000001"
T40="7a90000000000000000000000000000000000002"
echo "{\"object\":{\"sha\":\"$T40\",\"type\":\"tag\"}}"    > "$FIXTURES/repos_o_annotated_git_refs_tags_v1"
echo "{\"object\":{\"sha\":\"$C40\",\"type\":\"commit\"}}" > "$FIXTURES/repos_o_annotated_git_tags_$T40"
echo "{\"object\":{\"sha\":\"$C40\",\"type\":\"commit\"}}" > "$FIXTURES/repos_o_light_git_refs_tags_v2"
echo "{\"object\":{\"sha\":\"$T40\",\"type\":\"tag\"}}"    > "$FIXTURES/repos_o_tree_git_refs_tags_v3"
echo "{\"object\":{\"sha\":\"$C40\",\"type\":\"tree\"}}"   > "$FIXTURES/repos_o_tree_git_tags_$T40"

echo "=== dereference-github-tag.sh"
D="$ROOT/scripts/dereference-github-tag.sh"
check "$(bash "$D" o/annotated v1 2>/dev/null)" "o/annotated@$C40 # v1" "an annotated tag resolves to its commit, not to the tag object"
check "$(bash "$D" o/light v2 2>/dev/null)" "o/light@$C40 # v2" "a lightweight tag resolves to the commit it names"
bash "$D" o/missing v9 >/dev/null 2>&1; check "$?" "1" "a tag that does not exist is an error"
bash "$D" o/tree v3 >/dev/null 2>&1; check "$?" "1" "a tag that does not point at a commit is an error"
bash "$D" only-one >/dev/null 2>&1; check "$?" "2" "a wrong argument count is a usage error"

echo "=== resolve-image-digest.sh"
R="$ROOT/scripts/resolve-image-digest.sh"
digest() { : > "$CALLS"; bash "$R" "$1" 2>/dev/null; }
check "$(digest postgres:16)" "sha256:$(printf '%064d' 7)" "prints the digest the registry returned"
check "$(grep -c 'registry-1.docker.io/v2/library/postgres/manifests/16' "$CALLS")" "1" "a bare name is a Docker Hub library image"
check "$(grep -c 'Authorization: Bearer t0ken' "$CALLS")" "1" "Docker Hub is asked with a token"
check "$(grep -c 'application/vnd.oci.image.index.v1+json' "$CALLS")" "1" "the multi-arch index is asked for, not one platform's manifest"
digest bitnami/keycloak >/dev/null
check "$(grep -c 'registry-1.docker.io/v2/bitnami/keycloak/manifests/latest' "$CALLS")" "1" "no tag means latest"
digest quay.io/keycloak/keycloak:26.2.5 >/dev/null
check "$(grep -c 'https://quay.io/v2/keycloak/keycloak/manifests/26.2.5' "$CALLS"):$(grep -c 'Authorization' "$CALLS")" "1:0" "quay.io is asked directly, without a token"
digest ghcr.io/o/image:t >/dev/null
check "$(grep -c 'ghcr.io/token?scope=repository:o/image:pull' "$CALLS"):$(grep -c 'https://ghcr.io/v2/o/image/manifests/t' "$CALLS")" "1:1" "ghcr.io is asked with an anonymous token"
NO_DIGEST=1 bash "$R" postgres:16 >/dev/null 2>&1; check "$?" "1" "no digest from the registry is an error, not an empty line"

echo "=== apply-phase-1.sh"
newrepo() {  # newrepo <dir>: a repository whose first commit is from 2021
  mkdir -p "$1" && git -C "$1" init -q && git -C "$1" config user.email t@t && git -C "$1" config user.name t
  git -C "$1" remote add origin https://github.com/acme/nextcloud-traefik-letsencrypt-docker-compose.git
  echo x > "$1/README.md"; mkdir -p "$1/.github"; echo "github: [x]" > "$1/.github/FUNDING.yml"
  git -C "$1" add -A && GIT_AUTHOR_DATE="2021-03-01T12:00:00" GIT_COMMITTER_DATE="2021-03-01T12:00:00" git -C "$1" commit -qm first
}
T1="$WORK/t1"; newrepo "$T1"; echo "keep me" > "$T1/CHANGELOG.md"; git -C "$T1" add -A && git -C "$T1" commit -qm changelog
bash "$ROOT/scripts/apply-phase-1.sh" "$T1" >/dev/null 2>&1
check "$?" "0" "phase 1 applies"
check "$(grep -c "2021-$(date +%Y)" "$T1/LICENSE")" "1" "the licence runs from the first commit's year to this year"
check "$(cat "$T1/CHANGELOG.md")" "keep me" "an existing CHANGELOG is never overwritten"
check "$(cmp -s "$T1/.github/dependabot.yml" "$ROOT/templates/dependabot.yml" && echo same)" "same" "dependabot.yml is the runbook's"
check "$([ -e "$T1/.github/FUNDING.yml" ] && echo present || echo gone)" "gone" "FUNDING.yml is removed"
check "$(git -C "$T1" rev-list --count HEAD)" "2" "nothing is committed: the tree is left for review"
T2="$WORK/t2"; newrepo "$T2"; bash "$ROOT/scripts/apply-phase-1.sh" "$T2" >/dev/null 2>&1
check "$(grep -c 'nextcloud-traefik-letsencrypt-docker-compose' "$T2/CHANGELOG.md" | awk '{print ($1 > 0) ? "named" : "not named"}')" "named" "a new CHANGELOG names the repository"
bash "$ROOT/scripts/apply-phase-1.sh" "$WORK" >/dev/null 2>&1; check "$?" "1" "a directory that is not a repository is refused"

echo "=== apply-phase-5.sh"
T3="$WORK/t3"; newrepo "$T3"
out="$(bash "$ROOT/scripts/apply-phase-5.sh" "$T3" 2>&1)"
check "$(cmp -s "$T3/.github/workflows/scorecard.yml" "$ROOT/templates/scorecard.yml" && echo same)" "same" "scorecard.yml is dropped in from the template"
check "$(grep -c 'github.com/acme/nextcloud-traefik-letsencrypt-docker-compose/badge' <<<"$out")" "1" "the badge line names this repository"
echo "# mine" > "$T3/.github/workflows/scorecard.yml"
bash "$ROOT/scripts/apply-phase-5.sh" "$T3" >/dev/null 2>&1
check "$(cat "$T3/.github/workflows/scorecard.yml")" "# mine" "an existing scorecard.yml is never overwritten"

echo "=== templates"
unpinned="$(grep -hE '^\s*uses:' "$ROOT"/templates/*.yml "$ROOT"/templates/*.tmpl | grep -vE '@[0-9a-f]{40}( |$)' || true)"
check "${unpinned:-none}" "none" "every action in every template is pinned by a commit SHA"

echo
echo "passed: $PASSED   failed: $FAILED"
[ "$FAILED" -eq 0 ]
