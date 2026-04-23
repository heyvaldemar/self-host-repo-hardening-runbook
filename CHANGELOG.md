# Changelog

All notable changes to this runbook are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

_(no unreleased changes yet)_

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

[Unreleased]: https://github.com/heyvaldemar/self-host-repo-hardening-runbook/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/heyvaldemar/self-host-repo-hardening-runbook/releases/tag/v1.0.0
