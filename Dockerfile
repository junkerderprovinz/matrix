# syntax=docker/dockerfile:1.6
# =============================================================================
# Matrix All-in-One — Wrapper around the official Synapse image
# Adds: coturn (TURN/STUN), Element Web, Synapse-Admin, lighttpd, s6-overlay
#
# GitHub:  https://github.com/junkerderprovinz/matrix
# Image:   ghcr.io/junkerderprovinz/matrix
# License: Apache 2.0
# =============================================================================

# -----------------------------------------------------------------------------
# Stage 1 — Pull Element Web static assets
# -----------------------------------------------------------------------------
FROM vectorim/element-web:${ELEMENT_VERSION:-v1.11.92} AS element-web

# -----------------------------------------------------------------------------
# Stage 2 — Pull Synapse-Admin static assets
# -----------------------------------------------------------------------------
FROM awesometechnologies/synapse-admin:${SYNAPSE_ADMIN_VERSION:-0.10.3} AS synapse-admin

# -----------------------------------------------------------------------------
# Stage 3 — Final image, based on official Synapse
# -----------------------------------------------------------------------------
ARG SYNAPSE_VERSION=v1.152.1
ARG ELEMENT_VERSION=v1.11.92
ARG SYNAPSE_ADMIN_VERSION=0.10.3
ARG S6_OVERLAY_VERSION=3.2.0.2

FROM ghcr.io/element-hq/synapse:${SYNAPSE_VERSION}

# Inherit build args into this stage
ARG SYNAPSE_VERSION
ARG ELEMENT_VERSION
ARG SYNAPSE_ADMIN_VERSION
ARG S6_OVERLAY_VERSION

# OCI image labels
LABEL org.opencontainers.image.title="Matrix All-in-One" \
      org.opencontainers.image.description="Synapse + coturn + Element Web + Synapse-Admin, Plug-and-Play für Unraid" \
      org.opencontainers.image.source="https://github.com/junkerderprovinz/matrix" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.version="${SYNAPSE_VERSION}" \
      org.opencontainers.image.vendor="junkerderprovinz" \
      maintainer="junkerderprovinz"

# Switch to root for system-level setup
USER root

# Install runtime dependencies in a single layer to keep image size down.
# - coturn:        TURN/STUN server for voice/video calls
# - lighttpd:      lightweight HTTP server for static assets (Element + Admin)
# - gettext-base:  provides envsubst for template rendering
# - su-exec:       minimal setuid helper (used by s6 service scripts)
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
        su-exec \
        openssl \
        ca-certificates \
        curl \
        tzdata \
        xz-utils \
        jq \
    && rm -rf /var/lib/apt/lists/*

# Install s6-overlay v3 (init system + process supervisor).
# Architecture mapping: Docker TARGETARCH uses different names than s6-overlay release filenames.
ARG TARGETARCH
RUN case "${TARGETARCH}" in \
        amd64)  S6_ARCH="x86_64"   ;; \
        arm64)  S6_ARCH="aarch64"  ;; \
        arm)    S6_ARCH="arm"      ;; \
        *)      echo "Unsupported arch: ${TARGETARCH}" && exit 1 ;; \
    esac \
    && S6_BASE="https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}" \
    && curl -fsSL "${S6_BASE}/s6-overlay-noarch.tar.xz"        | tar -C / -Jxp \
    && curl -fsSL "${S6_BASE}/s6-overlay-${S6_ARCH}.tar.xz"    | tar -C / -Jxp

# Copy Element Web static assets from stage 1.
# Element serves at /var/www/html/element/
COPY --from=element-web /usr/share/nginx/html /var/www/html/element

# Copy Synapse-Admin static assets from stage 2.
# Admin UI serves at /var/www/html/admin/
COPY --from=synapse-admin /usr/share/nginx/html /var/www/html/admin

# Copy our rootfs overlay (service scripts, config templates, init scripts)
COPY rootfs/ /

# Make all shell scripts executable.
# cont-init.d scripts: run once at startup (in lexicographic order)
# services.d/*/run:   executed by s6 as long-running services
RUN find /etc/cont-init.d /etc/services.d -name "run" -o -name "*.sh" \
        | xargs chmod +x \
    && chmod +x /etc/cont-init.d/10-config.sh

# Synapse stores all persistent data here: homeserver.yaml, media, uploads, keys
VOLUME /data

# Port layout:
#   8008/tcp  — Synapse Matrix HTTP API (behind reverse proxy)
#   8080/tcp  — lighttpd: Element Web + Synapse-Admin
#   3478/tcp  — coturn TURN/STUN (TCP)
#   3478/udp  — coturn TURN/STUN (UDP)
#   5349/tcp  — coturn TURN over TLS (TCP, optional)
#   5349/udp  — coturn TURN over TLS (UDP, optional)
EXPOSE 8008/tcp 8080/tcp 3478/tcp 3478/udp 5349/tcp 5349/udp

# Health check: Synapse exposes a dedicated /health endpoint
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -fsSL http://127.0.0.1:8008/health || exit 1

# s6-overlay takes over as PID 1 and supervises all services
ENTRYPOINT ["/init"]
