# The Image-Publishing Runbook: Step by Step

Six phases. One PR each. Merge between phases so CI stays green and history is readable.

This is the companion runbook to [`RUNBOOK.md`](RUNBOOK.md). Use this one when the repository's deliverable is a Docker image you build and publish (e.g. [`aws-kubectl-docker`](https://github.com/heyvaldemar/aws-kubectl-docker)). Use `RUNBOOK.md` when the deliverable is a Docker Compose deployment template (e.g. [`keycloak-traefik-letsencrypt-docker-compose`](https://github.com/heyvaldemar/keycloak-traefik-letsencrypt-docker-compose)).

If you are not sure which runbook applies, see [`README.md`](README.md) → "Which runbook do I need?".

## Contents

- [Pre-flight (once per repo)](#pre-flight-once-per-repo)
- [Phase 0: Dockerfile hardening](#phase-0-dockerfile-hardening)
- [Phase 1: Community files + smoke test](#phase-1-community-files--smoke-test)
- [Phase 2: CI publish workflow](#phase-2-ci-publish-workflow)
- [Phase 3: README rewrite](#phase-3-readme-rewrite)
- [Phase 4: OpenSSF Scorecard](#phase-4-openssf-scorecard)
- [Phase 5: Tag retention + Docker Hub immutability](#phase-5-tag-retention--docker-hub-immutability)
- [Optional: Non-root migration (BREAKING CHANGE for existing :latest users)](#optional-non-root-migration-breaking-change-for-existing-latest-users)
- [Optional: Architecture Decision Records](#optional-architecture-decision-records)
- [Verification gates](#verification-gates)
- [Common pitfalls](#common-pitfalls)
- [Rollout strategy](#rollout-strategy)

---

## Pre-flight (once per repo)

```bash
cd ~/repos
git clone https://github.com/<owner>/<image-repo>-docker
cd <image-repo>-docker

# Confirm on main, clean tree
git status
git branch --show-current

# Get the first-commit year, you'll need it for LICENSE
git log --reverse --format=%ai | head -1 | cut -d- -f1

# Read the current state. Look for:
# - Dockerfile: single-stage? multi-stage? base image pinned by tag or by digest?
#   Already runs as non-root, or implicitly root?
# - .github/workflows/: existing publish workflow? what does it do?
# - .github/FUNDING.yml: exists? Phase 1 removes it.
# - .github/dependabot.yml: what ecosystems?
# - LICENSE / SECURITY.md / CHANGELOG.md: usually present on older repos but
#   often pre-Keep-a-Changelog.
# - scripts/: smoke-test.sh? cleanup-legacy-tags.sh? usually absent.
ls Dockerfile LICENSE SECURITY.md CHANGELOG.md .dockerignore .hadolint.yaml 2>&1
find .github -type f
head -20 Dockerfile
```

**Decide upfront:**

- Does the repo already have public consumers on `:latest`? If yes and Phase 0 includes a non-root switch, the non-root change becomes a BREAKING CHANGE that needs the optional migration phase. For fresh repos, fold non-root into Phase 0.
- Does the image have a Docker Hub presence today? If yes, you'll need Docker Hub PAT + `peter-evans/dockerhub-description` for the README sync step in Phase 2 and the tag immutability + cleanup steps in Phase 5.

---

## Phase 0: Dockerfile hardening

**Goal:** multi-stage Dockerfile with a digest-pinned base image, full OCI labels, non-root runtime user (UID 10001, GID 0), `.dockerignore`, `.hadolint.yaml`. Build-only tooling stays in the builder stage.

**Branch:** `feat/dockerfile-hardening`

### Steps

1. **Convert to multi-stage** if not already. The `builder` stage downloads, verifies, and unpacks payload binaries. The `final` stage installs only the runtime toolchain and copies pre-built artefacts from the builder. Build-only tools (`unzip`, build deps) live in the builder and never enter the final image.

2. **Pin the base image by digest.** Tags are mutable. Digests are not.

   ```dockerfile
   # syntax=docker/dockerfile:1.7

   # Digest pinned; Dependabot's docker ecosystem will bump this weekly.
   FROM ubuntu:24.04@sha256:<digest> AS builder
   ...
   FROM ubuntu:24.04@sha256:<digest> AS final
   ```

   Resolve the current digest with `scripts/resolve-image-digest.sh`:

   ```bash
   $RUNBOOK/scripts/resolve-image-digest.sh ubuntu:24.04
   # → sha256:c4a8d5503dfb...
   ```

   Both `FROM` lines reference the same digest.

3. **Verify checksum-able payload binaries during the build.** When the image bundles a binary fetched from a vendor URL (`kubectl`, `aws-cli`, `terraform`, etc.), download the upstream-published `sha256` checksum and verify before installing. Example for `kubectl`:

   ```dockerfile
   RUN curl -fsSLo kubectl  "https://dl.k8s.io/release/${KUBE_VERSION}/bin/linux/${KARCH}/kubectl" \
    && curl -fsSLo kubectl.sha256 "https://dl.k8s.io/release/${KUBE_VERSION}/bin/linux/${KARCH}/kubectl.sha256" \
    && echo "$(cat kubectl.sha256)  kubectl" | sha256sum -c - \
    && install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
   ```

   No `curl | bash`. No unverified downloads.

4. **Add full OCI labels** to the final stage. These show up in `docker image inspect`, on Docker Hub, in registry browsers, and let downstream tooling (Renovate, Trivy, container security scanners) link the image back to its source:

   ```dockerfile
   ARG VCS_REF=unknown
   ARG BUILD_DATE=unknown

   LABEL org.opencontainers.image.title="<image-name>" \
         org.opencontainers.image.description="<one-paragraph description>" \
         org.opencontainers.image.authors="Vladimir Mikhalev <v@valdemar.ai>" \
         org.opencontainers.image.vendor="heyvaldemar" \
         org.opencontainers.image.source="https://github.com/heyvaldemar/<repo>" \
         org.opencontainers.image.documentation="https://github.com/heyvaldemar/<repo>#readme" \
         org.opencontainers.image.url="https://hub.docker.com/r/heyvaldemar/<image>" \
         org.opencontainers.image.licenses="MIT" \
         org.opencontainers.image.revision="${VCS_REF}" \
         org.opencontainers.image.created="${BUILD_DATE}" \
         io.heyvaldemar.<custom-key>="${<value>}"
   ```

   `VCS_REF` and `BUILD_DATE` are stamped by CI from `${{ github.sha }}` and `date -u +'%Y-%m-%dT%H:%M:%SZ'` (see Phase 2). The `io.heyvaldemar.*` custom labels surface domain-specific facts that don't fit the OCI namespace, for example, the resolved upstream version of a bundled binary.

5. **Create a non-root runtime user** with UID 10001 and primary GID 0.

   ```dockerfile
   # Create non-root user with UID 10001 and primary GID 0 (root group).
   # GID 0 is OpenShift SCC compatible: OpenShift assigns random UIDs at runtime
   # but always uses GID 0 for file ownership. Files owned by root group remain
   # readable/writable. Also works on vanilla Kubernetes, Docker Desktop, and CI.
   # UID 10001 is outside the standard user range (1000-9999) to avoid host UID
   # collisions on developer machines.
   RUN useradd --system --uid 10001 --gid 0 \
         --home-dir /home/app --shell /sbin/nologin \
         --comment "<image-name> runtime user" app \
    && mkdir -p /home/app \
    && chown -R 10001:0 /home/app \
    && chmod -R g=u /home/app

   # HOME must be set explicitly for tooling that resolves cache paths (~/.kube,
   # ~/.aws, ~/.cache, etc.), otherwise they fall back to / under the random
   # OpenShift UID and break.
   ENV HOME=/home/app

   WORKDIR /home/app

   USER 10001:0

   CMD ["bash"]
   ```

   The combination "UID 10001, GID 0" is the OpenShift Security Context Constraint (SCC) `restricted-v2` and Kubernetes `restricted` Pod Security Standard contract: any UID, primary GID 0, no privilege escalation. Pinning UID 10001 specifically avoids host UID collisions on Ubuntu/Debian developer machines (their default `useradd` starts at 1000).

   For an image with an existing `:latest` audience, the user-switch is a BREAKING CHANGE. See [Optional: Non-root migration](#optional-non-root-migration-breaking-change-for-existing-latest-users) for the migration flow with a `v1-maintenance` escape hatch.

6. **Add `.dockerignore`** at repo root:

   ```
   .git
   .github
   .gitignore
   .dockerignore
   .hadolint.yaml
   *.md
   LICENSE
   scripts
   ```

   Smaller build context = faster builds + fewer accidental leaks.

7. **Add `.hadolint.yaml`** at repo root. Document any exceptions:

   ```yaml
   # hadolint configuration
   # See https://github.com/hadolint/hadolint/wiki for rule reference.

   ignored:
     # DL3008, pin apt versions. Intentionally unpinned: the weekly base image
     # rebuild (publish.yml cron) is the upgrade path. Pinning would defeat it.
     - DL3008
   ```

8. **Verify** locally:

   ```bash
   # Build succeeds for the host arch
   docker build -t <image>:local .

   # Image runs as non-root
   docker run --rm <image>:local id
   # → uid=10001 gid=0(root)

   # Hadolint clean
   docker run --rm -i hadolint/hadolint:latest < Dockerfile
   ```

9. **Commit, push, PR.** See [Verification gates → Phase 0](#phase-0).

### Commit message template

```
feat(dockerfile): multi-stage build with digest-pinned base, OCI labels, non-root user

Lands the foundation for the supply-chain hardening track:
- Multi-stage build separates download/verify/unpack from runtime —
  build-only tooling (e.g., unzip, build deps) no longer lands in the
  published image.
- Base image pinned by sha256 digest, not tag. Dependabot's docker
  ecosystem (added in Phase 1 PR) auto-bumps the digest weekly.
- Full OCI labels (org.opencontainers.image.*) plus domain-specific
  io.heyvaldemar.* labels stamped at build time from VCS_REF and
  BUILD_DATE build args.
- Runtime user is now UID 10001 with primary GID 0, HOME=/home/app.
  GID 0 is OpenShift SCC `restricted-v2` compatible. Users who need
  root inside the container override with `--user 0:0`.
- .dockerignore excludes repo metadata from the build context.
- .hadolint.yaml documents the DL3008 exception (unpinned apt; the
  weekly base rebuild is the upgrade path).
```

For repos with existing `:latest` users, this PR becomes a BREAKING CHANGE: see [Optional: Non-root migration](#optional-non-root-migration-breaking-change-for-existing-latest-users) for the additional steps (`v1-maintenance` branch, README "Breaking Changes in vX.0" section, SECURITY.md "Supported Versions" date-bound row, CHANGELOG `BREAKING CHANGES` block).

---

## Phase 1: community files + smoke test

**Goal:** `LICENSE`, `SECURITY.md`, `CHANGELOG.md`, upgraded Dependabot config, `FUNDING.yml` removed, plus a local `scripts/smoke-test.sh` that exercises every binary the image advertises.

**Branch:** `chore/community-files-and-smoke-test`

### Steps

1. **Run the helper script** to drop the community files into the target repo. This is the same script used for Type B repos. Phase 1 community files are the same shape regardless of repo type.

   ```bash
   RUNBOOK=~/repos/self-host-repo-hardening-runbook
   TARGET=~/repos/<image-repo>-docker

   $RUNBOOK/scripts/apply-phase-1.sh $TARGET
   ```

   The script leaves the working tree dirty for review. Expected post-run state:
   - `LICENSE`: `{{YEAR_RANGE}}` substituted to `<first-commit-year>-<current-year>`.
   - `SECURITY.md`: drop-in copy with `{{SUPPORTED_VERSIONS_NOTE}}`, `{{UPSTREAM_IMAGES}}`, `{{HISTORICAL_ISSUE_OR_OMIT}}` placeholders left for manual fill.
   - `CHANGELOG.md`: `{{REPO}}`, `{{SERVICE}}`, `{{FIRST_COMMIT_YEAR}}` auto-substituted; `{{UNRELEASED_ENTRIES_OR_PLACEHOLDER}}` and `{{YEAR_SPAN_MINOR}}` marked for manual fill.
   - `.github/dependabot.yml`: drop-in copy with `github-actions` + `docker` ecosystems, both grouped on minor/patch.
   - `.github/FUNDING.yml`: removed via `git rm` if it existed.

2. **Adapt SECURITY.md to the image-publishing flavor.** The default template assumes a deployment-template repo. For an image-publishing repo, the relevant claims are different:

   - "This repository publishes a Docker image at `hub.docker.com/r/heyvaldemar/<image>`." (not "deployment template").
   - "Every published digest is signed with cosign using Sigstore keyless OIDC issued to this repository's GitHub Actions workflow."
   - "SBOM (SPDX, generated by BuildKit) and SLSA build provenance (`provenance: mode=max`) attestations are attached to every digest."
   - "GitHub native build provenance is also generated via `actions/attest-build-provenance` and is available at `/attestations`."
   - "Trivy scans run on every published image and surface CRITICAL and HIGH fixable findings in this repository's GitHub Security tab."

   See [aws-kubectl-docker `SECURITY.md`](https://github.com/heyvaldemar/aws-kubectl-docker/blob/main/SECURITY.md) for the canonical shape, including the `cosign verify` command users run to validate the signature before deploy.

3. **Add `scripts/smoke-test.sh`.** The smoke test is a standalone bash script users (and you) can run against any tag of the image to verify the advertised toolchain. Pattern (taken verbatim from [aws-kubectl-docker](https://github.com/heyvaldemar/aws-kubectl-docker/blob/main/scripts/smoke-test.sh), adapt the binary list to match what your image bundles):

   ```bash
   #!/usr/bin/env bash
   # Smoke test for heyvaldemar/<image> images.
   # Verifies the advertised toolchain is present, working, and consistent with
   # any version markers baked in at build time.
   set -euo pipefail

   IMAGE="${1:-<image>:local}"

   say() { printf '\n>>> %s\n\n' "$*"; }
   run() {
     echo "+ $*"
     sh -c "$*"
     echo
   }

   say "Image: $IMAGE"

   # Core toolchain: every binary must respond. No `|| true` fallbacks for the
   # advertised toolchain, a missing binary is a test failure.
   run "docker run --rm '$IMAGE' <bin1> --version"
   run "docker run --rm '$IMAGE' <bin2> --version"
   ...

   # Binary presence + CA bundle (most non-trivial images need outbound HTTPS).
   run "docker run --rm '$IMAGE' sh -c 'ls -lh /etc/ssl/certs/ca-certificates.crt'"
   run "docker run --rm '$IMAGE' sh -c 'curl -fsSI -o /dev/null -w \"HTTPS OK (%{http_code})\\n\" https://example.com'"

   # Optional real-world checks, these require host config and ARE allowed to
   # fail silently. Pattern: `|| true` so a missing host config doesn't fail
   # the smoke test, but the output still shows what happened.
   if [ -d "${HOME}/<config-dir>" ]; then
     run "docker run --rm --user \"$(id -u):0\" -v '${HOME}/<config-dir>:/home/app/<config-dir>' '$IMAGE' <real-cmd> || true"
   fi

   say "All checks passed."
   ```

   Mark it executable (`chmod +x scripts/smoke-test.sh`) and reference it from the README's "Local Build & Test" section in Phase 3.

4. **Verify, commit, push, PR.** See [Verification gates → Phase 1](#phase-1).

### Commit message template

```
chore: add community health files + Dependabot grouping + smoke test

Lands the scaffolding files and Dependabot config that the upcoming
CI publish workflow PR will depend on. Plus a local smoke-test script
that exercises every binary the image advertises.

Added:
- LICENSE (MIT, Copyright <YEAR_RANGE>)
- SECURITY.md (disclosure policy + supply-chain trust statement
  describing cosign / SBOM / SLSA / Trivy posture for this image)
- CHANGELOG.md (Keep-a-Changelog format)
- scripts/smoke-test.sh (verifies advertised toolchain across any tag)

Changed:
- .github/dependabot.yml: added groups for both ecosystems; added
  docker ecosystem to track upstream base image digest bumps.

Removed:
- .github/FUNDING.yml: sponsor discovery moves to heyvaldemar.com.
```

---

## Phase 2: CI publish workflow

**Goal:** `.github/workflows/publish.yml` that lints, builds multi-arch, attaches BuildKit SBOM + SLSA provenance, signs with cosign, attests with `actions/attest-build-provenance`, scans with Trivy, and syncs the README to Docker Hub. PR builds run the build but skip everything that requires registry credentials.

**Branch:** `ci/publish-workflow-with-supply-chain-attestations`

### Job topology

| Job | Trigger | Blocks merge? | What it does |
|---|---|---|---|
| `lint` | push, PR, schedule, manual | ✅ yes | hadolint + shellcheck |
| `build` | push, PR, schedule, manual | ✅ yes (the publish step is conditional) | multi-arch buildx + BuildKit attestations + cosign sign + GitHub provenance attestation. PR runs build with `push: false`. |
| `scan-trivy` | post-build, non-PR only | ❌ `continue-on-error: true` | Trivy scan of the published digest, SARIF to GitHub Security tab |
| `dockerhub-description` | push to main only | ❌ | Sync README.md to Docker Hub via `peter-evans/dockerhub-description` |

### Steps

1. **Define triggers**: push to main, semver tag pushes, PRs, weekly cron for upstream base-image drift, manual dispatch:

   ```yaml
   on:
     push:
       branches: [main]
       tags: ["v*.*.*"]
     pull_request:
       branches: [main]
     schedule:
       # Weekly rebuild to pick up upstream base image security updates.
       - cron: "0 6 * * 1"
     workflow_dispatch:

   concurrency:
     group: publish-${{ github.ref }}
     cancel-in-progress: ${{ github.event_name == 'pull_request' }}
   ```

   Concurrency only cancels in-progress on PR pushes. Branch and tag builds always complete so signatures and attestations don't get orphaned.

2. **`lint` job**: hadolint on the Dockerfile, shellcheck on every `*.sh` in `scripts/`. 5-minute timeout. `contents: read` only.

   ```yaml
   lint:
     runs-on: ubuntu-latest
     timeout-minutes: 5
     permissions:
       contents: read
     steps:
       - uses: actions/checkout@<sha> # v6
       - uses: hadolint/hadolint-action@<sha> # v3.3.0
         with:
           dockerfile: Dockerfile
           config: .hadolint.yaml
       - name: ShellCheck
         run: |
           shellcheck --version
           shopt -s nullglob globstar
           shellcheck scripts/**/*.sh
   ```

3. **`build` job**: multi-arch build with BuildKit attestations, cosign keyless signing, GitHub native attestation. Permissions narrowed per-job:

   ```yaml
   build:
     needs: lint
     runs-on: ubuntu-latest
     timeout-minutes: 30
     permissions:
       contents: read
       packages: write
       id-token: write
       attestations: write
       security-events: write
     outputs:
       digest: ${{ steps.build.outputs.digest }}
   ```

   Steps inside the job: pin every `uses:` line to a commit SHA with a `# vX.Y.Z` comment using `scripts/dereference-github-tag.sh`:

   ```yaml
   - name: Checkout
     uses: actions/checkout@<sha> # v6

   - name: Compute build metadata
     id: meta-build
     run: |
       set -euo pipefail
       echo "build_date=$(date -u +'%Y-%m-%dT%H:%M:%SZ')" >> "$GITHUB_OUTPUT"
       echo "vcs_ref=${GITHUB_SHA}" >> "$GITHUB_OUTPUT"

   - name: Set up QEMU
     uses: docker/setup-qemu-action@<sha> # v4

   - name: Set up Docker Buildx
     uses: docker/setup-buildx-action@<sha> # v4

   - name: Login to Docker Hub
     if: github.event_name != 'pull_request'
     uses: docker/login-action@<sha> # v4
     with:
       username: ${{ secrets.DOCKERHUB_USERNAME }}
       password: ${{ secrets.DOCKERHUB_TOKEN }}

   - name: Docker image metadata
     id: meta
     uses: docker/metadata-action@<sha> # v6.0.0
     with:
       images: ${{ env.IMAGE_NAME }}
       flavor: |
         latest=false
       tags: |
         type=raw,value=latest,enable={{is_default_branch}}
         type=raw,value=edge,enable={{is_default_branch}}
         type=ref,event=tag
         type=semver,pattern={{version}}
         type=semver,pattern={{major}}.{{minor}}
         type=semver,pattern={{major}}
         type=sha,prefix=sha-,format=short
       labels: |
         org.opencontainers.image.title=<image-name>
         org.opencontainers.image.description=<one-paragraph>
         org.opencontainers.image.vendor=heyvaldemar
         org.opencontainers.image.licenses=MIT

   - name: Build and push
     id: build
     uses: docker/build-push-action@<sha> # v7
     timeout-minutes: 20
     with:
       context: .
       file: Dockerfile
       platforms: linux/amd64,linux/arm64
       push: ${{ github.event_name != 'pull_request' }}
       pull: true
       tags: ${{ steps.meta.outputs.tags }}
       labels: ${{ steps.meta.outputs.labels }}
       build-args: |
         VCS_REF=${{ steps.meta-build.outputs.vcs_ref }}
         BUILD_DATE=${{ steps.meta-build.outputs.build_date }}
       cache-from: type=gha
       cache-to: type=gha,mode=max
       sbom: true
       provenance: mode=max
   ```

   `flavor: latest=false` is critical: without it, semver tag pushes also retag `:latest`, which causes immutability conflicts once the Docker Hub immutability policy from Phase 5 is in place. With `latest=false`, only the explicit `type=raw,value=latest,enable={{is_default_branch}}` tag rule re-tags `:latest`, and only on main branch pushes.

   `sbom: true` and `provenance: mode=max` are the BuildKit attestation flags. `mode=max` includes full provenance (build environment, materials, configuration). The `min` mode strips the materials section.

4. **GitHub native build provenance attestation:**

   ```yaml
   - name: Attest build provenance
     if: github.event_name != 'pull_request'
     uses: actions/attest-build-provenance@<sha> # v4.1.0
     with:
       subject-name: ${{ env.IMAGE_NAME }}
       subject-digest: ${{ steps.build.outputs.digest }}
       # Docker Hub OCI referrers credential handoff is unreliable here; the
       # attestation remains available via GitHub Attestations storage.
       push-to-registry: false
   ```

   The `push-to-registry: false` is deliberate. The action can push the attestation to the registry as an OCI referrer sidecar, but Docker Hub's OCI referrer credential handoff proved unreliable in practice (see [aws-kubectl-docker hotfix #20](https://github.com/heyvaldemar/aws-kubectl-docker/pull/20)). Keep `push-to-registry: false`. The attestation remains discoverable via GitHub Attestations at `https://github.com/heyvaldemar/<repo>/attestations`.

5. **Cosign keyless signing.** Pin `cosign-installer` to a commit SHA AND pin Cosign itself to v2.6.1 explicitly:

   ```yaml
   - name: Install cosign
     if: github.event_name != 'pull_request'
     # Install Cosign v2.6.1 explicitly: cosign-installer v4 defaults to Cosign
     # v3.x, which changes container signature storage to OCI 1.1 referring
     # artifacts. Docker Hub's OCI referrer credential handoff proved unreliable
     # in practice. Cosign v2 keeps tag-based .sig storage which works reliably
     # on Docker Hub today. Full Cosign v3 migration is deferred to a separate
     # tracked project.
     uses: sigstore/cosign-installer@<sha> # v4.1.1
     with:
       cosign-release: "v2.6.1"

   - name: Sign image with cosign (keyless)
     if: github.event_name != 'pull_request'
     env:
       TAGS: ${{ steps.meta.outputs.tags }}
       DIGEST: ${{ steps.build.outputs.digest }}
     run: |
       set -euo pipefail
       if [ -z "${TAGS}" ] || [ -z "${DIGEST}" ]; then
         echo "ERROR: TAGS or DIGEST is empty" >&2
         exit 1
       fi
       echo "${TAGS}" | while IFS= read -r tag; do
         [ -z "$tag" ] && continue
         echo "Signing: ${tag}@${DIGEST}"
         cosign sign --yes "${tag}@${DIGEST}"
       done
       echo "All tags signed successfully"
   ```

   The `set -euo pipefail` plus explicit empty-string guards are intentional. Without them, a partial signing failure can leave the workflow green while only some tags got signed, silent breakage that doesn't surface until a user runs `cosign verify` and gets an error.

6. **PR-skip discipline.** Every step that requires registry credentials or produces an attestation must be gated with `if: github.event_name != 'pull_request'`:
   - `Login to Docker Hub`
   - `Attest build provenance`
   - `Install cosign`
   - `Sign image with cosign (keyless)`
   - `dockerhub-description` job (gated at job level via `if: github.event_name == 'push' && github.ref == 'refs/heads/main'`)

   PR builds still run the actual `Build and push` step with `push: false` (a dry-run that validates the build), so a Dockerfile regression caught in PR is the same surface as in main.

7. **`scan-trivy` job**: runs after the build, scans the published digest, uploads SARIF. Skipped on PR builds (the digest doesn't exist in the registry). `continue-on-error: true` so a new CVE disclosure doesn't red-CI ongoing work.

   ```yaml
   scan-trivy:
     needs: build
     if: github.event_name != 'pull_request'
     runs-on: ubuntu-latest
     timeout-minutes: 10
     continue-on-error: true
     permissions:
       contents: read
       security-events: write
     steps:
       - uses: actions/checkout@<sha> # v6
       - uses: aquasecurity/trivy-action@<sha> # v0.36.0
         with:
           image-ref: ${{ env.IMAGE_NAME }}@${{ needs.build.outputs.digest }}
           format: sarif
           output: trivy.sarif
           severity: CRITICAL,HIGH
           ignore-unfixed: true
       - uses: github/codeql-action/upload-sarif@<sha> # v4.35.2
         with:
           sarif_file: trivy.sarif
           category: trivy
   ```

8. **`dockerhub-description` job**: sync the GitHub README to the Docker Hub repository description on every main push. Empty-string permissions (`permissions: {}`) since the action authenticates via secrets directly.

   ```yaml
   dockerhub-description:
     needs: build
     if: github.event_name == 'push' && github.ref == 'refs/heads/main'
     runs-on: ubuntu-latest
     timeout-minutes: 5
     permissions: {}
     steps:
       - uses: actions/checkout@<sha> # v6
       - uses: peter-evans/dockerhub-description@<sha> # v5.0.0
         with:
           username: ${{ secrets.DOCKERHUB_USERNAME }}
           password: ${{ secrets.DOCKERHUB_TOKEN }}
           repository: ${{ env.IMAGE_NAME }}
           short-description: "<one-sentence under 100 chars; Docker Hub silently truncates longer>"
           readme-filepath: ./README.md
   ```

   Docker Hub silently truncates the `short-description` past ~100 characters. Test the description shows fully on the Docker Hub page after the first run.

9. **Add `IMAGE_NAME` env at workflow level** so it's referenced uniformly:

   ```yaml
   env:
     IMAGE_NAME: heyvaldemar/<image>
   ```

10. **Verify, commit, push, PR.** See [Verification gates → Phase 2](#phase-2).

### Commit message template

```
ci: publish workflow with cosign signing, SBOM, SLSA provenance, Trivy scan

Replaces the previous publish workflow with the supply-chain-hardened
shape that aws-kubectl-docker established as the heyvaldemar baseline.

Jobs:
- lint — hadolint + shellcheck. Blocking. 5-minute timeout.
- build — multi-arch (linux/amd64, linux/arm64) with BuildKit
  attestations (sbom: true, provenance: mode=max) + cosign keyless
  signing (Sigstore OIDC) + GitHub native build provenance via
  actions/attest-build-provenance. PR builds run with push: false
  (dry-run; signing/attest steps gated to non-PR).
- scan-trivy — Trivy scan of the published digest, SARIF upload to
  GitHub Security tab. continue-on-error: true so new CVE
  disclosures don't red-CI ongoing work; the response you can act on is
  a Dependabot base-image digest bump.
- dockerhub-description — peter-evans/dockerhub-description sync on
  main pushes only.

Cosign pinned to v2.6.1 (cosign-installer v4 defaults to v3.x, whose
OCI 1.1 referrer signature storage doesn't roundtrip reliably through
Docker Hub's OCI referrer credential handoff).

attest-build-provenance push-to-registry is false for the same
reason; attestations remain available at /attestations on GitHub.

All third-party actions pinned to commit SHA with # vX.Y.Z comment.
```

---

## Phase 3: README rewrite

**Goal:** evaluator-first README structured around the image's value proposition, supply chain story, and pinning guidance. Zero affiliate links, zero crypto wallets, zero guru voice.

**Branch:** `docs/readme-image-publishing-rewrite`

### Required sections (in order)

1. **Title + image hero phrase** (one line)
2. **Badge row**: left-to-right: usage → size → CI → security → supply-chain → legal
   ```markdown
   [![Docker Pulls](https://img.shields.io/docker/pulls/heyvaldemar/<image>.svg)](https://hub.docker.com/r/heyvaldemar/<image>)
   [![Docker Image Size](https://img.shields.io/docker/image-size/heyvaldemar/<image>/latest.svg)](https://hub.docker.com/r/heyvaldemar/<image>/tags)
   [![Build Status](https://github.com/heyvaldemar/<repo>/actions/workflows/publish.yml/badge.svg?branch=main)](https://github.com/heyvaldemar/<repo>/actions/workflows/publish.yml)
   [![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/heyvaldemar/<repo>/badge)](https://scorecard.dev/viewer/?uri=github.com/heyvaldemar/<repo>)
   [![Cosign Verified](https://img.shields.io/badge/cosign-verified-brightgreen?logo=sigstore)](https://github.com/heyvaldemar/<repo>/attestations)
   [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
   ```
3. **Auto-generated Contents** TOC
4. **Why this image?**: comparison table against the obvious alternatives (`amazon/aws-cli`, `bitnami/kubectl`, "Alpine + scripts", etc., pick what's relevant). Same shape as the [aws-kubectl-docker README](https://github.com/heyvaldemar/aws-kubectl-docker#why-this-image). End with a one-paragraph value prop.
5. **Getting started**: 2-3 concrete `docker run` invocations the reader can paste verbatim. Include `--user "$(id -u):0"` for any volume-mount example since the image runs non-root.
6. **Pinning guidance**: the section that distinguishes a hardened image from a casual one:
   ```markdown
   For production use, pin to **immutable semver tags**:

   - ✅ **Stable:** `heyvaldemar/<image>:X.Y.Z` — immutable on Docker Hub, never purged
   - ⚠️ **Fragile:** `heyvaldemar/<image>:sha-1dfda81` — short-SHA tags are deleted after 90 days

   If you pin by manifest digest (recommended for maximum supply chain integrity), make sure the digest is also referenced by a semver tag. Otherwise the digest may become unpullable once short-SHA cleanup runs. To resolve a tag to its current digest:

   `docker buildx imagetools inspect heyvaldemar/<image>:X.Y.Z --format '{{.Manifest.Digest}}'`
   ```
7. **Features**: bullets of what's actually inside the image (binaries, OS, build-time guarantees). Plus a `### Typical use cases` subsection with 3-5 concrete scenarios.
8. **Supply chain**: the trust statement. Lists every guarantee the image carries:
   - Base image pinned by `sha256` digest, Dependabot weekly bump
   - Multi-stage build keeps build-only artefacts out of the published image
   - Checksum-verified payload binaries
   - Weekly scheduled rebuild
   - Hadolint + shellcheck linting in CI
   - All third-party GitHub Actions pinned to commit SHA
   - `VCS_REF` and `BUILD_DATE` stamped into OCI labels
   - Every published digest is cosign-signed via Sigstore keyless OIDC
   - **SBOM** (SPDX, generated by BuildKit) and SLSA build provenance (`provenance: mode=max`) attached to every digest
   - **GitHub native build provenance** at `/attestations`
   - **Trivy** scans on every push; CRITICAL/HIGH fixable findings as SARIF in the Security tab

   With a `### Verifying signatures` subsection containing the `cosign verify` command:
   ```bash
   cosign verify heyvaldemar/<image>:latest \
     --certificate-identity-regexp "https://github.com/heyvaldemar/<repo>/.*" \
     --certificate-oidc-issuer "https://token.actions.githubusercontent.com"
   ```
9. **Tag management**: explains the five tag categories users will see on Docker Hub, what's immutable vs mutable, what gets deleted when:
   - **Exact semver** (`:X.Y.Z`): immutable, kept forever
   - **Rolling semver** (`:X.Y`, `:X`): mutable, kept forever
   - **Floating channels** (`:latest`, `:edge`): mutable, kept forever
   - **Custom version pins** (`:<custom-key>-<value>`) if applicable, e.g. `:kube-v1.36.0`
   - **Short-SHA builds** (`:sha-<7char>`): immutable, deleted after 90 days
   - Cosign signatures (`:sha256-<digest>.sig`): managed by Sigstore, not deleted

   Cross-link this section to Pinning guidance so users land on the right tag for production.
10. **Breaking changes in vX.0**: only if the repo had an existing user base before non-root migration. See the [Optional: Non-root migration](#optional-non-root-migration-breaking-change-for-existing-latest-users) section for what goes here.
11. **Mounting credentials / volumes**: the `~/.config` → `/home/app/.config` mapping with `--user "$(id -u):0"` so non-root reads host-owned files.
12. **Build instructions**: `docker build` examples for local single-arch, with build-args, multi-arch via buildx. Build-arg table:
    ```markdown
    | ARG          | Default    | Purpose                                                                  |
    |--------------|------------|--------------------------------------------------------------------------|
    | `VCS_REF`    | `unknown`  | Commit SHA, stamped into `org.opencontainers.image.revision`.            |
    | `BUILD_DATE` | `unknown`  | ISO-8601 timestamp, stamped into `org.opencontainers.image.created`.     |
    | `TARGETARCH` | auto       | Target architecture (`amd64`/`arm64`). Supplied automatically by buildx. |
    ```
13. **Local Build & Test**: references `scripts/smoke-test.sh`. Optional `<details>` block with one-liner verification commands.
14. **Security Notes**: short bulleted list (non-root by default, checksum-verified binaries, minimal apt, pin recommendations).
15. **Run as root (override)**: only if the image runs non-root by default. One-line documentation of `--user 0:0`.
16. **About the maintainer**: compact footer. Do not duplicate the profile bio:

    ```markdown
    ---

    ## About the maintainer

    <div align="center">

    **Maintained by [Vladimir Mikhalev](https://github.com/heyvaldemar)** — Docker Captain · IBM Champion · AWS Community Builder

    [YouTube](https://www.youtube.com/channel/UCf85kQ0u1sYTTTyKVpxrlyQ?sub_confirmation=1) · [Blog](https://heyvaldemar.com) · [LinkedIn](https://www.linkedin.com/in/heyvaldemar/)

    </div>
    ```

### What to strip from a legacy README

Same checklist as Type B Phase 4. The pre-hardening README typically contains:

- "hey everyone" / "cutting my teeth" / "super detailed" / "I'm stoked" / "Let's do this together!"
- "My 2D Portfolio" (sre.gg), "My Courses" (Udemy affiliate), "My Services", "Patreon Exclusives"
- "My Recommendations" kit.co affiliate links
- "Follow Me" social-network wall (10+ links)
- "Community of IT Experts" Discord invite
- "Refill My Coffee Supplies" (PayPal / Patreon / BMC / Ko-fi / GitHub Sponsors)
- BTC / ETH / BNB / LTC wallet addresses
- "Show some 💜 by starring" + octocat GIF
- Footer SVG

All of it → delete. The compact `About the maintainer` footer replaces it.

### Verify

```bash
# No legacy content
grep -iEc "patreon|kit\.co|buymeacoffee|bc1q|0x76C|octocat|footer SVG|cutting my teeth|let's do this together|I'm stoked|My dream|super detailed|seriously, they're foolproof" README.md
# expected: 0

# Has the canonical footer
grep -c "Docker Captain · IBM Champion · AWS Community Builder" README.md
# expected: 1

# Pinning guidance present
grep -c "## Pinning guidance" README.md
# expected: 1

# Tag management present
grep -c "## Tag management" README.md
# expected: 1
```

### Commit message template

Long form. The README is the most user-visible artefact and the rewrite is the most substantive PR after the publish workflow. Use the [aws-kubectl-docker README rewrite commit](https://github.com/heyvaldemar/aws-kubectl-docker/blob/main/CHANGELOG.md#changed) as the shape template.

---

## Phase 4: OpenSSF scorecard

**Goal:** weekly automated Scorecard run, results published to scorecard.dev viewer, SARIF uploaded to GitHub Security tab, badge in README.

**Branch:** `feat/openssf-scorecard-workflow`

### Steps

1. **Run the helper script**: same one used for Type B repos:

   ```bash
   $RUNBOOK/scripts/apply-phase-5.sh $TARGET
   ```

   Drops in `.github/workflows/scorecard.yml` (refuses to overwrite if one exists and prints a diff instead) and echoes the README badge with owner/repo pre-filled from `git remote`.

2. **Add the Scorecard badge to README**: the script prints the exact line. Place it in the badge row after Build Status and before License (security badges before legal).

3. **Adjust the cron schedule** if you have a Phase-5 tag-cleanup workflow on Mondays at 07:00 UTC (see Phase 5). Default Scorecard cron is Tuesday 06:00 UTC, which lands after the Monday 06:00 UTC publish rebuild and the Monday 07:00 UTC cleanup, keeps the Scorecard score in sync with any weekly change in pinned-dependency posture.

4. **Update CHANGELOG**: `[Unreleased] → Added` entry.

5. **Verify, commit, push, PR.** See [Verification gates → Phase 4](#phase-4).

### Commit message template

```
feat(ci): add OpenSSF Scorecard workflow + README badge

OpenSSF Scorecard scores public OSS repos on supply-chain security
posture. Runs weekly on Tuesdays at 06:00 UTC (after the Monday
rebuild and cleanup workflows), publishes to scorecard.dev viewer,
uploads SARIF to GitHub Security tab.

Workflow:
- .github/workflows/scorecard.yml — heyvaldemar baseline shape.
- All four action pins are commit-SHA based with # vX.Y.Z comments.
- ossf/scorecard-action pinned to dereferenced commit SHA (not
  tag-object SHA) — Scorecard's imposter-commit check rejects the
  latter.

README: Scorecard badge between Build Status and License.
```

---

## Phase 5: tag retention + Docker Hub immutability

**Goal:** prevent unbounded `sha-*` tag accumulation on Docker Hub via a weekly cleanup workflow, sweep any pre-Phase-1 legacy long-SHA tags via a one-shot script, and make Docker Hub enforce immutability on the tag categories that should never be re-pushed.

**Branch:** `feat/tag-retention-and-immutability`

### Steps

1. **Add `.github/workflows/dockerhub-tag-cleanup.yml`**: weekly Monday 07:00 UTC (one hour after the Monday 06:00 UTC publish rebuild, so newly-produced `sha-*` tags older than 90 days get swept the same morning):

   ```yaml
   name: Docker Hub Tag Cleanup

   on:
     schedule:
       - cron: "0 7 * * 1"
     workflow_dispatch:
       inputs:
         dry_run:
           description: "Dry run (list only, no deletion)"
           required: false
           default: "true"
           type: choice
           options:
             - "true"
             - "false"

   concurrency:
     group: dockerhub-tag-cleanup
     cancel-in-progress: false

   permissions:
     contents: read

   jobs:
     cleanup:
       runs-on: ubuntu-latest
       timeout-minutes: 10
       steps:
         - name: Get Docker Hub JWT
           # Exchange PAT for short-lived JWT. The REST API for tag deletion
           # requires bearer JWT, not the raw PAT.
           ...
         - name: List and filter sha-* tags
           # Cutoff: 90 days ago. Match name starts with 'sha-' AND
           # last_updated < cutoff. Critical: do NOT match 'sha256-*.sig'
           # (cosign signatures) which start with 'sha256-', not 'sha-'.
           ...
         - name: Delete filtered tags
           # Scheduled runs auto-delete (DRY_RUN=false). Manual workflow_dispatch
           # defaults to dry_run=true (safer for humans testing the workflow).
           ...
   ```

   See [aws-kubectl-docker `dockerhub-tag-cleanup.yml`](https://github.com/heyvaldemar/aws-kubectl-docker/blob/main/.github/workflows/dockerhub-tag-cleanup.yml) for the full workflow including the JWT exchange, pagination, jq filter, and per-tag DELETE with rate-limit sleep.

   **Critical filter detail:** the regex must match `sha-*` (the short-SHA tags from CI) but NOT `sha256-*.sig` (cosign signature manifests). They look similar; getting it wrong wipes out all signatures.

2. **Add `scripts/cleanup-legacy-tags.sh`**: one-shot local cleanup for legacy long-SHA tags from the pre-Phase-1 CI era. Dry-run by default; `--execute` requires typed `DELETE` confirmation. The list of target tags is hardcoded in the script so the operation is auditable in version control.

   ```bash
   #!/usr/bin/env bash
   set -euo pipefail

   REPO="heyvaldemar/<image>"
   API="https://hub.docker.com"
   UA="<image>-cleanup-script/1.0"

   # Hardcoded list of legacy tags to sweep. Kept inline so the script
   # remains self-contained and auditable in version control.
   LEGACY_TAGS=(
     <tag-1>
     <tag-2>
     ...
   )

   MODE="${1:---dry-run}"
   case "$MODE" in
     --dry-run|--execute) ;;
     *) echo "Usage: $0 [--dry-run|--execute]" >&2; exit 2 ;;
   esac

   # PAT from $DOCKERHUB_PAT or interactive prompt (input hidden).
   # JWT exchange. Per-tag DELETE with HTTP-code dispatch (200/204/404 cases).
   # --execute requires typed "DELETE" confirmation.
   ...
   ```

   See [aws-kubectl-docker `scripts/cleanup-legacy-tags.sh`](https://github.com/heyvaldemar/aws-kubectl-docker/blob/main/scripts/cleanup-legacy-tags.sh) for the full script. The `--execute` confirmation is exact-match: typing anything other than `DELETE` aborts.

3. **Set the Docker Hub tag immutability policy.** Docker Hub supports a per-repository regex that marks matching tags as immutable (cannot be re-pushed once created). Apply via the Docker Hub UI: Repository → Settings → Tag immutability rules. The recommended regex covers exact semver, prefixed semver, short-SHA, and any custom version pins:

   ```
   ^(v?\d+\.\d+\.\d+|sha-[0-9a-f]{7,40}|<custom-prefix>-v?\d+\.\d+\.\d+)$
   ```

   For aws-kubectl-docker the actual regex is:

   ```
   ^(v?\d+\.\d+\.\d+|sha-[0-9a-f]{7,40}|kube-v\d+\.\d+\.\d+)$
   ```

   The `kube-v*` group is a domain-specific pin pattern. Adapt for your image (or omit the third clause if you have no custom version pins).

   **Critical:** the regex must NOT match `latest`, `edge`, rolling semver (`X.Y`, `X`), or floating channels. Those need to be mutable so `:latest` can re-target each main push.

4. **Set Docker Hub categories.** Per-repository setting on Docker Hub (Repository → General → Categories) so the image surfaces in browse and search. Pick at most 3 from Docker Hub's category list, e.g., for aws-kubectl-docker: `Operating Systems`, `Languages & Frameworks`, `Integrations & Delivery`.

5. **Enable Docker Scout** (free for public repos) at the repository level on Docker Hub if it isn't already on. Scout's CVE feed is the lowest-friction way for downstream users to see CRITICAL/HIGH findings against the image without running their own Trivy.

6. **Update CHANGELOG**: `[Unreleased] → Added` entries for the cleanup workflow, the legacy-cleanup script, and the immutability policy.

7. **Verify, commit, push, PR.** See [Verification gates → Phase 5](#phase-5).

### Commit message template

```
feat: tag retention workflow + legacy cleanup script + immutability policy

Closes the tag-management track for this image. Three pieces:

1. .github/workflows/dockerhub-tag-cleanup.yml — weekly (Mon 07:00 UTC,
   1h after the Mon 06:00 UTC publish rebuild). Deletes sha-* image
   tags older than 90 days. Filter explicitly excludes sha256-*.sig
   cosign signature manifests. Scheduled runs auto-delete; manual
   workflow_dispatch defaults to dry-run.

2. scripts/cleanup-legacy-tags.sh — one-shot sweeper for the N legacy
   long-SHA (40-char hex) tags from the pre-Phase-1 CI era. Tags
   hardcoded inline so the operation is auditable in version control.
   Dry-run by default; --execute requires typed DELETE confirmation.

3. Docker Hub tag immutability policy applied via the Docker Hub UI
   with regex `^(v?\d+\.\d+\.\d+|sha-[0-9a-f]{7,40}|<...>)$`. Locks
   exact-semver and short-SHA tags from re-push. Floating channels
   (latest, edge, rolling semver X.Y, X) remain mutable as required.

Result: predictable tag lifecycle. No silent re-pushes on immutable
categories. No unbounded sha-* accumulation. Cosign signatures untouched.
```

---

## Optional: non-root migration (BREAKING CHANGE for existing :latest users)

Apply this when you are about to ship the Phase 0 non-root user switch on a repo that has an existing audience pulling `:latest`.

**Goal:** announce, document, and provide a migration path. Don't simply break running workflows.

### Steps

1. **Cut a `v1-maintenance` branch** from the last pre-non-root commit before the Phase 0 PR lands. Push it.

2. **Configure CI to build `:v1-maintenance`** from that branch. The simplest approach: add the branch to the `publish.yml` `on.push.branches` list. The branch gets the same weekly rebuild + cosign signing + Trivy scan as `main`.

3. **Document a sunset date.** Convention: 90 days from the v2.0 release. After that the branch is frozen: no further rebuilds. State this in:
   - `SECURITY.md` "Supported Versions" table: mark `v1-maintenance` with the explicit end-of-support date.
   - `CHANGELOG.md` `[2.0.0]` entry under `BREAKING CHANGES`.
   - README "Breaking Changes in vX.0" section.

   Example SECURITY.md row from [aws-kubectl-docker](https://github.com/heyvaldemar/aws-kubectl-docker/blob/main/SECURITY.md):

   ```markdown
   | `v1-maintenance` tag (pre-v2.0, root default, security-only)   | :white_check_mark: until **2026-07-20** |
   ```

4. **Add a top-of-README "Breaking Changes in vX.0" section** with three subsections:
   - **For most users: no changes needed.** Most one-shot CI commands work identically.
   - **For users mounting volumes.** Document `--user "$(id -u):0"` and the new `/home/app/.<config>` mount paths.
   - **Staying on v1.x.** Document `docker pull heyvaldemar/<image>:v1-maintenance` and the sunset date.

5. **Add the migration block to CHANGELOG `[2.0.0]`:**

   ```markdown
   ### BREAKING CHANGES
   - Container now runs as non-root user (UID 10001, GID 0) by default. Users who
     depend on running as root must override with `--user 0:0`. Volume mounts may
     require adjusted file ownership or `--user "$(id -u):0"` so the container can
     read mounted host files. See the README "Breaking Changes in v2.0" section for
     the full migration guide.
   - Default `WORKDIR` changed from `/` to `/home/app`. Scripts that assumed a
     specific working directory should set it explicitly via `-w` or `WORKDIR`.
   - Default mount paths for credentials/configs documented as `/home/app/.<config>`
     (previously `/root/.<config>`). Old paths still work if you mount there AND
     override with `--user 0:0`, but are no longer the documented contract.
   ```

6. **Cut the v2.0.0 git tag and release.** The publish workflow auto-tags the image as `:2.0.0`, `:2.0`, `:2`, and `:latest`. The `v1-maintenance` branch keeps publishing under its own tag.

7. **Monitor for breakage.** Issue templates and `:v1-maintenance` pulls are the early signal. If a critical workflow breaks for many users, consider extending the `v1-maintenance` sunset.

### Why a 90-day window

90 days is enough time for downstream consumers to encounter the breaking change in their own CI cycles, file an issue, and migrate. It's short enough to not become a permanent maintenance liability. `v1-maintenance` requires its own weekly rebuilds and new CVEs accumulate against the older base. The hard cutoff is documented up front so users budget the migration; nobody is surprised on day 91.

---

## Optional: architecture decision records

Same pattern as the Type B runbook. See [`RUNBOOK.md` → Optional: Architecture Decision Records (flagship repos)](RUNBOOK.md#optional--architecture-decision-records-flagship-repos) for when, why, and how. The ADR template at [`templates/ADR.md.tmpl`](templates/ADR.md.tmpl) is shared between both runbooks.

Topics worth recording for image-publishing repos:

- Why this base distro (Ubuntu / Alpine / Debian / distroless)?
- Why multi-stage with a builder, vs. a single-stage RUN that cleans up after itself?
- Why UID 10001 specifically (not 1000, not 65534)?
- Why GID 0 instead of a dedicated runtime group?
- Why Cosign v2.6.1 instead of v3.x today?
- Why `attest-build-provenance` with `push-to-registry: false`: capture the Docker Hub OCI referrer credential handoff history.
- Why ship `unzip` (or any other "carried for backwards compatibility" binary) in the final image?

Pick 2-3 whose "why" is least obvious to a drive-by reader.

---

## Verification gates

Run these checks after each phase, before merging. Hard gates: if a check fails, fix before merge.

### Phase 0

```bash
# Multi-stage Dockerfile
grep -c "^FROM .* AS " Dockerfile  # expected: >= 2

# Base image pinned by digest (not bare tag)
grep -E "^FROM " Dockerfile | grep -vc "@sha256:"  # expected: 0

# Non-root user declared
grep -E "^USER " Dockerfile  # expected: matches `USER 10001:0` or similar

# OCI labels present (at minimum: title, source, licenses, revision, created)
for label in title source licenses revision created; do
  grep -c "org.opencontainers.image.${label}" Dockerfile
done
# expected: each >= 1

# .dockerignore + .hadolint.yaml exist
test -f .dockerignore && echo "ok" || echo "MISSING"
test -f .hadolint.yaml && echo "ok" || echo "MISSING"

# Hadolint clean
docker run --rm -i hadolint/hadolint:latest < Dockerfile
# expected: exit 0, no output

# Image runs as non-root
docker build -t <image>:local .
docker run --rm <image>:local id
# expected: uid=10001 gid=0(root)
```

### Phase 1

```bash
# LICENSE exists and is ~1KB (canonical MIT)
wc -c LICENSE  # expected: ~1070-1100 bytes

# SECURITY.md + CHANGELOG.md tracked
git ls-files | grep -E '^(SECURITY|CHANGELOG)\.md$'  # expected: both

# scripts/smoke-test.sh present and executable
test -x scripts/smoke-test.sh && echo "ok" || echo "MISSING or not +x"

# FUNDING.yml gone
test -f .github/FUNDING.yml && echo "still present" || echo "removed"

# Dependabot has both ecosystems
python3 -c "
import yaml
d = yaml.safe_load(open('.github/dependabot.yml'))
ecos = {u['package-ecosystem'] for u in d['updates']}
assert 'github-actions' in ecos
assert 'docker' in ecos
print('OK')
"
```

### Phase 2

```bash
# Every uses: line has a commit-SHA pin with # comment
grep -E "uses:" .github/workflows/*.yml | grep -v '@[0-9a-f]\{40\}.*#.*v'
# expected: empty

# BuildKit attestation flags
grep -c "sbom: true" .github/workflows/publish.yml      # expected: 1
grep -c "provenance: mode=max" .github/workflows/publish.yml  # expected: 1

# Cosign pinned to v2 explicitly
grep "cosign-release:" .github/workflows/publish.yml | grep -E "v2\.[0-9]+\.[0-9]+"
# expected: matches

# attest-build-provenance push-to-registry is false
grep -A2 "attest-build-provenance" .github/workflows/publish.yml | grep "push-to-registry: false"
# expected: matches

# PR-skip discipline on every credential / attestation step
grep -B1 -A1 "Login to Docker Hub\|Install cosign\|Sign image with cosign\|Attest build provenance" .github/workflows/publish.yml | grep -c "github.event_name != 'pull_request'"
# expected: >= 4 (one per step)

# flavor: latest=false in metadata-action (so semver tag pushes don't retag :latest)
grep -A2 "uses: docker/metadata-action" .github/workflows/publish.yml | grep "latest=false"
# expected: matches

# Trivy scan job present and gated to non-PR
grep -B2 "uses: aquasecurity/trivy-action" .github/workflows/publish.yml | grep "github.event_name != 'pull_request'"
# expected: matches

# Per-job permissions (no workflow-level packages: write)
python3 <<'EOF'
import yaml
d = yaml.safe_load(open('.github/workflows/publish.yml'))
top = d.get('permissions', {})
assert 'packages' not in top, 'workflow-level permissions should not include packages: write'
print('OK')
EOF
```

### Phase 3

```bash
# No legacy guru voice / affiliate content
grep -iEc "patreon|kit\.co|buymeacoffee|bc1q|0x76C|octocat|footer SVG|cutting my teeth|let's do this together|I'm stoked|My dream|super detailed|seriously, they're foolproof" README.md
# expected: 0

# All required sections present
for section in "Why this image" "Getting started" "Pinning guidance" "Features" "Supply chain" "Verifying signatures" "Tag management" "Build Instructions" "Security Notes" "About the maintainer"; do
  grep -c "^##* ${section}" README.md
done
# expected: each >= 1

# Compact maintainer footer with the 3-title subtitle
grep -c "Docker Captain · IBM Champion · AWS Community Builder" README.md
# expected: 1

# Six badges in the right order: pulls → size → CI → scorecard → cosign → license
grep -c "img.shields.io/docker/pulls\|img.shields.io/docker/image-size\|/actions/workflows/publish.yml/badge.svg\|api.scorecard.dev/projects\|cosign-verified\|License-MIT" README.md
# expected: >= 6

# Cosign verify command present
grep -c "cosign verify heyvaldemar" README.md
# expected: >= 1
```

### Phase 4

```bash
# Scorecard workflow parses
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/scorecard.yml'))"

# Scorecard badge in README between Build Status and License
grep -A1 "actions/workflows/publish.yml/badge.svg" README.md | tail -1 | grep "OpenSSF Scorecard"
# expected: matches

# All four scorecard.yml action pins are commit SHAs
grep "uses:" .github/workflows/scorecard.yml | grep -vc '@[0-9a-f]\{40\}'
# expected: 0
```

### Phase 5

```bash
# dockerhub-tag-cleanup.yml present and parses
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/dockerhub-tag-cleanup.yml'))"

# Filter excludes signature tags
grep -c 'startswith("sha-")' .github/workflows/dockerhub-tag-cleanup.yml
# expected: >= 1
grep -c 'sha256-' .github/workflows/dockerhub-tag-cleanup.yml
# expected: 0 (must NOT match signature tags)

# scripts/cleanup-legacy-tags.sh exists, is executable, and dry-run is the default
test -x scripts/cleanup-legacy-tags.sh
grep -c 'MODE="${1:---dry-run}"' scripts/cleanup-legacy-tags.sh  # expected: 1
grep -c '"DELETE"' scripts/cleanup-legacy-tags.sh  # expected: confirmation present

# Docker Hub immutability policy applied (manual UI step, verify by attempting a no-op re-push of an immutable tag; should be rejected)
# expected: HTTP 400 from Docker Hub if tag immutability matches
```

---

## Common pitfalls

### Pitfall 1: cosign v2 vs v3 storage divergence

`cosign-installer@v4` defaults to Cosign v3.x. Cosign v3 changed container signature storage to OCI 1.1 referring artifacts. Docker Hub's OCI referrer credential handoff is unreliable in practice. A workflow that signs successfully in CI can leave signatures unverifiable for downstream users.

**Pin Cosign to `v2.6.1`** explicitly via `cosign-release: "v2.6.1"`. Cosign v2 keeps tag-based `.sig` storage which works reliably on Docker Hub today. Full Cosign v3 migration is deferred until Docker Hub's OCI referrer handoff stabilizes.

### Pitfall 2: `attest-build-provenance` push-to-registry

Same root cause as Pitfall 1. `actions/attest-build-provenance` can push the attestation to the registry as an OCI referrer sidecar via `push-to-registry: true`, but Docker Hub's OCI referrer credential handoff fails silently in some cases.

**Set `push-to-registry: false`.** The attestation remains discoverable via GitHub Attestations at `https://github.com/heyvaldemar/<repo>/attestations`.

### Pitfall 3: `flavor: latest=false` is mandatory once tag immutability is enabled

By default, `docker/metadata-action` retags `:latest` on every successful build, including semver-tag pushes. Once Phase 5's Docker Hub tag immutability policy is in place, the second push of `:latest` from a semver tag run conflicts with whatever was pushed by the previous main-branch run, and the entire publish job fails.

**Add `flavor: latest=false`** to the metadata action and gate `:latest` explicitly:

```yaml
flavor: |
  latest=false
tags: |
  type=raw,value=latest,enable={{is_default_branch}}
  ...
```

This was the root cause of [aws-kubectl-docker hotfix #32](https://github.com/heyvaldemar/aws-kubectl-docker/pull/32).

### Pitfall 4: annotated tag SHA vs commit SHA

Same as Type B Pitfall 1. `sigstore/cosign-installer`, `actions/attest-build-provenance`, `ossf/scorecard-action`, and `github/codeql-action` all use annotated tags. Pinning their tag-object SHA causes Scorecard's imposter-commit check to reject the workflow.

**Use `scripts/dereference-github-tag.sh`** for every action pin. It handles both annotated and lightweight tags transparently.

### Pitfall 5: cosign signing without `set -euo pipefail`

The naive cosign signing loop:

```yaml
run: |
  echo "${TAGS}" | while IFS= read -r tag; do
    cosign sign --yes "${tag}@${DIGEST}"
  done
```

…silently swallows partial failures. A pipe error or missing variable produces an empty `TAGS`, the `while` loop runs zero iterations, and the workflow exits green with zero tags signed.

**Always use `set -euo pipefail` plus explicit empty-string guards:**

```yaml
run: |
  set -euo pipefail
  if [ -z "${TAGS}" ] || [ -z "${DIGEST}" ]; then
    echo "ERROR: TAGS or DIGEST is empty" >&2
    exit 1
  fi
  echo "${TAGS}" | while IFS= read -r tag; do
    [ -z "$tag" ] && continue
    cosign sign --yes "${tag}@${DIGEST}"
  done
```

### Pitfall 6: tag cleanup regex matching cosign signatures

The cleanup workflow's filter is:

```jq
.[] | select(.name | startswith("sha-")) | select(.last_updated < $cutoff)
```

This intentionally matches `sha-1234567` (short-SHA build tags) but NOT `sha256-abcd1234.sig` (cosign signature manifests). They both start with `sha`, but the prefix `sha-` is exact. `sha256-*` has a different prefix.

**Test the filter on a non-prod repo before deploying.** A bad regex that matches `sha256-*.sig` wipes every signature on the repo in one workflow run. Cosign signatures are reproducible (re-sign by re-running the publish workflow), but the recovery is several hours of CI time.

### Pitfall 7: Docker Hub `short-description` truncation

`peter-evans/dockerhub-description` accepts a `short-description` of any length, but Docker Hub silently truncates it past ~100 characters. The web UI shows the truncation; the API doesn't.

**Keep `short-description` under 100 chars.** Test by visiting the Docker Hub repo page after the first sync and verifying the full description shows.

### Pitfall 8: `unzip` (or any other "carried for backwards compatibility" binary) in the final image

Multi-stage builds tempt you to delete every build-time tool from the final image. Sometimes that breaks unrelated user workflows that relied on the tool being present at runtime, e.g. an `unzip` invocation in a downstream CI script, even though the image's primary purpose has nothing to do with zip files.

**Decide explicitly per binary** whether it stays in the final image and document the decision in a comment in the Dockerfile and (if user-impacting) in the CHANGELOG. Removing a long-bundled binary is a BREAKING CHANGE. Pair it with a deprecation notice on a previous release.

Example from aws-kubectl-docker:

```
# `unzip` is retained in the final image for backwards compatibility with
# users of heyvaldemar/aws-kubectl:latest (500K+ pulls) who rely on it for
# ad-hoc zip extraction in CI/CD pipelines.
```

### Pitfall 9: `sha-*` tag immutability vs scheduled rebuilds

Same root cause as Pitfall 3 (`flavor: latest=false`), different tag. The `sha-*` rule emitted by `docker/metadata-action` re-emits the same `sha-<X>` on every event type, including `schedule` and `workflow_dispatch`. The weekly cron from Phase 2 is meant to rebuild against fresher base layers, which produces a different image manifest digest for the same source SHA. Pushing to `sha-<X>` then fails with HTTP 403 against the Docker Hub immutability policy from Phase 5:

```
ERROR: failed to push <image>:sha-0546ce8: denied: requested access to the resource is denied
- tag sha-0546ce8 is already assigned to an image in this repository and cannot be updated
due to immutability settings.
```

The build-and-push step exits 1, which short-circuits the rest of the job: `attest-build-provenance`, cosign install, cosign sign, and Trivy scan all skip. CI goes red on cron without any human change to the repo.

The collision surfaces the first time a cron run lands on a stale source SHA after the immutability policy was applied. Earlier cron runs that landed within hours of a fresh main push didn't trigger it because the source SHA was new each time.

**Fix:** gate the `sha-*` tag rule to events that produce a new source SHA:

```yaml
type=sha,prefix=sha-,format=short,enable=${{ github.event_name == 'push' || github.event_name == 'pull_request' }}
```

Behavior after the fix:

| Event | sha-* emitted? | Pushed to registry? | Rationale |
|---|---|---|---|
| Push to main / push tag | ✅ | ✅ | New source SHA → fresh tag, no collision |
| Pull request | ✅ | ❌ (`push: false`) | Tag list completeness only |
| Schedule (weekly cron) | ❌ | - | Only re-tag mutable `:latest` and `:edge` with rebuilt image |
| `workflow_dispatch` | ❌ | - | Manual rebuild without source change; if source did change, push instead |

The "first push of a source SHA owns the immutable `sha-*` tag forever" semantic is preserved, which is the property downstream consumers depend on when pinning by `sha-*`.

**Why not just disable tag immutability?** Immutability is the whole point of the `sha-*` pin: a downstream consumer that pinned `:sha-XYZ` should get byte-identical content forever. Allowing re-push of `sha-XYZ` with different content silently invalidates that contract.

**Why not delete and re-push?** Same problem at one remove: the `sha-*` pin loses its "pin to first build" semantic.

**Same family of bug as Pitfall 3 and `kube-v*`.** `docker/metadata-action`'s default emission rules don't account for tag immutability. Each rule that emits an immutable-category tag needs an explicit `enable=` predicate matching the events where re-push is safe. When you add the immutability policy in Phase 5, audit every tag rule in `metadata-action` and add the predicate.

Reference: aws-kubectl-docker [PR #37](https://github.com/heyvaldemar/aws-kubectl-docker/pull/37) (the worked example, surfaced by the 2026-05-04 cron run).

---

## Rollout strategy

Per repo, expect:

| Phase | Hours | Automation potential |
|---|---|---|
| 0: Dockerfile hardening | 1.5-3 | Low (per-image binary inventory differs) |
| 1: Community files + smoke test | 0.5-1 | **High** (`scripts/apply-phase-1.sh`) |
| 2: CI publish workflow | 2-4 | Medium (workflow shape is identical, but per-image build-args and binary list need adapting) |
| 3: README rewrite | 2-3 | Medium (skeleton template + per-image fills) |
| 4: OpenSSF Scorecard | 0.1-0.25 | **High** (`scripts/apply-phase-5.sh`) |
| 5: Tag retention + immutability | 1-2 | Medium (workflow is drop-in, immutability regex needs per-image adaptation, Docker Hub UI step is manual) |
| Optional: Non-root migration | 1-2 (only if needed) | Low (per-repo audience analysis) |
| **Total** | **~7-13 h** for a fresh repo | - |

First-time application against `aws-kubectl-docker` took ~25–30 hours of design work across multiple PRs in 2026-04 (the v2.0 release cycle). With this runbook + the included templates and helper scripts, subsequent image-publishing repos should take ~7–10 hours of focused work.

### Phasing guidance: which subset to apply

| Tier | Pulls / week | Active? | Phases to apply |
|---|---|---|---|
| Flagship | 10K+ | Yes | 0–5 (full program) + optional non-root migration if applicable |
| Active | 1K–10K | Yes | 0–5 (skip Phase 5 cleanup workflow if tag accumulation isn't yet a problem) |
| Long tail | <1K | Infrequent | 0–4 (skip Scorecard + retention; revisit if pulls grow) |
| Dormant | Any | No push in >2 years | Archive instead of harden |

Pull counts are easily checked via `docker pull` count on Docker Hub. The thresholds are heuristics. Adjust based on whether the image has external production users or is a personal tool.
