#!/command/with-contenv sh
# shellcheck shell=sh
# Prepares /data on every start: validates the environment, generates
# homeserver.yaml on first boot and renders the Synapse overrides, the coturn
# config and Element Web's config.json from /defaults.
#
# The shebang needs with-contenv, or s6-overlay v3 runs this script with an empty
# environment. It is /command/with-contenv because the symlinks-noarch tarball
# that would add /usr/bin/with-contenv is not installed.
#
# No `set -e`: a failed optional step must not leave the later files unrendered,
# or services such as coturn wait for them forever. Fatal errors exit explicitly.

log_info()  { printf '\033[0;32m[init] INFO:  %s\033[0m\n'  "$*"; }
log_warn()  { printf '\033[0;33m[init] WARN:  %s\033[0m\n'  "$*"; }
log_error() { printf '\033[0;31m[init] ERROR: %s\033[0m\n'  "$*" >&2; }

MISSING=""

if [ -z "${SERVER_NAME}" ]; then
    MISSING="${MISSING} SERVER_NAME"
fi
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

POSTGRES_PORT="${POSTGRES_PORT:-5432}"
REPORT_STATS="${REPORT_STATS:-no}"
PUID="${PUID:-99}"
PGID="${PGID:-100}"
TZ="${TZ:-Europe/Vienna}"
TURN_DOMAIN="${TURN_DOMAIN:-$SERVER_NAME}"
TURN_PORT="${TURN_PORT:-3478}"
# TURN over TLS switches itself on when a certificate is mounted at /data/certs;
# TURN_TLS_ENABLE forces it either way. coturn's directives are cert and pkey,
# without a tls- prefix.
TURN_TLS_CERT="${TURN_TLS_CERT:-/data/certs/fullchain.pem}"
TURN_TLS_KEY="${TURN_TLS_KEY:-/data/certs/privkey.pem}"
TURN_TLS_PORT="${TURN_TLS_PORT:-5349}"
case "${TURN_TLS_ENABLE:-auto}" in
    false|False|FALSE|0|no|No|NO)  TURN_TLS_ON="false" ;;
    true|True|TRUE|1|yes|Yes|YES)  TURN_TLS_ON="true" ;;
    *) if [ -f "${TURN_TLS_CERT}" ] && [ -f "${TURN_TLS_KEY}" ]; then TURN_TLS_ON="true"; else TURN_TLS_ON="false"; fi ;;
esac
if [ "${TURN_TLS_ON}" = "true" ]; then
    if [ ! -f "${TURN_TLS_CERT}" ] || [ ! -f "${TURN_TLS_KEY}" ]; then
        log_warn "TURN over TLS requested but cert/key missing (${TURN_TLS_CERT}, ${TURN_TLS_KEY})"
        log_warn "coturn's TLS listener will fail until they are mounted (see the README 'TURN over TLS' section)."
    fi
    TURN_TLS_CONF="$(printf 'tls-listening-port=%s\ncert=%s\npkey=%s' "${TURN_TLS_PORT}" "${TURN_TLS_CERT}" "${TURN_TLS_KEY}")"
    log_info "TURN over TLS  = ENABLED (turns:${TURN_DOMAIN}:${TURN_TLS_PORT}, cert ${TURN_TLS_CERT})"
else
    TURN_TLS_CONF="$(printf 'no-tls\nno-dtls')"
    log_info "TURN over TLS  = off (mount fullchain.pem + privkey.pem at /data/certs to enable)"
fi
# ENABLE_REGISTRATION drives both Synapse (enable_registration) and Element's
# "Create Account" button (UIFeature.registration). Normalise to a literal
# true/false so it is valid in both YAML and JSON.
case "${ENABLE_REGISTRATION:-false}" in
    true|True|TRUE|1|yes|Yes|YES) ENABLE_REGISTRATION="true" ;;
    *)                            ENABLE_REGISTRATION="false" ;;
esac

log_info "SERVER_NAME    = ${SERVER_NAME}"
log_info "POSTGRES_HOST  = ${POSTGRES_HOST}:${POSTGRES_PORT}"
log_info "POSTGRES_DB    = ${POSTGRES_DB}"
log_info "POSTGRES_USER  = ${POSTGRES_USER}"
log_info "REPORT_STATS   = ${REPORT_STATS}"
log_info "TZ             = ${TZ}"
log_info "PUID/PGID      = ${PUID}/${PGID}"
log_info "REGISTRATION   = ${ENABLE_REGISTRATION}"
log_info "TURN_ENDPOINT  = ${TURN_DOMAIN}:${TURN_PORT}"

if [ -f "/usr/share/zoneinfo/${TZ}" ]; then
    ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime
    echo "${TZ}" > /etc/timezone
else
    log_warn "Timezone '${TZ}' not found in tzdata; using container default."
fi

log_info "Setting ownership of /data to ${PUID}:${PGID} ..."
chown -R "${PUID}:${PGID}" /data 2>/dev/null || true

HOMESERVER_YAML="/data/homeserver.yaml"

if [ ! -f "${HOMESERVER_YAML}" ]; then
    log_info "No homeserver.yaml found, running first-boot configuration."

    # The official image's start script does not handle --generate-config, so the
    # module is called directly.
    log_info "Generating initial homeserver.yaml via synapse --generate-config ..."
    # Relative paths in the generated config resolve against the working
    # directory, which would otherwise be the s6 service directory, and
    # --data-directory makes generate-config write absolute /data paths.
    cd /data || exit 1
    if ! gosu "${PUID}:${PGID}" python -m synapse.app.homeserver \
        --server-name "${SERVER_NAME}" \
        --config-path "${HOMESERVER_YAML}" \
        --data-directory /data \
        --generate-config \
        --report-stats="${REPORT_STATS}"; then
        log_error "synapse --generate-config failed: homeserver.yaml was not created."
        log_error "Halting container start so the broken state is visible. Check the error above"
        log_error "(SERVER_NAME, /data permissions), fix it and restart the container."
        exit 1
    fi

    log_info "homeserver.yaml generated successfully."

    if [ -z "${TURN_SECRET}" ]; then
        TURN_SECRET="$(openssl rand -hex 32)"
        log_info "Generated random TURN_SECRET."
    else
        log_info "Using provided TURN_SECRET."
    fi

    echo "${TURN_SECRET}" > /data/.turn_secret
    chown "${PUID}:${PGID}" /data/.turn_secret
    chmod 600 /data/.turn_secret

else
    log_info "homeserver.yaml already exists, skipping first-boot generation."

    if [ -f "/data/.turn_secret" ]; then
        TURN_SECRET="$(cat /data/.turn_secret)"
    else
        # /data was partly reset but homeserver.yaml kept.
        TURN_SECRET="$(openssl rand -hex 32)"
        echo "${TURN_SECRET}" > /data/.turn_secret
        chown "${PUID}:${PGID}" /data/.turn_secret
        chmod 600 /data/.turn_secret
        log_warn "No persisted TURN secret found; generated a new one. Update homeserver.yaml TURN config if needed."
    fi
fi

# On every boot the 8008 listener is set up for the reverse proxy in front, and
# relative paths are made absolute under /data, because the working directory of
# the services is the read-only s6 service directory.
log_info "Ensuring homeserver.yaml + log.config use absolute paths ..."
python3 - <<'PYEOF'
import os, yaml, glob

cfg_path = "/data/homeserver.yaml"
with open(cfg_path, "r") as fh:
    cfg = yaml.safe_load(fh) or {}

changed = False

for listener in cfg.get("listeners", []):
    if listener.get("port") == 8008:
        if listener.get("bind_addresses") != ["0.0.0.0"]:
            listener["bind_addresses"] = ["0.0.0.0"]; changed = True
        if not listener.get("x_forwarded"):
            listener["x_forwarded"] = True; changed = True
        if listener.get("tls"):
            listener["tls"] = False; changed = True

if cfg.get("media_store_path") != "/data/media_store":
    cfg["media_store_path"] = "/data/media_store"; changed = True
if cfg.get("uploads_path") != "/data/uploads":
    cfg["uploads_path"] = "/data/uploads"; changed = True

for key in ("signing_key_path", "log_config"):
    val = cfg.get(key)
    if isinstance(val, str) and val and not val.startswith("/"):
        cfg[key] = os.path.join("/data", val); changed = True

if changed:
    with open(cfg_path, "w") as fh:
        yaml.dump(cfg, fh, default_flow_style=False, allow_unicode=True)
    print("[init] homeserver.yaml patched.")
else:
    print("[init] homeserver.yaml already correct.")

# The generated <SERVER_NAME>.log.config has a rolling file handler with a relative
# filename, which fails in the read-only s6 service directory. Every log config is
# replaced with a console-only one, so the logs end up in `docker logs`.
os.makedirs("/data/logs", exist_ok=True)
clean_log_cfg = {
    "version": 1,
    "formatters": {
        "precise": {
            "format": "%(asctime)s - %(name)s - %(lineno)d - %(levelname)s - %(request)s - %(message)s"
        }
    },
    "filters": {
        "context": {"()": "synapse.logging.context.LoggingContextFilter", "request": ""}
    },
    "handlers": {
        "console": {
            "class": "logging.StreamHandler",
            "formatter": "precise",
            "filters": ["context"],
        }
    },
    "loggers": {
        "synapse.storage.SQL": {"level": "INFO"},
        "twisted": {"handlers": ["console"], "propagate": False, "level": "INFO"},
    },
    "root": {"level": "INFO", "handlers": ["console"]},
    "disable_existing_loggers": False,
}

canonical = "/data/log.config"
with open(canonical, "w") as fh:
    yaml.dump(clean_log_cfg, fh, default_flow_style=False)
print(f"[init] wrote canonical clean log config to {canonical}.")

for old_lc in glob.glob("/data/*.log.config"):
    with open(old_lc, "w") as fh:
        yaml.dump(clean_log_cfg, fh, default_flow_style=False)
    print(f"[init] overwrote stale {old_lc} with clean console-only config.")

with open(cfg_path) as fh:
    cfg2 = yaml.safe_load(fh) or {}
if cfg2.get("log_config") != canonical:
    cfg2["log_config"] = canonical
    with open(cfg_path, "w") as fh:
        yaml.dump(cfg2, fh, default_flow_style=False, allow_unicode=True)
    print(f"[init] homeserver.yaml log_config repointed to {canonical}.")
PYEOF
chown -R "${PUID}:${PGID}" "${HOMESERVER_YAML}" /data/log.config /data/logs 2>/dev/null || true

# Synapse reads the overrides through a second --config-path in
# services.d/synapse/run. homeserver.yaml cannot include them: Synapse has no
# include directive (synapse/config/_base.py honours only -c arguments and config
# directories).
OVERRIDES_TMPL="/defaults/homeserver-overrides.yaml.tmpl"
OVERRIDES_OUT="/data/homeserver-overrides.yaml"

# An empty whitelist makes a private server; ~ federates with everyone.
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
export POSTGRES_HOST POSTGRES_PORT POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB SERVER_NAME TURN_SECRET FEDERATION_WHITELIST TURN_DOMAIN TURN_PORT ENABLE_REGISTRATION
envsubst < "${OVERRIDES_TMPL}" > "${OVERRIDES_OUT}"

# The turns: URIs are inserted after rendering so the template stays valid YAML
# for the CI template linter.
if [ "${TURN_TLS_ON}" = "true" ]; then
    TURNS_TMP="$(mktemp)"
    printf '  - "turns:%s:%s?transport=tcp"\n  - "turns:%s:%s?transport=udp"\n' \
        "${TURN_DOMAIN}" "${TURN_TLS_PORT}" "${TURN_DOMAIN}" "${TURN_TLS_PORT}" > "${TURNS_TMP}"
    sed -i "/^turn_uris:\$/r ${TURNS_TMP}" "${OVERRIDES_OUT}"
    rm -f "${TURNS_TMP}"
fi

chown "${PUID}:${PGID}" "${OVERRIDES_OUT}"
# Holds POSTGRES_PASSWORD and TURN_SECRET.
chmod 600 "${OVERRIDES_OUT}"

# Installs from before the second --config-path carry an include_config_files
# block in homeserver.yaml that Synapse never honoured, so they ran on SQLite with
# every override ignored. The block is stripped so the file shows what Synapse
# reads; the file check keeps this from creating a stub homeserver.yaml.
if [ -f "${HOMESERVER_YAML}" ] && grep -q "^include_config_files:" "${HOMESERVER_YAML}"; then
    log_warn "Stripping legacy include_config_files block from homeserver.yaml (never honored by Synapse)"
    sed -i \
        -e '/^# Injected by container init — do not remove$/d' \
        -e '/^include_config_files:$/,/^  - \/data\/homeserver-overrides\.yaml$/d' \
        "${HOMESERVER_YAML}"
fi

# A homeserver.db from such an install is orphaned, since the overrides select Postgres.
if [ -f "/data/homeserver.db" ]; then
    log_warn "Found /data/homeserver.db: earlier builds misloaded config, so Synapse may have"
    log_warn "been writing to SQLite. With the overrides now active, Synapse will use Postgres."
    log_warn "To keep the SQLite data, stop the container and run synapse_port_db first."
    log_warn "See: https://element-hq.github.io/synapse/latest/postgres.html#porting-from-sqlite"
fi

TURN_TMPL="/defaults/turnserver.conf.tmpl"
TURN_OUT="/data/turnserver.conf"

log_info "Rendering turnserver.conf from template ..."
export SERVER_NAME TURN_SECRET TURN_TLS_CONF
envsubst < "${TURN_TMPL}" > "${TURN_OUT}"
chmod 640 "${TURN_OUT}"

ELEMENT_TMPL="/defaults/element-config.json.tmpl"
ELEMENT_OUT="/var/www/html/element/config.json"

# ELEMENT_EXTRA_FEATURES is an optional JSON object for Element Web's "features"
# block, e.g. '{"feature_html_topic": true}'. Malformed JSON would keep Element
# Web from loading at all, so a bad value is dropped with a warning.
if [ -z "${ELEMENT_EXTRA_FEATURES}" ]; then
    ELEMENT_EXTRA_FEATURES='{}'
fi
if ! printf '%s' "${ELEMENT_EXTRA_FEATURES}" | python3 -c "
import json, sys
obj = json.load(sys.stdin)
if not isinstance(obj, dict):
    sys.exit(1)
" >/dev/null 2>&1; then
    log_warn "ELEMENT_EXTRA_FEATURES is not a valid JSON object, ignoring it: ${ELEMENT_EXTRA_FEATURES}"
    ELEMENT_EXTRA_FEATURES='{}'
fi

log_info "Rendering Element Web config.json ..."
export SERVER_NAME ENABLE_REGISTRATION ELEMENT_EXTRA_FEATURES
envsubst < "${ELEMENT_TMPL}" > "${ELEMENT_OUT}"

# envsubst is blind text substitution, so the rendered file is checked as well.
if ! python3 -c "import json; json.load(open('${ELEMENT_OUT}'))" >/dev/null 2>&1; then
    log_error "Rendered Element Web config.json is not valid JSON, check ELEMENT_EXTRA_FEATURES."
    log_error "Element Web will fail to load until this is fixed and the container is restarted."
fi

log_info "Ensuring /data sub-directories exist ..."
for dir in media_store uploads logs; do
    mkdir -p "/data/${dir}"
    chown "${PUID}:${PGID}" "/data/${dir}"
done

if [ -n "${ADMIN_USER}" ] && [ -n "${ADMIN_PASSWORD}" ]; then
    # The admin-bootstrap service registers the user or promotes an existing one
    # to server admin, then deletes this file. It is not gated on
    # /data/.admin_created, so an account that existed before ADMIN_USER was set
    # (self-registered in Element, say) still gets the server-admin flag the admin
    # UI requires. Clearing ADMIN_USER and ADMIN_PASSWORD afterwards stops it
    # running on every restart.
    log_info "ADMIN_USER='${ADMIN_USER}' set, admin user will be created/promoted after Synapse starts."
    umask 077
    printf '%s\n%s\n' "${ADMIN_USER}" "${ADMIN_PASSWORD}" > /data/.create_admin
    chown "${PUID}:${PGID}" /data/.create_admin
fi

log_info "Container initialization complete. Starting services ..."
