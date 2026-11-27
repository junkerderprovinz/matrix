# syntax=docker/dockerfile:1.29@sha256:572cebbc2b15e6f84c077742952674889cb63cd5e9b80abdffcbe587b6f19183
# Matrix All-in-One: the official Synapse image plus coturn, Element Web, Ketesa,
# lighttpd and s6-overlay.
#
# GitHub:  https://github.com/junkerderprovinz/matrix
# Image:   ghcr.io/junkerderprovinz/matrix
# License: AGPL-3.0-only

# The component versions live only here: Renovate bumps these lines, and a
# build-arg in the workflow would override what it bumps. Each stage redeclares
# the args it uses.
# renovate: datasource=docker depName=ghcr.io/element-hq/synapse
ARG SYNAPSE_VERSION=v1.165.0
# renovate: datasource=docker depName=vectorim/element-web
ARG ELEMENT_VERSION=v1.12.36
# Ketesa follows the registry, as its GitHub tags do not all get an image.
# renovate: datasource=docker depName=ghcr.io/etkecc/ketesa
ARG SYNAPSE_ADMIN_VERSION=v1.5.2
# renovate: datasource=docker depName=ghcr.io/element-hq/matrix-authentication-service
ARG MAS_VERSION=1.29.0
# renovate: datasource=github-releases depName=just-containers/s6-overlay versioning=loose
ARG S6_OVERLAY_VERSION=3.2.3.2

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

# A Go binary carries the standard library it was built with, and both Debian's
# gosu and the upstream release bring a Go 1.24 with open advisories, plus the
# x/sys v0.1.0 gosu's go.mod asks for. So gosu is built here, with the Go
# checksum database verifying its source and x/sys. It cross-compiles natively,
# as Go under QEMU is slow and can hang.
FROM --platform=$BUILDPLATFORM golang:1.27.4-trixie@sha256:f18c3d73a184fb0582828510722e723b63a93f7188d11dd223d9be6f6880e65d AS gosu
# renovate: datasource=github-tags depName=tianon/gosu
ARG GOSU_VERSION=1.20
# renovate: datasource=go depName=golang.org/x/sys
ARG XSYS_VERSION=v0.50.0
ARG TARGETOS
ARG TARGETARCH
WORKDIR /src
RUN go mod init gosu-build \
    && go get "github.com/tianon/gosu@${GOSU_VERSION}" "golang.org/x/sys@${XSYS_VERSION}" \
    && CGO_ENABLED=0 GOOS="${TARGETOS}" GOARCH="${TARGETARCH}" \
       go build -trimpath -ldflags '-d -w' -o /gosu github.com/tianon/gosu

# The workflow names this stage in no-cache-filters, so the apt upgrade below
# runs on every build instead of coming back from the layer cache.
ARG SYNAPSE_VERSION
FROM ghcr.io/element-hq/synapse:${SYNAPSE_VERSION} AS runtime

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
      io.github.junkerderprovinz.matrix.synapse-version="${SYNAPSE_VERSION}" \
      org.opencontainers.image.vendor="junkerderprovinz" \
      maintainer="junkerderprovinz"

# s6-overlay runs as root; Synapse and MAS drop to PUID:PGID with gosu.
# hadolint ignore=DL3002
USER root

# pipefail, so a failing curl in `curl | tar` stops the build.
# hadolint ignore=DL4006
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# gettext-base provides envsubst for the config templates. The upgrade takes the
# Debian security fixes published since upstream built the Synapse image.
# Synapse unpacks its runtime libraries without dpkg and describes each one in
# status.d. Once apt installs or upgrades such a library, its status.d record
# still names the old version and scanners report that one, so it goes.
RUN apt-get update \
    && apt-get upgrade -y \
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
    && for record in /var/lib/dpkg/status.d/*; do \
           if dpkg-query -W "${record##*/}" >/dev/null 2>&1; then rm "$record"; fi; \
       done \
    && rm -rf /var/lib/apt/lists/*

COPY --from=gosu /gosu /usr/local/bin/gosu
# Synapse's start.py runs /usr/sbin/gosu, the Debian copy its image brings, so
# that path leads to ours and the record of the Debian package goes with it.
RUN ln -sf /usr/local/bin/gosu /usr/sbin/gosu \
    && rm -f /var/lib/dpkg/status.d/gosu

# Optional S3 media storage (matrix-org/synapse-s3-storage-provider), unused unless
# S3_MEDIA_ENABLED=true. The official image installs Synapse into the system
# site-packages without a venv, so the provider installed next to it is importable
# with no PYTHONPATH wiring. It mainly adds boto3 and its dependencies.
RUN pip install --no-cache-dir --break-system-packages synapse-s3-storage-provider==1.6.1

# Synapse 1.164 ships authlib 1.6.12, which has open advisories fixed in 1.9.
# The pin can go once a Synapse release carries 1.9.1 or later. authlib 1.9 adds
# joserfc as a dependency; --no-deps keeps pip away from the rest of Synapse's.
# renovate: datasource=pypi depName=authlib
ARG AUTHLIB_VERSION=1.9.10
# renovate: datasource=pypi depName=joserfc
ARG JOSERFC_VERSION=1.8.0
# Synapse's lockfile holds pyasn1 at 0.6.4, and the advisories against it are
# fixed in 0.6.5.
# renovate: datasource=pypi depName=pyasn1
ARG PYASN1_VERSION=0.6.5
# The Synapse image carries soupsieve 2.10 and tornado 6.5.9, both with open
# advisories.
# renovate: datasource=pypi depName=soupsieve
ARG SOUPSIEVE_VERSION=4.1.3
# renovate: datasource=pypi depName=tornado
ARG TORNADO_VERSION=6.6.1
# Synapse 1.165 locks Twisted at 26.4.0, whose advisories 26.10.0 fixes. Synapse
# 1.166 locks 26.10.0, so the pin can go with that release.
# renovate: datasource=pypi depName=twisted
ARG TWISTED_VERSION=26.10.0
# The image carries setuptools 83.0.0, which has an advisory fixed in 84.1.0.
# renovate: datasource=pypi depName=setuptools
ARG SETUPTOOLS_VERSION=84.2.1
# pip 26.2.2 vendors urllib3 2.7.0 and msgpack 1.1.2, and 26.3 the fixed releases.
# renovate: datasource=pypi depName=pip
ARG PIP_VERSION=26.3
RUN pip install --no-cache-dir --break-system-packages --no-deps \
        "authlib==${AUTHLIB_VERSION}" "joserfc==${JOSERFC_VERSION}" "pyasn1==${PYASN1_VERSION}" \
        "soupsieve==${SOUPSIEVE_VERSION}" "tornado==${TORNADO_VERSION}" \
        "twisted==${TWISTED_VERSION}" "setuptools==${SETUPTOOLS_VERSION}" "pip==${PIP_VERSION}"

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

# In /usr/local/bin only the files that lack the bit: a chmod on the others
# would copy them into this layer, and mas-cli alone is 100 MB.
RUN find /etc/cont-init.d /etc/services.d \( -name "run" -o -name "*.sh" \) -print0 \
        | xargs -0 chmod +x \
    && find /usr/local/bin -type f ! -perm -u+x -exec chmod +x {} +

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
