# syntax=docker/dockerfile:1.27@sha256:bde3983e9c939224420ddaf6b784cc30e09b035a4dea01f581230c50809f372e
# Matrix All-in-One: the official Synapse image plus coturn, Element Web, Ketesa,
# lighttpd and s6-overlay.
#
# GitHub:  https://github.com/junkerderprovinz/matrix
# Image:   ghcr.io/junkerderprovinz/matrix
# License: AGPL-3.0-only

# The component versions live only here: Renovate bumps these lines, and a
# build-arg in the workflow would override what it bumps. SYNAPSE_VERSION is the
# exception: build.yml passes in the latest Synapse release, so its value below is
# only the default for a local build. Each stage redeclares the args it uses.
ARG SYNAPSE_VERSION=v1.161.0
ARG ELEMENT_VERSION=v1.12.29
ARG SYNAPSE_ADMIN_VERSION=v1.5.0
ARG MAS_VERSION=1.25.1
ARG S6_OVERLAY_VERSION=3.2.0.2

ARG ELEMENT_VERSION
FROM vectorim/element-web:${ELEMENT_VERSION} AS element-web

# Ketesa (github.com/etkecc/ketesa, formerly etkecc/synapse-admin) is the
# maintained fork of Awesome-Technologies/synapse-admin and the only one that
# understands a homeserver delegating auth to Matrix Authentication Service.
ARG SYNAPSE_ADMIN_VERSION
FROM ghcr.io/etkecc/ketesa:${SYNAPSE_ADMIN_VERSION} AS synapse-admin

# Matrix Authentication Service (MAS), Element's OIDC provider. QR code device
# linking (MSC4108) needs it: Synapse refuses msc4108_enabled without delegated
# auth, and /_matrix/client/v1/auth_metadata exists only with it. MAS starts only
# when AUTH_ENABLED=true; otherwise the binary (~50 MB) sits unused and the
# rendered Synapse config is unchanged.
#
# The upstream image is distroless, with the binary at /usr/local/bin/mas-cli and
# its templates, translations, assets and policy.wasm under /usr/local/share/mas-cli.
# Its distroless/cc-debian13 base shares the glibc generation of our
# python:*-slim-trixie base, which the ldd check below proves per architecture.
ARG MAS_VERSION
FROM ghcr.io/element-hq/matrix-authentication-service:${MAS_VERSION} AS mas

# Debian's gosu is built with a Go whose os and os/exec flaws govulncheck finds
# reachable in it; the upstream static build has none.
FROM tianon/gosu:1.19 AS gosu

ARG SYNAPSE_VERSION
FROM ghcr.io/element-hq/synapse:${SYNAPSE_VERSION}

ARG SYNAPSE_VERSION
ARG ELEMENT_VERSION
ARG SYNAPSE_ADMIN_VERSION
ARG MAS_VERSION
ARG S6_OVERLAY_VERSION
ARG TARGETARCH

LABEL org.opencontainers.image.title="Matrix All-in-One" \
      org.opencontainers.image.description="Synapse + coturn + Element Web + Ketesa admin UI, plug-and-play for Unraid" \
      org.opencontainers.image.source="https://github.com/junkerderprovinz/matrix" \
      org.opencontainers.image.licenses="AGPL-3.0-only" \
      org.opencontainers.image.version="${SYNAPSE_VERSION}" \
      org.opencontainers.image.vendor="junkerderprovinz" \
      maintainer="junkerderprovinz"

# s6-overlay runs as root; Synapse and MAS drop to PUID:PGID with gosu.
# hadolint ignore=DL3002
USER root

# pipefail, so a failing curl in `curl | tar` stops the build.
# hadolint ignore=DL4006
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# gettext-base provides envsubst for the config templates.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        coturn \
        lighttpd \
        gettext-base \
        openssl \
        ca-certificates \
        curl \
        tzdata \
        xz-utils \
        jq \
    && rm -rf /var/lib/apt/lists/*

COPY --from=gosu /gosu /usr/local/bin/gosu

# Optional S3 media storage (matrix-org/synapse-s3-storage-provider), unused unless
# S3_MEDIA_ENABLED=true. The official image installs Synapse into the system
# site-packages without a venv, so the provider installed next to it is importable
# with no PYTHONPATH wiring. It mainly adds boto3 and its dependencies.
RUN pip install --no-cache-dir --break-system-packages synapse-s3-storage-provider==1.6.1

# s6-overlay names its release files after the machine architecture, not TARGETARCH.
RUN case "${TARGETARCH}" in \
        amd64)  S6_ARCH="x86_64"   ;; \
        arm64)  S6_ARCH="aarch64"  ;; \
        arm)    S6_ARCH="arm"      ;; \
        *)      echo "Unsupported arch: ${TARGETARCH}" && exit 1 ;; \
    esac \
    && S6_BASE="https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}" \
    && curl -fsSL "${S6_BASE}/s6-overlay-noarch.tar.xz"        | tar -C / -Jxp \
    && curl -fsSL "${S6_BASE}/s6-overlay-${S6_ARCH}.tar.xz"    | tar -C / -Jxp

# element-web keeps the built site at /app (its /usr/share/nginx/html is only a
# symlink to it). Ketesa, built on static-web-server, keeps its site at
# /home/sws/public; the root-base build references its assets relatively, so it
# works unchanged under lighttpd's /admin/ prefix.
COPY --from=element-web   /app              /var/www/html/element
COPY --from=synapse-admin /home/sws/public  /var/www/html/admin

# MAS is built on another base than ours, so ldd catches a missing shared library
# here, per architecture, instead of on a user's machine, and `mas-cli --version`
# proves the binary runs under this stage's loader.
COPY --from=mas /usr/local/bin/mas-cli    /usr/local/bin/mas-cli
COPY --from=mas /usr/local/share/mas-cli  /usr/local/share/mas-cli
RUN ldd /usr/local/bin/mas-cli \
    && /usr/local/bin/mas-cli --version \
    && test -f /usr/local/share/mas-cli/policy.wasm

COPY rootfs/ /

# The shared init-log banner, printed by print-banner.sh just above the
# "MATRIX IS READY" box. CRs are stripped so the log shows it cleanly.
COPY .github/assets/banner-raw.txt /usr/local/share/banner-raw.txt
RUN tr -d '\r' < /usr/local/share/banner-raw.txt > /usr/local/share/banner.txt

RUN find /etc/cont-init.d /etc/services.d \( -name "run" -o -name "*.sh" \) -print0 \
        | xargs -0 chmod +x

# s6-overlay's default of 0 carries on after a failed cont-init script and starts
# Synapse on a config known to be broken. Every exit 1 in cont-init.d is a
# misconfiguration the user has to fix, so 2 stops the container instead.
ENV S6_BEHAVIOUR_IF_STAGE2_FAILS=2

# Synapse stores all persistent data here: homeserver.yaml, media, uploads, keys
VOLUME /data

# 8008/tcp            Synapse Matrix HTTP API (behind a reverse proxy)
# 8080/tcp            lighttpd: Element Web and Ketesa (well-known is served by Synapse on 8008)
# 8090/tcp            Matrix Authentication Service, listening only when AUTH_ENABLED=true.
#                     Not 8080, the MAS default, which lighttpd holds in this container.
# 3478/tcp, 3478/udp  coturn TURN/STUN
# 5349/tcp, 5349/udp  coturn TURN over TLS, only with certificates in /data/certs/
# 49160-49200/udp     coturn media relay range; must match min-port/max-port in
#                     turnserver.conf.tmpl and the Unraid template
# 9090/tcp            Prometheus metrics (/_synapse/metrics)
EXPOSE 8008/tcp 8080/tcp 8090/tcp 3478/tcp 3478/udp 5349/tcp 5349/udp 9090/tcp
EXPOSE 49160-49200/udp

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD ["sh", "-c", "curl -fsSL http://127.0.0.1:8008/health || exit 1"]

ENTRYPOINT ["/init"]
