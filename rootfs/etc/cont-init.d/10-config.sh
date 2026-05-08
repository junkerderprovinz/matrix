#!/command/with-contenv sh
# shellcheck shell=sh
# =============================================================================
# 10-config.sh — Container initialization script
# Runs once at container start (s6-overlay cont-init.d phase, stage 2).
#
# IMPORTANT: the shebang MUST use 'with-contenv' so the container's environment
# variables (set by 'docker run -e' / Unraid template) are available in this
# script. Without it, s6-overlay v3 runs cont-init.d scripts with an empty
# environment and SERVER_NAME, POSTGRES_*, etc. would all appear unset.
# Note: in s6-overlay v3 the binary lives at /command/with-contenv — the
# /usr/bin/with-contenv path only exists if the symlinks-noarch tarball is
# installed, which we do NOT install.
#
# Responsibilities:
#   1. Validate required environment variables
#   2. Generate homeserver.yaml if it does not yet exist (first boot)
#   3. Patch listener configuration (bind to 0.0.0.0, enable x_forwarded)
#   4. Render/overwrite Postgres + performance config overlay
#   5. Generate TURN secret and render turnserver.conf
#   6. Render Element Web config.json (always, so domain changes take effect)
#   7. Fix /data ownership so Synapse can write its files
#
# Design decisions:
#   - Idempotent: safe to re-run; step 2 is skipped when homeserver.yaml exists
#   - Runs as root; Synapse itself is dropped to PUID:PGID inside the run script
#   - Uses envsubst for all template rendering to avoid Python/jinja2 dependency
# =============================================================================

# Note: we deliberately do NOT use 'set -e' here. Each step has explicit error
# handling and we want to make a best-effort attempt at rendering all config
# files even if an earlier optional step fails — otherwise downstream services
# (especially coturn) would hang waiting for files that never get rendered.

# --- Colour helpers (informational output to container logs) ----------------
log_info()  { printf '\033[0;32m[init] INFO:  %s\033[0m\n'  "$*"; }
log_warn()  { printf '\033[0;33m[init] WARN:  %s\033[0m\n'  "$*"; }
log_error() { printf '\033[0;31m[init] ERROR: %s\033[0m\n'  "$*" >&2; }

# =============================================================================
# 1. Validate required environment variables
# =============================================================================
MISSING=""

# SERVER_NAME is the Matrix domain (e.g. matrix.example.com).
# It is used by Synapse to construct @user:SERVER_NAME identifiers.
if [ -z "${SERVER_NAME}" ]; then
    MISSING="${MISSING} SERVER_NAME"
fi

# Postgres connection details — external container, mandatory.
if [ -z "${POSTGRES_HOST}" ]; then
    MISSING="${MISSING} POSTGRES_HOST"
fi
if [ -z "${POSTGRES_USER}" ]; then
    MISSING="${MISSING} POSTGRES_USER"
fi
if [ -z "${POSTGRES_PASSWORD}" ]; then
    MISSING="${MISSING} POSTGRES_PASSWORD"
fi
if [ -z "${POSTGRES_DB}" ]; then
    MISSING="${MISSING} POSTGRES_DB"
fi

if [ -n "${MISSING}" ]; then
    log_error "The following required environment variables are not set:${MISSING}"
    log_error "Please set them in the Unraid template (or docker run -e) and restart the container."
    exit 1
fi

# Apply defaults for optional variables
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
REPORT_STATS="${REPORT_STATS:-no}"
PUID="${PUID:-99}"
PGID="${PGID:-100}"
TZ="${TZ:-Europe/Vienna}"

log_info "SERVER_NAME    = ${SERVER_NAME}"
log_info "POSTGRES_HOST  = ${POSTGRES_HOST}:${POSTGRES_PORT}"
log_info "POSTGRES_DB    = ${POSTGRES_DB}"
log_info "POSTGRES_USER  = ${POSTGRES_USER}"
log_info "REPORT_STATS   = ${REPORT_STATS}"
log_info "TZ             = ${TZ}"
log_info "PUID/PGID      = ${PUID}/${PGID}"

# Apply timezone if tzdata is installed
if [ -f "/usr/share/zoneinfo/${TZ}" ]; then
    ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime
    echo "${TZ}" > /etc/timezone
else
    log_warn "Timezone '${TZ}' not found in tzdata; using container default."
fi

# =============================================================================
# 2. Ensure /data is writable by PUID:PGID before any Synapse operations
# =============================================================================
log_info "Setting ownership of /data to ${PUID}:${PGID} ..."
chown -R "${PUID}:${PGID}" /data 2>/dev/null || true

# =============================================================================
# 3. First-boot: generate homeserver.yaml if it does not exist
# =============================================================================
HOMESERVER_YAML="/data/homeserver.yaml"

if [ ! -f "${HOMESERVER_YAML}" ]; then
    log_info "No homeserver.yaml found — running first-boot configuration."

    # The official Synapse image no longer supports --generate-config on its own
    # startup path. We drive it explicitly here via python -m.
    log_info "Generating initial homeserver.yaml via synapse --generate-config ..."
    gosu "${PUID}:${PGID}" python -m synapse.app.homeserver \
        --server-name "${SERVER_NAME}" \
        --config-path "${HOMESERVER_YAML}" \
        --generate-config \
        --report-stats="${REPORT_STATS}"

    log_info "homeserver.yaml generated successfully."

    # -------------------------------------------------------------------------
    # 3a. Patch listeners: bind to 0.0.0.0 and enable x_forwarded
    #     The generated file binds to ::1 (IPv6 loopback) by default, which
    #     makes the port unreachable from the host / reverse proxy.
    #     We use Python for this surgical YAML patch to avoid corrupting the file.
    # -------------------------------------------------------------------------
    log_info "Patching listener bind_addresses and x_forwarded in homeserver.yaml ..."
    python3 - <<'PYEOF'
import yaml, sys

cfg_path = "/data/homeserver.yaml"
with open(cfg_path, "r") as fh:
    cfg = yaml.safe_load(fh)

listeners = cfg.get("listeners", [])
for listener in listeners:
    # Patch the main client-server listener (port 8008)
    if listener.get("port") == 8008:
        listener["bind_addresses"] = ["0.0.0.0"]
        listener["x_forwarded"] = True
        # Ensure tls is off — TLS termination is handled by the reverse proxy
        listener["tls"] = False

cfg["listeners"] = listeners

with open(cfg_path, "w") as fh:
    yaml.dump(cfg, fh, default_flow_style=False, allow_unicode=True)

print("[init] Listener patch applied successfully.")
PYEOF

    # -------------------------------------------------------------------------
    # 3b. Generate a cryptographically random TURN secret (if not provided)
    # -------------------------------------------------------------------------
    if [ -z "${TURN_SECRET}" ]; then
        TURN_SECRET="$(openssl rand -hex 32)"
        log_info "Generated random TURN_SECRET."
    else
        log_info "Using provided TURN_SECRET."
    fi

    # Persist the TURN_SECRET into a file so it survives container restarts
    echo "${TURN_SECRET}" > /data/.turn_secret
    chown "${PUID}:${PGID}" /data/.turn_secret
    chmod 600 /data/.turn_secret

else
    log_info "homeserver.yaml already exists — skipping first-boot generation."

    # Load persisted TURN_SECRET for coturn template rendering below
    if [ -f "/data/.turn_secret" ]; then
        TURN_SECRET="$(cat /data/.turn_secret)"
    else
        # Fallback: generate and persist a new secret (edge case: data volume was
        # partially reset but homeserver.yaml was kept)
        TURN_SECRET="$(openssl rand -hex 32)"
        echo "${TURN_SECRET}" > /data/.turn_secret
        chown "${PUID}:${PGID}" /data/.turn_secret
        chmod 600 /data/.turn_secret
        log_warn "No persisted TURN secret found; generated a new one. Update homeserver.yaml TURN config if needed."
    fi
fi

# =============================================================================
# 4. Render homeserver-overrides.yaml from template and apply it
#    The overrides file is written to /data/ so Synapse can read it via
#    include_config_files. We append the include directive to homeserver.yaml
#    only once (idempotent).
# =============================================================================
OVERRIDES_TMPL="/defaults/homeserver-overrides.yaml.tmpl"
OVERRIDES_OUT="/data/homeserver-overrides.yaml"

# ENABLE_FEDERATION (default 'true'):
#   true  → federation_domain_whitelist: ~          (allow all = federate with everyone)
#   false → federation_domain_whitelist: []         (allow none = private island)
ENABLE_FEDERATION="${ENABLE_FEDERATION:-true}"
case "${ENABLE_FEDERATION}" in
    false|False|FALSE|0|no|No|NO)
        FEDERATION_WHITELIST="[]"
        log_info "Federation:    DISABLED (homeserver runs as a private island)"
        ;;
    *)
        FEDERATION_WHITELIST="~"
        log_info "Federation:    enabled"
        ;;
esac

log_info "Rendering homeserver-overrides.yaml from template ..."
export POSTGRES_HOST POSTGRES_PORT POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB SERVER_NAME TURN_SECRET FEDERATION_WHITELIST
envsubst < "${OVERRIDES_TMPL}" > "${OVERRIDES_OUT}"
chown "${PUID}:${PGID}" "${OVERRIDES_OUT}"

# Append include directive to homeserver.yaml if not already present
if ! grep -q "homeserver-overrides.yaml" "${HOMESERVER_YAML}"; then
    log_info "Adding include_config_files directive to homeserver.yaml ..."
    printf '\n# Injected by container init — do not remove\ninclude_config_files:\n  - /data/homeserver-overrides.yaml\n' \
        >> "${HOMESERVER_YAML}"
fi

# =============================================================================
# 5. Render turnserver.conf from template
# =============================================================================
TURN_TMPL="/defaults/turnserver.conf.tmpl"
TURN_OUT="/data/turnserver.conf"

log_info "Rendering turnserver.conf from template ..."
export SERVER_NAME TURN_SECRET
envsubst < "${TURN_TMPL}" > "${TURN_OUT}"
chmod 640 "${TURN_OUT}"

# =============================================================================
# 6. Render Element Web config.json (always — picks up SERVER_NAME changes)
# =============================================================================
ELEMENT_TMPL="/defaults/element-config.json.tmpl"
ELEMENT_OUT="/var/www/html/element/config.json"

log_info "Rendering Element Web config.json ..."
export SERVER_NAME
envsubst < "${ELEMENT_TMPL}" > "${ELEMENT_OUT}"

# =============================================================================
# 7. Ensure /data sub-directories exist with correct ownership
# =============================================================================
log_info "Ensuring /data sub-directories exist ..."
for dir in media_store uploads logs; do
    mkdir -p "/data/${dir}"
    chown "${PUID}:${PGID}" "/data/${dir}"
done

# =============================================================================
# 8. Optional: auto-create admin user on first boot
#    Set ADMIN_USER + ADMIN_PASSWORD in the Unraid template to have an admin
#    account created automatically. After Synapse is up, the synapse/run script
#    will pick up /data/.create_admin and register the user, then delete the
#    marker file. Idempotent: only runs if user does not already exist.
# =============================================================================
if [ -n "${ADMIN_USER}" ] && [ -n "${ADMIN_PASSWORD}" ]; then
    if [ ! -f "/data/.admin_created" ]; then
        log_info "ADMIN_USER='${ADMIN_USER}' set — will create admin user after Synapse starts."
        # Write marker file with credentials; consumed by post-start hook
        umask 077
        printf '%s\n%s\n' "${ADMIN_USER}" "${ADMIN_PASSWORD}" > /data/.create_admin
        chown "${PUID}:${PGID}" /data/.create_admin
    else
        log_info "Admin user already created on a previous boot — skipping."
    fi
fi

log_info "Container initialization complete. Starting services ..."
