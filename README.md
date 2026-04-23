# Self-Host Repo Hardening Runbook

A documented engineering standard and repeatable 7-phase program for bringing a self-host deployment-template repository — typically one in the `<service>-traefik-letsencrypt-docker-compose` shape — up to a **supply-chain-hardened baseline** matching [heyvaldemar/keycloak-traefik-letsencrypt-docker-compose](https://github.com/heyvaldemar/keycloak-traefik-letsencrypt-docker-compose) and [heyvaldemar/aws-kubectl-docker](https://github.com/heyvaldemar/aws-kubectl-docker).

[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/heyvaldemar/self-host-repo-hardening-runbook/badge)](https://scorecard.dev/viewer/?uri=github.com/heyvaldemar/self-host-repo-hardening-runbook)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

## What this is

A runbook you follow once per repo. After executing the seven PRs in order, the target repo has:

- **Credentials out of git** — tracked `.env` replaced with `.env.example` + gitignored real file + compose fails fast without required vars.
- **Community health files** — `LICENSE`, `SECURITY.md`, `CHANGELOG.md`, Dependabot groups for `github-actions` + `docker` ecosystems, `.github/FUNDING.yml` removed.
- **CI workflow hardened** — all GitHub Actions pinned to commit SHA with version comment, per-job permissions, `timeout-minutes`, `concurrency` group, weekly cron for upstream drift detection.
- **Upstream images pinned by digest** — `image:tag@sha256:...` in `.env.example` + CI ephemeral env, Dependabot auto-bumps.
- **README rewritten** — evaluator-first structure (badges → TOC → Why this → Getting started → Features → Supply chain trust → Production checklist → preserved ops content → Security Notes → compact About-maintainer footer). Zero affiliate links, zero crypto wallets, zero guru voice.
- **OpenSSF Scorecard workflow** — runs weekly, publishes to scorecard.dev viewer, uploads SARIF to GitHub Security tab.
- **CI linting + upstream Trivy scan** — `lint` job (shellcheck + actionlint, blocking) and `scan-trivy` matrix job (per upstream image, SARIF to Security tab under distinct categories, `continue-on-error` so findings don't block deployment).

## When to apply

Use this runbook when you want to bring a **public deployment-template repo** up to a consistent, repeatable engineering baseline. Particularly suited to:

- `<service>-traefik-letsencrypt-docker-compose` repos that deploy one service behind Traefik + Let's Encrypt.
- Docker Compose based homelab / small-team self-host templates.
- Any repo where the deliverable is infrastructure-as-code (compose, not a custom image build).

**Not the right runbook for:**

- Repos that publish their own Docker image (those need cosign signing + SBOM + SLSA provenance). See [aws-kubectl-docker](https://github.com/heyvaldemar/aws-kubectl-docker) for that pattern.
- Kubernetes Helm charts (different surface — values schema, chart test, etc.).
- Library / CLI repos (entirely different concerns).

## Expected time per repo

| Phase | Hours | Automation potential |
|---|---|---|
| 0 — Security audit + `.env` hygiene | 0.5–1 | Low (per-repo secrets differ) |
| 1 — Community files + scaffolding | 0.5–1 | **High** (mostly file copies) |
| 2 — CI workflow hardening | 0.5–1 | **High** (identical pins across repos) |
| 3 — Upstream image digest pinning | 0.5–1 | **High** (script-automated digest resolution) |
| 4 — README rewrite | 1.5–2 | Medium (skeleton template + per-service fills) |
| 5 — OpenSSF Scorecard | 0.25–0.5 | **High** (drop-in file) |
| 6 — CI linting + upstream image scanning | 0.5–1 | **High** (drop-in job skeletons + per-repo matrix fill) |
| **Total** | **~4–7.5 h** | — |

First-time application against `keycloak-traefik-letsencrypt-docker-compose` took ~10-12 hours across 7 PRs. With this runbook + the included templates and scripts, subsequent repos should take ~4–6 hours of focused work.

## Quick start

```bash
# 1. Clone the target repo and this runbook side by side
cd ~/repos
git clone https://github.com/<you>/<service>-traefik-letsencrypt-docker-compose
git clone https://github.com/heyvaldemar/self-host-repo-hardening-runbook

# 2. Open the runbook
cd self-host-repo-hardening-runbook
$EDITOR RUNBOOK.md

# 3. Work through Phase 0 → Phase 5, one PR each, merge between phases
```

Main reference: **[`RUNBOOK.md`](RUNBOOK.md)** — the full step-by-step playbook.

## Reference implementations

The patterns in this runbook were developed against two live repositories. Use them as working examples when the runbook prose is ambiguous:

| Repo | Type | Supply chain surface |
|---|---|---|
| [aws-kubectl-docker](https://github.com/heyvaldemar/aws-kubectl-docker) | Publishes own image | Cosign signing + SBOM + SLSA provenance + Trivy SARIF + digest-pinned base + 7.8 OpenSSF Scorecard |
| [keycloak-traefik-letsencrypt-docker-compose](https://github.com/heyvaldemar/keycloak-traefik-letsencrypt-docker-compose) | Deployment template | Digest-pinned upstream images + Dependabot auto-bumps + CI weekly deployment smoke + OpenSSF Scorecard |

This runbook targets the second shape (deployment template). For the first shape, see the `aws-kubectl-docker` repo directly — its PR history is the narrative.

## Repository contents

```
self-host-repo-hardening-runbook/
├── README.md                     ← you are here
├── RUNBOOK.md                    ← the main runbook
├── LICENSE                       ← MIT
├── SECURITY.md                   ← disclosure policy for this repo
├── CHANGELOG.md                  ← version history
├── templates/                    ← drop-in or find/replace-ready files
│   ├── LICENSE.mit.tmpl
│   ├── SECURITY.md.tmpl
│   ├── CHANGELOG.md.tmpl
│   ├── dependabot.yml
│   ├── scorecard.yml
│   ├── deployment-verification.yml.tmpl
│   └── README.md.tmpl
├── scripts/                      ← helpers for digest + SHA resolution
│   ├── resolve-image-digest.sh
│   └── dereference-github-tag.sh
└── .github/
    ├── dependabot.yml            ← dogfood
    └── workflows/
        └── scorecard.yml         ← dogfood
```

## Contributing

This runbook codifies one maintainer's standard. PRs are welcome, but only for:

- Correctness fixes (e.g., a template field that's wrong)
- Security-posture improvements (e.g., a new check that raises the bar)
- Template-automation helpers (e.g., a script that resolves digests faster)

PRs expanding scope beyond "hardening public self-host deployment templates to match the reference implementations" will likely be declined as drift.

See [`SECURITY.md`](SECURITY.md) for the vulnerability disclosure process.

---

<div align="center">

**Maintained by [Vladimir Mikhalev](https://github.com/heyvaldemar)** — Docker Captain · IBM Champion · AWS Community Builder

[YouTube](https://www.youtube.com/channel/UCf85kQ0u1sYTTTyKVpxrlyQ?sub_confirmation=1) · [Blog](https://heyvaldemar.com) · [LinkedIn](https://www.linkedin.com/in/heyvaldemar/)

</div>
