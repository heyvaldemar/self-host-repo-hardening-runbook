# Changelog

All notable changes to this runbook are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

_(no unreleased changes yet)_

## [1.3.2] - 2026-05-06

### Added

- **`audits/` directory** with point-in-time compliance snapshots of reference implementations against the runbook standard. First entry: `audits/keycloak-2026-04-28.md` — full audit of `keycloak-traefik-letsencrypt-docker-compose` against the augmented 8-phase Compose-stack runbook. Catalogues universal-standard compliance, Phase 0–7 status per phase, HIGH/MEDIUM/LOW findings with remediation effort estimates, and recommended remediation order. Surfaced two patterns the keycloak repo evolved past the runbook (backup-restore-e2e CI job, RTO/RPO documentation table) which are candidates for future runbook additions.
- README repository-contents tree updated with the `audits/` entry plus a paragraph explaining the audits' role (point-in-time gap pins between reference impl and runbook).

## [1.3.1] - 2026-05-05

### Added

- **`IMAGE-PUBLISHING-RUNBOOK.md` Common Pitfall 9 — `sha-*` tag immutability vs scheduled rebuilds.** Same family of bug as Pitfall 3 (`flavor: latest=false`) and the `kube-v*` tag fix from aws-kubectl-docker PR #32: `docker/metadata-action`'s default tag emission rules don't account for tag immutability. The weekly schedule cron and `workflow_dispatch` reuse the source SHA but produce a fresh image manifest digest (newer base layers), and pushing to the existing immutable `sha-<X>` tag is rejected with HTTP 403. Documents the failure mode, the one-line fix (`enable=` predicate gating the rule to push and pull_request events), the per-event behavior matrix, and the broader rule: when adding an immutability policy in Phase 5, audit every tag rule in `metadata-action` and add the appropriate `enable=` predicate. Surfaced by aws-kubectl-docker [PR #37](https://github.com/heyvaldemar/aws-kubectl-docker/pull/37) after the 2026-05-04 weekly cron failure.

## [1.3.0] - 2026-04-28

### Added

- **`IMAGE-PUBLISHING-RUNBOOK.md`** — companion runbook codifying the image-publishing patterns from [aws-kubectl-docker](https://github.com/heyvaldemar/aws-kubectl-docker). 6 mandatory phases (Dockerfile hardening, community files + smoke test, CI publish workflow with cosign + SBOM + SLSA + Trivy, README rewrite, OpenSSF Scorecard, tag retention + Docker Hub immutability) plus an optional non-root migration phase for repos with existing `:latest` users. Verbatim cosign-signing block with rationale for pinning Cosign v2.6.1 (not v3.x). Verbatim `attest-build-provenance` block with `push-to-registry: false` rationale. 8 common pitfalls including the `flavor: latest=false` interaction with Docker Hub tag immutability.
- **`RUNBOOK.md` Phase 7 — Container security context + resource limits.** `security_opt: no-new-privileges:true`, `cap_drop: [ALL]`, `read_only: true` with explicit tmpfs mounts, memory + CPU ceilings via `deploy.resources.limits`, healthcheck-coverage verification. Surfaced by the cross-repo audit against keycloak-traefik in 2026-04-28; previously not codified anywhere.
- **`README.md` "Which runbook do I need?" decision table** disambiguating Compose-stack vs image-publishing applicability.
- **Common Pitfall 8 — `read_only: true` + unexpected writable paths.** Documents the most common Phase 7 failure mode: enabling `read_only` on a service whose upstream image writes to a path you didn't anticipate. Lists common writable paths to anticipate (`/tmp`, `/run`, `/var/run`, service-specific cache dirs).

### Changed

- `RUNBOOK.md` top line "Seven phases" → "Eight phases."
- Rollout-strategy estimates include Phase 7 (~1.5 h on first repo, ~1 h on subsequent). Total per Compose-stack repo ~5–8 h (was ~3.5–7).
- Phasing tier table updated: flagship 0–7, active 0–6 (skip Phase 7 unless service-compromise risk justifies the per-service tuning effort), long-tail 0–2.
- `README.md` reframed from single-runbook to two-runbook hub. Two separate time-estimate tables. Reference-implementations table now pairs each repo with its corresponding runbook.

### Known gaps

- No `Dockerfile.tmpl` or `publish.yml.tmpl` yet — image-publishing users copy directly from `aws-kubectl-docker`. Templates are a future addition; the README's repository-contents tree calls this out.
- The keycloak-traefik reference implementation does not yet implement Phase 7 in `main`; the [audit report from 2026-04-28](https://github.com/heyvaldemar/keycloak-traefik-letsencrypt-docker-compose) flags this as the largest remaining gap. Phase 7 application against keycloak-traefik is tracked as a separate PR series.

## [1.2.0] - 2026-04-23

### Added

- **`scripts/apply-phase-1.sh`** — helper script that drops Phase 1 community files into a target repo with auto-derived substitutions:
  - `LICENSE` — `{{YEAR_RANGE}}` substituted from `<first-commit-year>-<current-year>` (read via `git log --reverse`).
  - `SECURITY.md` — drop-in copy, skipped if the target already has one. Content-dependent placeholders (`{{SUPPORTED_VERSIONS_NOTE}}`, `{{UPSTREAM_IMAGES}}`, `{{HISTORICAL_ISSUE_OR_OMIT}}`) left for manual fill with clear markers.
  - `CHANGELOG.md` — `{{REPO}}`, `{{SERVICE}}` (derived from repo name first-token, capitalised), and `{{FIRST_COMMIT_YEAR}}` auto-substituted. Skipped if the target already has a CHANGELOG to avoid overwriting history.
  - `.github/dependabot.yml` — drop-in copy (overwrites existing since the new shape adds grouping + docker ecosystem).
  - `.github/FUNDING.yml` — `git rm` if present.
  - Does not commit or push. Leaves the working tree dirty for human review. Prints a check-list of remaining manual fills.
- **`scripts/apply-phase-5.sh`** — helper script that drops `.github/workflows/scorecard.yml` into a target repo. Refuses to overwrite an existing file (prints a diff instead). Echoes the README badge line with owner/repo pre-filled from the target's `git remote`.
- **`templates/ADR.md.tmpl`** — Michael Nygard-style Architecture Decision Record template (Context / Decision / Alternatives / Consequences / References sections + header metadata). Drop-in starter for `docs/adr/000N-<slug>.md` files on flagship repos.
- **Optional "Architecture Decision Records (flagship repos)" section in `RUNBOOK.md`** — when/why to apply, step-by-step (mkdir + cp + fill), six typical decision topics worth recording, commit-message template. Explicitly scoped to flagship repos (20+ stars, active); not recommended for long-tail.

### Changed

- **RUNBOOK Phase 1 steps** — rewritten as "run the helper script" first, then a grep-for-`{{` step to find remaining manual fills, with the manual `cp` / `sed` fallback preserved for users who prefer it or don't have the script available.
- **RUNBOOK Phase 5 steps** — rewritten as "run the helper script" first, with the manual `cp` fallback preserved.
- **RUNBOOK Contents TOC** — new "Optional — Architecture Decision Records (flagship repos)" entry between Phase 6 and Verification gates.

## [1.1.0] - 2026-04-23

### Added

- **Phase 6 — CI linting + upstream image scanning** added to `RUNBOOK.md`. Codifies the final CI-hardening step observed during the keycloak reference-implementation cycle (PR #19):
  - `lint` job — shellcheck (via `koalaman/shellcheck-alpine:stable`) on every `*.sh` in the repo root, actionlint (via `rhysd/actionlint:1.7.12`) on every workflow YAML. Blocking (5-min timeout). `deploy-and-test` gains `needs: lint` so CI fails fast before burning the 15-minute compose-up slot.
  - `scan-trivy` job — matrix × N upstream images with `aquasecurity/trivy-action@v0.35.0` (commit-SHA pinned), `severity: CRITICAL,HIGH`, `ignore-unfixed: true`. Per-image SARIF upload to the GitHub Security tab under distinct `trivy-<name>` categories via `github/codeql-action/upload-sarif@v4.35.2` (commit-SHA pinned, matches `scorecard.yml`). `continue-on-error: true` — findings surface for triage but don't gate deployment; the actionable response is a Dependabot digest bump in a separate PR.
  - Phase 6 includes a `fail-fast: false` matrix, `security-events: write` scoped to the scan job, full verification gates, and design-decision rationale (why `continue-on-error` on scan, why matrix instead of a single script, why direct docker invocation for shellcheck/actionlint).
- **Common Pitfall 6 — shellcheck SC2016 on intentional `bash -c` deferred expansion.** Documents the pattern used for HTTP smoke checks and the correct placement of `# shellcheck disable=SC2016` directives.
- **Common Pitfall 7 — Dependabot `docker` ecosystem doesn't auto-bump `.env.example` digests.** Dependabot scans `Dockerfile` and `docker-compose.yml` for literal `image: <ref>` strings and doesn't expand `${VAR}` references. Documents three workarounds (inline tags in compose, migrate to Renovate, accept manual rotation) and the current keycloak reference-implementation choice.
- **Rollout-strategy phasing guidance table** — maps `Tier × stars × activity` to the subset of phases to apply. Flagship repos get 0–6, long-tail gets 0–2 only, dormant gets archived.

### Changed

- `templates/deployment-verification.yml.tmpl` — ships with the `lint` and `scan-trivy` job skeletons pre-wired. `deploy-and-test` now declares `needs: lint`. Two existing `timeout 5m bash -c '...'` smoke-check blocks include `# shellcheck disable=SC2016` directives with rationale comments inline (necessary to pass actionlint on fresh applications of the template).
- `RUNBOOK.md` — top line updated from "Six phases" to "Seven phases". Contents TOC expanded with a Phase 6 entry. Rollout-strategy estimates include Phase 6 (~1 hour on first repo).
- Keycloak reference implementation at [heyvaldemar/keycloak-traefik-letsencrypt-docker-compose](https://github.com/heyvaldemar/keycloak-traefik-letsencrypt-docker-compose) now implements Phase 6 as of [PR #19](https://github.com/heyvaldemar/keycloak-traefik-letsencrypt-docker-compose/pull/19). The runbook's Phase 6 prose references this PR as the working example.

## [1.0.0] - 2026-04-23

### Added

- Initial release. Codifies the 6-phase hardening program applied to [heyvaldemar/keycloak-traefik-letsencrypt-docker-compose](https://github.com/heyvaldemar/keycloak-traefik-letsencrypt-docker-compose) across PRs #12–#17, itself modelled on the supply-chain track established in [heyvaldemar/aws-kubectl-docker](https://github.com/heyvaldemar/aws-kubectl-docker).
- `RUNBOOK.md` — the step-by-step playbook. Six phases, one PR each:
  - Phase 0 — Security audit + `.env` hygiene.
  - Phase 1 — Community files + scaffolding (LICENSE, SECURITY.md, CHANGELOG.md, Dependabot groups + docker ecosystem, FUNDING.yml removal).
  - Phase 2 — CI workflow hardening (pinned SHAs, per-job permissions, timeouts, concurrency, weekly cron, filename rename).
  - Phase 3 — Upstream image digest pinning with Dependabot auto-bumps.
  - Phase 4 — README full rewrite to evaluator-first structure.
  - Phase 5 — OpenSSF Scorecard workflow + badge.
- `templates/` directory:
  - `LICENSE.mit.tmpl` — canonical MIT license with `{{YEAR_RANGE}}` placeholder.
  - `SECURITY.md.tmpl` — disclosure policy + supply-chain trust section with `{{REPO}}` / `{{UPSTREAM_IMAGES}}` placeholders.
  - `CHANGELOG.md.tmpl` — Keep-a-Changelog starter.
  - `dependabot.yml` — drop-in. Two ecosystems (github-actions + docker), both grouped.
  - `scorecard.yml` — drop-in. All action pins are commit SHAs with version comments.
  - `deployment-verification.yml.tmpl` — CI workflow skeleton with repo-specific `{{NETWORKS}}` / `{{HOSTNAMES}}` / `{{COMPOSE_FILE}}` placeholders.
  - `README.md.tmpl` — evaluator-first README skeleton with `{{TITLE}}` / `{{SERVICE}}` / `{{COMPARISON_TABLE}}` / `{{FEATURES_LIST}}` / etc. placeholders.
- `scripts/` directory:
  - `resolve-image-digest.sh` — resolve any image reference (Docker Hub `library/*`, Quay.io, GHCR) to its `sha256:...` digest via the registry v2 API.
  - `dereference-github-tag.sh` — resolve a `<owner>/<repo>@<tag>` to a commit SHA, handling the annotated-tag dereferencing case (required for `ossf/scorecard-action`, `github/codeql-action`, `actions/attest-build-provenance`, `sigstore/cosign-installer`).
- `LICENSE` — MIT for this runbook itself.
- `SECURITY.md` — disclosure policy for this runbook.
- `.github/dependabot.yml` — dogfood. Tracks updates to the templates' own action pins as new SHAs ship upstream.
- `.github/workflows/scorecard.yml` — dogfood. The runbook scores itself against the standard it publishes.

[Unreleased]: https://github.com/heyvaldemar/self-host-repo-hardening-runbook/compare/v1.3.2...HEAD
[1.3.2]: https://github.com/heyvaldemar/self-host-repo-hardening-runbook/compare/v1.3.1...v1.3.2
[1.3.1]: https://github.com/heyvaldemar/self-host-repo-hardening-runbook/compare/v1.3.0...v1.3.1
[1.3.0]: https://github.com/heyvaldemar/self-host-repo-hardening-runbook/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/heyvaldemar/self-host-repo-hardening-runbook/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/heyvaldemar/self-host-repo-hardening-runbook/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/heyvaldemar/self-host-repo-hardening-runbook/releases/tag/v1.0.0
