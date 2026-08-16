# syntax=docker/dockerfile:1.26
# =============================================================================
# Matrix All-in-One — Wrapper around the official Synapse image
# Adds: coturn (TURN/STUN), Element Web, Ketesa (admin UI), lighttpd, s6-overlay
#
# GitHub:  https://github.com/junkerderprovinz/matrix
# Image:   ghcr.io/junkerderprovinz/matrix
# License: AGPL-3.0-only
# =============================================================================

# -----------------------------------------------------------------------------
# Global build args — declared BEFORE the first FROM so they are available
# in every stage's FROM line. Per stage they still need to be re-declared
# with `ARG <name>` to be available inside RUN/COPY/etc.
#
# THIS FILE IS THE SINGLE SOURCE OF TRUTH for the component versions. The build
# workflow must not shadow these with its own build-args, or Renovate (whose
# custom managers match exactly these lines) would bump values that never reach
# the published image. The one exception is SYNAPSE_VERSION: build.yml resolves
# the latest upstream Synapse release at build time and passes it in on purpose,
# so the value below is only the local `docker build` default.
# -----------------------------------------------------------------------------
ARG SYNAPSE_VERSION=v1.158.0
ARG ELEMENT_VERSION=v1.12.25
ARG SYNAPSE_ADMIN_VERSION=v1.4.0
ARG MAS_VERSION=1.22.0
ARG S6_OVERLAY_VERSION=3.2.0.2

# -----------------------------------------------------------------------------
# Stage 1 — Pull Element Web static assets
# -----------------------------------------------------------------------------
ARG ELEMENT_VERSION
FROM vectorim/element-web:${ELEMENT_VERSION} AS element-web

# -----------------------------------------------------------------------------
# Stage 2 — Pull the admin UI static assets
#
# Ketesa (github.com/etkecc/ketesa), formerly published as etkecc/synapse-admin,
# is the maintained fork of Awesome-Technologies/synapse-admin. It is a drop-in
# replacement, is the only variant that understands a homeserver delegating auth
# to Matrix Authentication Service, and unlike the original it is still shipping
# releases. Renovate tracks this same image, so the tag here is the one that is
# actually built.
# -----------------------------------------------------------------------------
ARG SYNAPSE_ADMIN_VERSION
FROM ghcr.io/etkecc/ketesa:${SYNAPSE_ADMIN_VERSION} AS synapse-admin

# -----------------------------------------------------------------------------
# Stage 3 — Pull the Matrix Authentication Service (MAS) binary + assets
#
# MAS is Element's OAuth 2.0 / OIDC provider for Matrix. It is what makes QR code
# device linking (MSC4108) possible: Synapse refuses to start with
# msc4108_enabled unless auth is delegated to MAS, and /_matrix/client/v1/
# auth_metadata does not exist without it.
#
# It is shipped here but NOT started unless AUTH_ENABLED=true. With the switch
# off the binary is inert dead weight (~50 MB) and the rendered Synapse config is
# byte-for-byte what it was before MAS existed.
#
# The upstream image is distroless (no shell), entrypoint /usr/local/bin/mas-cli,
# with templates, translations, assets and policy.wasm under /usr/local/share/
# mas-cli. Both linux/amd64 and linux/arm64 are published. Its base is
# distroless/cc-debian13 while ours is python:*-slim-trixie, so the glibc
# generation matches — the ldd check below is what proves that per build.
# -----------------------------------------------------------------------------
ARG MAS_VERSION
FROM ghcr.io/element-hq/matrix-authentication-service:${MAS_VERSION} AS mas

# -----------------------------------------------------------------------------
# Stage 4 — Final image, based on official Synapse
# -----------------------------------------------------------------------------
ARG SYNAPSE_VERSION
FROM ghcr.io/element-hq/synapse:${SYNAPSE_VERSION}

# Re-declare args for use in RUN/LABEL inside this stage
ARG SYNAPSE_VERSION
ARG ELEMENT_VERSION
ARG SYNAPSE_ADMIN_VERSION
ARG MAS_VERSION
ARG S6_OVERLAY_VERSION
ARG TARGETARCH

# OCI image labels
LABEL org.opencontainers.image.title="Matrix All-in-One" \
      org.opencontainers.image.description="Synapse + coturn + Element Web + Ketesa admin UI, plug-and-play for Unraid" \
      org.opencontainers.image.source="https://github.com/junkerderprovinz/matrix" \
      org.opencontainers.image.licenses="AGPL-3.0-only" \
      org.opencontainers.image.version="${SYNAPSE_VERSION}" \
      org.opencontainers.image.vendor="junkerderprovinz" \
      maintainer="junkerderprovinz"

# Switch to root for system-level setup. s6-overlay (PID 1) will drop
# privileges to the synapse user via the gosu calls inside services.d.
# hadolint ignore=DL3002
USER root

# Use bash with pipefail for any RUN that uses pipes (curl | tar etc.)
# so a failing curl aborts the build instead of being masked by tar.
# hadolint ignore=DL4006
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Install runtime dependencies in a single layer to keep image size down.
# - coturn:        TURN/STUN server for voice/video calls
# - lighttpd:      lightweight HTTP server for static assets (Element + Admin)
# - gettext-base:  provides envsubst for template rendering
# - gosu:          minimal setuid helper (used by s6 service scripts)
# - openssl:       generate random secrets (TURN secret, registration token)
# - ca-certificates, curl: health checks and HTTPS fetches
# - tzdata:        timezone data for TZ env var support
# - xz-utils:      decompress s6-overlay .tar.xz archives
# - jq:            parse JSON in shell scripts
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        coturn \
        lighttpd \
        gettext-base \
        gosu \
        openssl \
        ca-certificates \
        curl \
        tzdata \
        xz-utils \
        jq \
    && rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
# Optional S3 media storage provider (matrix-org/synapse-s3-storage-provider).
#
# Installed into the SAME Python environment Synapse itself runs under (the
# official image has no separate venv — Synapse is pip-installed straight into
# system site-packages), so `s3_storage_provider.S3StorageProviderBackend`
# becomes importable without any extra PYTHONPATH wiring. Inert when unused:
# same "always shipped, opt-in at runtime" pattern as the MAS binary above.
# Most of its own dependencies (PyYAML, Twisted, psycopg2) are already present
# as part of Synapse; this mainly adds boto3/botocore/humanize/tqdm.
# -----------------------------------------------------------------------------
RUN pip install --no-cache-dir --break-system-packages synapse-s3-storage-provider==1.6.1

# Install s6-overlay v3 (init system + process supervisor).
# Architecture mapping: Docker TARGETARCH uses different names than s6-overlay release filenames.
RUN case "${TARGETARCH}" in \
        amd64)  S6_ARCH="x86_64"   ;; \
        arm64)  S6_ARCH="aarch64"  ;; \
        arm)    S6_ARCH="arm"      ;; \
        *)      echo "Unsupported arch: ${TARGETARCH}" && exit 1 ;; \
    esac \
    && S6_BASE="https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}" \
    && curl -fsSL "${S6_BASE}/s6-overlay-noarch.tar.xz"        | tar -C / -Jxp \
    && curl -fsSL "${S6_BASE}/s6-overlay-${S6_ARCH}.tar.xz"    | tar -C / -Jxp

# -----------------------------------------------------------------------------
# Copy static web assets from earlier stages.
#
# vectorim/element-web stores the built site at /app (the nginx container has
# /usr/share/nginx/html as a symlink to /app — we copy the real path to avoid
# dangling symlinks).
#
# Ketesa does NOT use that convention: it is built on static-web-server, runs as
# the unprivileged `sws` user and keeps the built site at /home/sws/public. We
# take the root-base build (assets referenced relatively), which is what makes it
# work unchanged under lighttpd's /admin/ prefix.
# -----------------------------------------------------------------------------
COPY --from=element-web   /app              /var/www/html/element
COPY --from=synapse-admin /home/sws/public  /var/www/html/admin

# -----------------------------------------------------------------------------
# Matrix Authentication Service binary + its templates/assets/policy.
#
# The ldd check is deliberate and must not be dropped: MAS is built against a
# different (distroless) base than ours, and a missing shared library would
# otherwise only surface at runtime on a user's machine — and only on whichever
# architecture happens to be broken. `mas-cli --version` additionally proves the
# binary actually executes under this stage's loader on TARGETARCH.
# -----------------------------------------------------------------------------
COPY --from=mas /usr/local/bin/mas-cli    /usr/local/bin/mas-cli
COPY --from=mas /usr/local/share/mas-cli  /usr/local/share/mas-cli
RUN ldd /usr/local/bin/mas-cli \
    && /usr/local/bin/mas-cli --version \
    && test -f /usr/local/share/mas-cli/policy.wasm

# Copy our rootfs overlay (service scripts, config templates, init scripts)
COPY rootfs/ /

# Init-log banner: single source at .github/assets/banner-raw.txt (the shared
# Junker-der-Provinz banner; CR stripped so the log shows it cleanly). It is
# printed by print-banner.sh from the matrix-ready service, as the last log
# block directly above the "MATRIX IS READY" box.
COPY .github/assets/banner-raw.txt /usr/local/share/banner-raw.txt
RUN tr -d '\r' < /usr/local/share/banner-raw.txt > /usr/local/share/banner.txt

# Make all shell scripts executable.
# cont-init.d scripts: run once at startup (in lexicographic order)
# services.d/*/run:   executed by s6 as long-running services
RUN find /etc/cont-init.d /etc/services.d \( -name "run" -o -name "*.sh" \) -print0 \
        | xargs -0 chmod +x

# Make a failing cont-init script actually stop the container.
#
# s6-overlay v3 defaults S6_BEHAVIOUR_IF_STAGE2_FAILS to 0, "continue silently".
# Every `exit 1` guard in cont-init.d was therefore decorative: 10-config.sh has
# claimed since v2.1.1 to be "halting container start so the broken state is
# visible", while s6 shrugged and started Synapse anyway on top of a config that
# was known to be broken. Missing SERVER_NAME, a failed --generate-config or an
# incomplete MAS setup all produced a running-but-wrong container instead of a
# loud stop.
#
# 2 = stop the container. Every exit 1 in cont-init.d is a genuine
# misconfiguration that the user has to fix, so failing visibly is strictly
# better than limping on.
ENV S6_BEHAVIOUR_IF_STAGE2_FAILS=2

# Synapse stores all persistent data here: homeserver.yaml, media, uploads, keys
VOLUME /data

# Port layout:
#   8008/tcp  — Synapse Matrix HTTP API (behind reverse proxy)
#   8080/tcp  — lighttpd: Element Web + Ketesa (well-known is served by Synapse on 8008)
#   8090/tcp  — Matrix Authentication Service (only listening when AUTH_ENABLED=true).
#               Deliberately NOT 8080: that is MAS's own default bind and would
#               collide with lighttpd inside this container.
#   3478/tcp  — coturn TURN/STUN (TCP)
#   3478/udp  — coturn TURN/STUN (UDP)
#   5349/tcp  — coturn TURN over TLS (TCP, optional — requires certs at /data/certs/)
#   5349/udp  — coturn TURN over TLS (UDP, optional — requires certs at /data/certs/)
#   49160-49200/udp — coturn media relay range (must match min-port/max-port
#                     in turnserver.conf.tmpl and the Unraid template)
#   9090/tcp  — Prometheus metrics endpoint (/_synapse/metrics)
EXPOSE 8008/tcp 8080/tcp 8090/tcp 3478/tcp 3478/udp 5349/tcp 5349/udp 9090/tcp
EXPOSE 49160-49200/udp

# Health check: Synapse exposes a dedicated /health endpoint
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD ["sh", "-c", "curl -fsSL http://127.0.0.1:8008/health || exit 1"]

# s6-overlay takes over as PID 1 and supervises all services
ENTRYPOINT ["/init"]
