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
| Ketesa        | Admin UI (static, from upstream image) | 8080/admin/          |
| lighttpd      | Serves the two static web apps         | 8080                 |
| MAS           | Auth service, **only if AUTH_ENABLED**  | 8090 (health 8091)  |
| Prometheus    | Synapse metrics endpoint               | 9090                 |

s6-overlay v3 is PID 1 and supervises the services. PostgreSQL is **external**
(not in the image). The image is published to `ghcr.io/junkerderprovinz/matrix`
and mirrored to `docker.io/junkerderprovinz/matrix` once the Docker Hub
credentials are set. The Unraid CA template lives in the central `unraid-apps`
repo, not here.

## Layout

```
Dockerfile                       Multi-stage: element-web + ketesa + mas -> synapse
rootfs/                          Overlay copied into the image (COPY rootfs/ /)
  etc/cont-init.d/               s6 one-shot init (00-banner.sh, 10-config.sh,
                                 15-s3-media.sh, 20-mas.sh, 25-mas-migrate.sh —
                                 order matters: 15 and 20 both patch 10's
                                 output, 25 runs while Synapse is still
                                 stopped, which is what syn2mas needs)
  etc/services.d/*/run           s6 long-running services (synapse, coturn,
                                 lighttpd, mas, admin-bootstrap, matrix-ready)
  defaults/*.tmpl                envsubst config templates (homeserver overrides,
                                 element-config, turnserver, mas-config,
                                 mas-overrides, s3-media-overrides) + lighttpd.conf
  usr/local/bin/print-banner.sh  Prints the init-log banner
.github/workflows/               build.yml, lint.yml, release.yml
.github/assets/                  Banner/logo/icon sources + gen-banner.mjs, screenshots
.github/release-notes/<tag>.md   Per-release changelog consumed by release.yml
.github/DOCKERHUB.md             Condensed description synced to Docker Hub
renovate.json                    Dependency automation config
```

There is no Go, no application source to compile, and no frontend to build in
this repo — Element Web and Ketesa arrive prebuilt from their upstream
images. The only "build" is `docker build`.

**Component versions live in the Dockerfile ARGs and nowhere else.** `build.yml`
must not pass ELEMENT_VERSION / SYNAPSE_ADMIN_VERSION / S6_OVERLAY_VERSION as
build-args: doing so shadows the Dockerfile, and Renovate's custom managers match
the Dockerfile lines, so bumps would never reach the image. SYNAPSE_VERSION is the
sole exception (resolved to the latest upstream release at build time). Renovate's
datasources must point at the registry the Dockerfile actually pulls from, not at
a same-named GitHub repo.

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
- **Delegated auth is opt-in, and that is a hard contract.** With `AUTH_ENABLED`
  unset or false, `20-mas.sh` must leave the rendered `homeserver-overrides.yaml`
  byte-for-byte as it was before MAS existed — not "delegation disabled", absent.
  CI asserts this. Users pull `:latest` unattended; a feature that rearranges
  their auth on a routine update would be a catastrophe. Every env read uses
  `${AUTH_X:-default}` (never `${AUTH_X-default}`) because a blank Unraid
  template field arrives as `-e AUTH_ENABLED=`, i.e. set but empty.
- **S3 media storage is opt-in on the same hard-contract terms as MAS.** With
  `S3_MEDIA_ENABLED` unset or false, `15-s3-media.sh` must leave the rendered
  `homeserver-overrides.yaml` byte-for-byte unchanged — no `media_storage_providers`
  key, nothing. `S3_MEDIA_ENDPOINT` has no default and fails loudly if unset when
  enabled: this targets a self-hosted S3-compatible backend (SeaweedFS, Garage,
  MinIO), not bare AWS, so silently falling back to AWS's real endpoint would be
  worse than refusing to start.
- **Synapse traps under delegation:** `enable_registration: true` is a hard
  ConfigError (Synapse will not start), and `experimental_features` may appear
  only once in the merged YAML — `20-mas.sh` strips both from the base render
  before appending. `mas-cli syn2mas` never writes to Synapse's database.
- **syn2mas needs BOTH Synapse config files.** The database connection is
  rendered into `homeserver-overrides.yaml`, so `--synapse-config` must be passed
  twice (base then overrides). With only `homeserver.yaml` it reads the generated
  SQLite defaults and migrates from the wrong database.
- **The migration lives in cont-init on purpose.** `25-mas-migrate.sh` runs while
  s6 has not started the synapse service, so the offline window syn2mas requires
  is structural rather than an instruction the operator has to remember. It is
  gated on `AUTH_MIGRATE`, guarded by a `/data/mas/.migrated` marker, and exits
  non-zero on any failure so the container stops instead of coming up
  half-migrated. CI proves the migrated account still logs in with its original
  password — a migration that silently breaks password hashes looks successful in
  every log line.
- **`S6_BEHAVIOUR_IF_STAGE2_FAILS=2` is load-bearing.** s6-overlay v3 defaults it
  to 0 ("continue silently"), which made every `exit 1` guard in cont-init.d
  decorative — 10-config.sh claimed to halt on a broken config while s6 started
  Synapse anyway. Do not remove it.
