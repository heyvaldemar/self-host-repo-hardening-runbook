# Self-Host Repo Hardening Runbook

Documented engineering standards and repeatable phase-by-phase programs for bringing public heyvaldemar repositories up to a **supply-chain-hardened baseline** matching [heyvaldemar/keycloak-traefik-letsencrypt-docker-compose](https://github.com/heyvaldemar/keycloak-traefik-letsencrypt-docker-compose) and [heyvaldemar/aws-kubectl-docker](https://github.com/heyvaldemar/aws-kubectl-docker).

[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/heyvaldemar/self-host-repo-hardening-runbook/badge)](https://scorecard.dev/viewer/?uri=github.com/heyvaldemar/self-host-repo-hardening-runbook)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

## Which runbook do I need?

Two runbooks live in this repository, one per repo type. Pick the one that matches your target:

| If your repo's deliverable is… | Use | Reference implementation |
|---|---|---|
| A Docker Compose stack (e.g. `<service>-traefik-letsencrypt-docker-compose`) | **[`RUNBOOK.md`](RUNBOOK.md)** | [keycloak-traefik-letsencrypt-docker-compose](https://github.com/heyvaldemar/keycloak-traefik-letsencrypt-docker-compose) |
| A Docker image you build and publish to a registry | **[`IMAGE-PUBLISHING-RUNBOOK.md`](IMAGE-PUBLISHING-RUNBOOK.md)** | [aws-kubectl-docker](https://github.com/heyvaldemar/aws-kubectl-docker) |

Some scaffolding is shared between both — the LICENSE / SECURITY.md / CHANGELOG.md templates, the Dependabot config, the Scorecard workflow, the helper scripts in `scripts/`. Both runbooks reuse `scripts/apply-phase-1.sh` for community files and `scripts/apply-phase-5.sh` for Scorecard.

The runbooks diverge where the repo type's surface diverges. Compose-stack repos have services to harden, upstream images to pin, ephemeral CI deployments to verify. Image-publishing repos have multi-stage Dockerfiles to harden, signing + SBOM + SLSA provenance to attach, tag retention policies to enforce.

If you maintain a repo that doesn't match either type (a Helm chart, a library, a CLI tool), neither runbook applies cleanly. Cherry-pick the universal pieces (LICENSE, SECURITY.md, Dependabot, Scorecard) and accept that the type-specific phases don't translate.

## What the Compose-stack runbook delivers

After executing the eight Compose-stack PRs in order, the target repo has:

- **Credentials out of git** — tracked `.env` replaced with `.env.example` + gitignored real file + compose fails fast without required vars.
- **Community health files** — `LICENSE`, `SECURITY.md`, `CHANGELOG.md`, Dependabot groups for `github-actions` + `docker` ecosystems, `.github/FUNDING.yml` removed.
- **CI workflow hardened** — all GitHub Actions pinned to commit SHA with version comment, per-job permissions, `timeout-minutes`, `concurrency` group, weekly cron for upstream drift detection.
- **Upstream images pinned by digest** — `image:tag@sha256:...` in `.env.example` + CI ephemeral env, Dependabot auto-bumps.
- **README rewritten** — evaluator-first structure (badges → TOC → Why this → Getting started → Features → Supply chain trust → Production checklist → preserved ops content → Security Notes → compact About-maintainer footer). Zero affiliate links, zero crypto wallets, zero guru voice.
- **OpenSSF Scorecard workflow** — runs weekly, publishes to scorecard.dev viewer, uploads SARIF to GitHub Security tab.
- **CI linting + upstream Trivy scan** — `lint` job (shellcheck + actionlint, blocking) and `scan-trivy` matrix job (per upstream image, SARIF to Security tab under distinct categories, `continue-on-error` so findings don't block deployment).
- **Container security context + resource limits** — `security_opt: no-new-privileges:true`, `cap_drop: ALL`, `read_only: true` with explicit tmpfs mounts, memory + CPU ceilings on every long-running service.

## What the Image-publishing runbook delivers

After executing the six image-publishing PRs in order, the target repo has:

- **Hardened Dockerfile** — multi-stage build, base image pinned by `sha256` digest (Dependabot weekly bump), checksum-verified payload binaries, full OCI labels (`org.opencontainers.image.*`) stamped from `VCS_REF` / `BUILD_DATE` build args, non-root runtime user (UID 10001, GID 0), `.dockerignore` + `.hadolint.yaml`.
- **Community health files** — same shape as the Compose-stack runbook plus `scripts/smoke-test.sh` exercising every advertised binary.
- **Supply-chain CI workflow** — multi-arch buildx (`linux/amd64`, `linux/arm64`) with BuildKit `sbom: true` + `provenance: mode=max`, GitHub native attestation via `actions/attest-build-provenance`, cosign keyless signing pinned to v2.6.1 (with explicit rationale for not migrating to v3.x), Trivy SARIF scan, `peter-evans/dockerhub-description` README sync, PR-skip discipline on every credential-bearing step.
- **README rewritten** — image-publishing flavor with Pinning guidance, Tag management (5 categories with retention rules), Verifying signatures (`cosign verify` one-liner), Build Instructions table, About-maintainer footer.
- **OpenSSF Scorecard workflow** — same as Compose-stack.
- **Tag retention + immutability** — weekly Docker Hub `sha-*` cleanup workflow (90-day retention, signature manifests excluded), one-shot legacy-tag sweeper script, Docker Hub tag immutability regex applied via the registry UI.

## When to apply each

**Compose-stack runbook** — particularly suited to:

- `<service>-traefik-letsencrypt-docker-compose` repos that deploy one service behind Traefik + Let's Encrypt.
- Docker Compose based homelab / small-team self-host templates.
- Any repo where the deliverable is infrastructure-as-code (compose, not a custom image build).

**Image-publishing runbook** — particularly suited to:

- Single-image base/utility repos that publish to Docker Hub or GHCR (CI/CD tool images, language runtime images, opinionated platform images).
- Repos shipping a multi-arch image consumers pull at a versioned tag.
- Any repo where the deliverable is the image itself plus its supply-chain attestations.

**Not the right runbook for either:**

- Kubernetes Helm charts (different surface — values schema, chart test, etc.).
- Library / CLI repos (entirely different concerns).
- Multi-image monorepos that publish many images from one repo (this runbook assumes one Dockerfile per repo).

## Expected time per repo

### Compose-stack runbook (`RUNBOOK.md`)

| Phase | Hours | Automation potential |
|---|---|---|
| 0 — Security audit + `.env` hygiene | 0.5–1 | Low (per-repo secrets differ) |
| 1 — Community files + scaffolding | 0.25–0.5 | **High** (`scripts/apply-phase-1.sh`) |
| 2 — CI workflow hardening | 0.5–1 | **High** (`scripts/dereference-github-tag.sh` + identical pins) |
| 3 — Upstream image digest pinning | 0.5–1 | **High** (`scripts/resolve-image-digest.sh`) |
| 4 — README rewrite | 1.5–2 | Medium (skeleton template + per-service fills) |
| 5 — OpenSSF Scorecard | 0.1–0.25 | **High** (`scripts/apply-phase-5.sh`) |
| 6 — CI linting + upstream image scanning | 0.5–1 | **High** (drop-in job skeletons + per-repo matrix fill) |
| 7 — Container security context + resource limits | 1–1.5 | Low (per-service tuning required) |
| **Total** | **~5–8 h** | — |

First-time application against `keycloak-traefik-letsencrypt-docker-compose` took ~10–12 hours across the original 7 PRs (pre-Phase-7). With this runbook + the templates and helper scripts, subsequent repos should take ~5–7 hours of focused work. Flagship repos that opt into the [optional ADR phase](RUNBOOK.md#optional--architecture-decision-records-flagship-repos) add ~1 hour for 2–3 decision records.

### Image-publishing runbook (`IMAGE-PUBLISHING-RUNBOOK.md`)

| Phase | Hours | Automation potential |
|---|---|---|
| 0 — Dockerfile hardening | 1.5–3 | Low (per-image binary inventory differs) |
| 1 — Community files + smoke test | 0.5–1 | **High** (`scripts/apply-phase-1.sh`) |
| 2 — CI publish workflow | 2–4 | Medium (workflow shape is identical, but per-image build-args and binary list need adapting) |
| 3 — README rewrite | 2–3 | Medium (skeleton + per-image fills) |
| 4 — OpenSSF Scorecard | 0.1–0.25 | **High** (`scripts/apply-phase-5.sh`) |
| 5 — Tag retention + immutability | 1–2 | Medium (workflow drop-in, regex per-image, Docker Hub UI step manual) |
| Optional — Non-root migration | 1–2 (only if needed) | Low (per-repo audience analysis) |
| **Total** | **~7–13 h** for a fresh repo | — |

First-time application against `aws-kubectl-docker` took ~25–30 hours of design work in 2026-04 (the v2.0 release cycle). With this runbook + helpers, subsequent image-publishing repos should take ~7–10 hours.

## Quick start

```bash
# 1. Clone the target repo and this runbook side by side
cd ~/repos
git clone https://github.com/<you>/<target-repo>
git clone https://github.com/heyvaldemar/self-host-repo-hardening-runbook

# 2. Pick the right runbook for your repo type
cd self-host-repo-hardening-runbook
$EDITOR RUNBOOK.md                    # Compose-stack repos
# OR
$EDITOR IMAGE-PUBLISHING-RUNBOOK.md   # Image-publishing repos

# 3. Work through the phases, one PR each, merge between phases
```

## Reference implementations

The patterns in these runbooks were developed against two live repositories. Each runbook codifies the patterns from one of them. Use them as working examples when the runbook prose is ambiguous:

| Repo | Runbook | Supply chain surface |
|---|---|---|
| [aws-kubectl-docker](https://github.com/heyvaldemar/aws-kubectl-docker) | [`IMAGE-PUBLISHING-RUNBOOK.md`](IMAGE-PUBLISHING-RUNBOOK.md) | Cosign signing + SBOM + SLSA provenance + Trivy SARIF + digest-pinned base + tag immutability + OpenSSF Scorecard |
| [keycloak-traefik-letsencrypt-docker-compose](https://github.com/heyvaldemar/keycloak-traefik-letsencrypt-docker-compose) | [`RUNBOOK.md`](RUNBOOK.md) | Digest-pinned upstream images + Dependabot auto-bumps + CI weekly deployment smoke + Trivy matrix scan + OpenSSF Scorecard |

When this prose is unclear, the reference implementation is the authoritative answer.

## Repository contents

```
self-host-repo-hardening-runbook/
├── README.md                          ← you are here
├── RUNBOOK.md                         ← Compose-stack runbook (8 phases)
├── IMAGE-PUBLISHING-RUNBOOK.md        ← Image-publishing runbook (6 phases)
├── LICENSE                            ← MIT
├── SECURITY.md                        ← disclosure policy for this repo
├── CHANGELOG.md                       ← version history
├── templates/                         ← shared drop-in or find/replace-ready files
│   ├── LICENSE.mit.tmpl               ← used by both runbooks
│   ├── SECURITY.md.tmpl               ← used by both runbooks
│   ├── CHANGELOG.md.tmpl              ← used by both runbooks
│   ├── ADR.md.tmpl                    ← Architecture Decision Record starter
│   ├── dependabot.yml                 ← used by both runbooks (github-actions + docker)
│   ├── scorecard.yml                  ← used by both runbooks
│   ├── deployment-verification.yml.tmpl  ← Compose-stack only
│   └── README.md.tmpl                 ← Compose-stack only
├── scripts/                           ← shared helpers
│   ├── resolve-image-digest.sh        ← used by both runbooks
│   ├── dereference-github-tag.sh      ← used by both runbooks
│   ├── apply-phase-1.sh               ← used by both runbooks (community files)
│   └── apply-phase-5.sh               ← used by both runbooks (Scorecard)
└── .github/
    ├── dependabot.yml                 ← dogfood
    └── workflows/
        └── scorecard.yml              ← dogfood
```

The image-publishing runbook does not yet ship a `Dockerfile.tmpl` or `publish.yml.tmpl` — those are a future addition. Until then, copy directly from [aws-kubectl-docker](https://github.com/heyvaldemar/aws-kubectl-docker) and adapt.

## Contributing

These runbooks codify one maintainer's standard. PRs are welcome, but only for:

- Correctness fixes (e.g., a template field that's wrong)
- Security-posture improvements (e.g., a new check that raises the bar)
- Template-automation helpers (e.g., a script that resolves digests faster)

PRs expanding scope beyond "hardening public self-host repos to match the two reference implementations" will likely be declined as drift.

See [`SECURITY.md`](SECURITY.md) for the vulnerability disclosure process.

---

<div align="center">

**Maintained by [Vladimir Mikhalev](https://github.com/heyvaldemar)** — Docker Captain · IBM Champion · AWS Community Builder

[YouTube](https://www.youtube.com/channel/UCf85kQ0u1sYTTTyKVpxrlyQ?sub_confirmation=1) · [Blog](https://heyvaldemar.com) · [LinkedIn](https://www.linkedin.com/in/heyvaldemar/)

</div>
