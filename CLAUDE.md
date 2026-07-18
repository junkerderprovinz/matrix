# CLAUDE.md — Matrix All-in-One

Guide for working in this repo. Keep it accurate to what is actually here.

## What this is

A single Docker image that wraps the **official Synapse image**
(`ghcr.io/element-hq/synapse`) and layers on everything needed for a
plug-and-play Matrix homeserver on Unraid:

| Component     | Role                                   | Port(s)              |
|---------------|----------------------------------------|----------------------|
| Synapse       | Matrix homeserver (from upstream image)| 8008                 |
| coturn        | TURN/STUN for voice/video              | 3478, 5349, 49160-49200/udp |
| Element Web   | Web client (static, from upstream image)| 8080/element/       |
| Synapse-Admin | Admin UI (static, from upstream image) | 8080/admin/          |
| lighttpd      | Serves the two static web apps         | 8080                 |
| Prometheus    | Synapse metrics endpoint               | 9090                 |

s6-overlay v3 is PID 1 and supervises the services. PostgreSQL is **external**
(not in the image). The image is published to `ghcr.io/junkerderprovinz/matrix`
and mirrored to `docker.io/junkerderprovinz/matrix` once the Docker Hub
credentials are set. The Unraid CA template lives in the central `unraid-apps`
repo, not here.

## Layout

```
Dockerfile                       Multi-stage: element-web + synapse-admin -> synapse
rootfs/                          Overlay copied into the image (COPY rootfs/ /)
  etc/cont-init.d/               s6 one-shot init (00-banner.sh, 10-config.sh)
  etc/services.d/*/run           s6 long-running services (synapse, coturn,
                                 lighttpd, admin-bootstrap, matrix-ready)
  defaults/*.tmpl                envsubst config templates (homeserver overrides,
                                 element-config, turnserver) + lighttpd.conf
  usr/local/bin/print-banner.sh  Prints the init-log banner
.github/workflows/               build.yml, lint.yml, release.yml
.github/assets/                  Banner/logo/icon sources + gen-banner.mjs, screenshots
.github/release-notes/<tag>.md   Per-release changelog consumed by release.yml
.github/DOCKERHUB.md             Condensed description synced to Docker Hub
renovate.json                    Dependency automation config
```

There is no Go, no application source to compile, and no frontend to build in
this repo — Element Web and Synapse-Admin arrive prebuilt from their upstream
images. The only "build" is `docker build`.

## Build / run / test (local)

Recipes are in the `justfile` (`just --list`). The real commands underneath:

- **Build:** `docker build -t matrix:dev .` — version pins come from the
  Dockerfile `ARG` defaults (`SYNAPSE_VERSION`, `ELEMENT_VERSION`,
  `SYNAPSE_ADMIN_VERSION`, `S6_OVERLAY_VERSION`); override with `--build-arg`.
- **Smoke test:** boot the image against a throwaway PostgreSQL and wait for
  `http://localhost:8008/health` (`just smoke`). Mirrors the CI gate; needs a
  Postgres initialised with `--lc-collate=C --lc-ctype=C`.
- **Lint:** `just lint` = hadolint (Dockerfile) + shellcheck (rootfs scripts) +
  yamllint (workflows). `just secrets` runs gitleaks. `just check` chains lint +
  secrets. `just scan` runs the Trivy CVE scan locally.

## CI gates

- **lint.yml** (push to main + PRs): hadolint on `Dockerfile`
  (`--ignore DL3008,DL3009`, `failure-threshold: warning`); shellcheck on every
  `rootfs/**` `*.sh` and s6 `run` script (`-S warning -x -e SC1091`); yamllint on
  `.github/workflows/` (line-length max 160); and a Python `yaml.safe_load`
  validation of `rootfs/defaults/*.yaml.tmpl` (placeholders substituted first).
- **build.yml** (hourly cron + push to main + manual dispatch): resolves the
  latest Synapse release tag, skips if that image already exists (unless a push
  or `force_rebuild`), then **builds an amd64 smoke image (`matrix:smoke-amd64`)
  and boots it** — it must serve `/health`, must NOT have fallen back to SQLite,
  and must have created tables in the throwaway PostgreSQL. Only then does it
  build+push the multi-arch (`amd64,arm64`) image to GHCR (and Docker Hub if
  configured) with `:latest`, `:v1.x.y`, and `:1.x.y` tags. A **non-blocking
  Trivy CVE scan** (HIGH/CRITICAL, `ignore-unfixed`, `exit-code: 0`) runs on the
  smoke image and uploads SARIF to the Security tab; the pushed image carries
  **SBOM + provenance** attestations.
- **release.yml** (tag `v*.*.*`): creates the GitHub release from
  `.github/release-notes/<tag>.md` (falls back to auto-generated notes if the
  file is missing).

## Release procedure

- Versioning: 3-digit SemVer. Repo release tag = `vX.Y.Z`; the GitHub release
  **title is the version only** (`vX.Y.Z`), no repo name in the heading.
- Write the full changelog to `.github/release-notes/vX.Y.Z.md` **before**
  tagging — the release body is the whole changelog, not a link list.
- The image's own `:v1.x.y` tag tracks the **upstream Synapse** version and is
  independent of the repo release tag.
- **Never tag or cut a release without explicit approval.**

## Repo-specific gotchas

- **Line endings:** `.gitattributes` pins `*.sh`, the banner, and all of
  `rootfs/**` to `eol=lf`. CRLF breaks shebangs and s6 scripts inside the image —
  strip CR from any new file that ships into the image.
- **s6 env:** cont-init scripts that read container env vars must use the
  `#!/command/with-contenv sh` shebang; without it s6-overlay v3 runs them with
  an empty environment and `SERVER_NAME`/`POSTGRES_*` appear unset.
- **PostgreSQL locale:** Synapse refuses to start unless the DB is UTF8 with `C`
  collation. If the override `--config-path` is dropped, Synapse silently falls
  back to SQLite with every override dead (the issue #3 regression) — the smoke
  test now asserts against exactly this.
- **Pre-push hook:** a global hook runs gitleaks + hadolint (and gofmt if a
  `go.mod` exists). If it blocks, fix the cause — never `--no-verify`.
- **Trivy is report-only** (`exit-code: 0`); unfixed upstream CVEs do not gate
  the build.
- **Commits:** English in the repo, no AI attribution.
