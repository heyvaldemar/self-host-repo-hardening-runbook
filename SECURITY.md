# Security Policy

This repository publishes a runbook (documentation) and a set of templates and helper scripts. There is no deployed service, no packaged binary, and no image published from this repo.

## Supported versions

| Version | Status |
|---------|--------|
| Latest `main` | :white_check_mark: |
| Older | Superseded by latest; pin a specific commit if you want a stable reference |

## Reporting a vulnerability

Send reports to v@valdemar.ai. Encrypted email is preferred: the PGP public key is published at [heyvaldemar.com/security](https://heyvaldemar.com/security).

You can expect an acknowledgment within 7 days. This project does not operate a bounty program.

Please do not open public GitHub issues for security reports.

## Scope of "security issue" for this repo

Valid:

- A template file (`templates/*.tmpl`) that, when applied verbatim, leaks credentials or produces an insecure configuration.
- A helper script (`scripts/*.sh`) that exfiltrates data, bypasses TLS verification, or executes arbitrary untrusted code.
- RUNBOOK guidance that produces an insecure posture when followed faithfully.

Out of scope:

- Security issues in the target repositories that apply this runbook: those belong in each repo's own SECURITY.md.
- Security issues in upstream tooling (Docker, Traefik, Keycloak, GitHub Actions).

## Helper scripts integrity

`scripts/resolve-image-digest.sh` and `scripts/dereference-github-tag.sh` both execute `curl` requests to public registries (Docker Hub, Quay.io, GitHub API) and parse the responses. They never POST, never authenticate, never write outside `/tmp` or stdout. Verify integrity with the commit SHA pin before running against production repos:

```bash
git -C self-host-repo-hardening-runbook log -1 --format='%H' scripts/resolve-image-digest.sh
```

Match the output against the commit SHA in the release you intend to use.
