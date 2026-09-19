#!/command/with-contenv sh
# shellcheck shell=sh
# Matrix Authentication Service (MAS) setup. Runs after 10-config.sh because it
# patches the homeserver-overrides.yaml rendered there on every boot.
#
# The shebang needs with-contenv as in 10-config.sh. Without it every AUTH_*
# variable would read as unset, and the feature would stay off without a word.
#
# With AUTH_ENABLED off the script writes no config, starts nothing and leaves the
# rendered Synapse config unchanged: existing homeservers pull new images
# unattended, and a routine update must not rearrange their auth.
#
# Where it exits 1, Synapse would otherwise refuse to boot a few seconds later
# with a far less obvious message, or carrying on would corrupt data.

log_info()  { printf '\033[0;32m[mas]  INFO:  %s\033[0m\n'  "$*"; }
log_warn()  { printf '\033[0;33m[mas]  WARN:  %s\033[0m\n'  "$*"; }
log_error() { printf '\033[0;31m[mas]  ERROR: %s\033[0m\n'  "$*" >&2; }

MAS_DIR=/data/mas
OVERRIDES_OUT=/data/homeserver-overrides.yaml

# ':-' rather than '-': a blank Unraid template field arrives as AUTH_ENABLED=
# (set but empty), and only ':-' falls back to false then.
case "$(printf '%s' "${AUTH_ENABLED:-false}" | tr '[:upper:]' '[:lower:]')" in
    true|1|yes|on) AUTH_ENABLED=true ;;
    *)             AUTH_ENABLED=false ;;
esac

if [ "${AUTH_ENABLED}" != "true" ]; then
    # After a migration to MAS, switching it off leaves accounts, passwords and
    # sessions in the MAS database, and nobody can log in.
    if [ -f "${MAS_DIR}/config.yaml" ]; then
        log_warn "AUTH_ENABLED is off, but ${MAS_DIR}/config.yaml exists from an earlier run."
        log_warn "Synapse is starting without delegated auth. If you already migrated accounts"
        log_warn "with syn2mas, they live in the MAS database and logins will fail until you"
        log_warn "set AUTH_ENABLED=true again or restore your pre-migration backup."
    fi
    log_info "Matrix Authentication Service = disabled (set AUTH_ENABLED=true to enable QR code login)"
    exit 0
fi

log_info "Matrix Authentication Service = ENABLED"

# Preconditions are checked before anything is written, so a misconfigured
# container stops cleanly instead of half-initialised.
FATAL=0

# Element Web registers itself with MAS as a dynamic client, and MAS rejects plain
# http client and redirect URIs ("invalid_redirect_uri: invalid client_uri;
# invalid redirect_uri"). The browser shows only a generic sign-in error, so the
# check happens here where the log can explain it.
if [ -z "${AUTH_PUBLIC_BASE}" ]; then
    log_error "AUTH_PUBLIC_BASE is not set."
    log_error "It is the public URL of the auth service, e.g. https://auth.example.com/"
    log_error "It needs its own reverse-proxy host pointing at this container's port 8090."
    FATAL=1
else
    case "${AUTH_PUBLIC_BASE}" in
        https://*) : ;;
        *)
            log_error "AUTH_PUBLIC_BASE must start with https:// (got: ${AUTH_PUBLIC_BASE})"
            log_error "MAS refuses plain-http client and redirect URIs, so Element's sign-in"
            log_error "would fail with an unhelpful error. Put a certificate in front of it."
            FATAL=1
            ;;
    esac
    # MAS treats the public base as a URL prefix; a missing trailing slash makes
    # it build https://auth.example.compath style URLs.
    case "${AUTH_PUBLIC_BASE}" in
        */) : ;;
        *)  AUTH_PUBLIC_BASE="${AUTH_PUBLIC_BASE}/"
            log_info "Appended missing trailing slash: AUTH_PUBLIC_BASE=${AUTH_PUBLIC_BASE}" ;;
    esac
fi

# Connection details default to Synapse's, since one Postgres server is the common
# case. The database name has no default: MAS needs its own, and a guessed name
# could be Synapse's.
AUTH_POSTGRES_HOST="${AUTH_POSTGRES_HOST:-${POSTGRES_HOST}}"
AUTH_POSTGRES_PORT="${AUTH_POSTGRES_PORT:-${POSTGRES_PORT:-5432}}"
AUTH_POSTGRES_USER="${AUTH_POSTGRES_USER:-${POSTGRES_USER}}"
AUTH_POSTGRES_PASSWORD="${AUTH_POSTGRES_PASSWORD:-${POSTGRES_PASSWORD}}"

if [ -z "${AUTH_POSTGRES_DB}" ]; then
    log_error "AUTH_POSTGRES_DB is not set."
    log_error "MAS needs its own empty PostgreSQL database; it cannot share Synapse's."
    log_error "Create one first, e.g.:"
    log_error "  CREATE DATABASE mas TEMPLATE template0 ENCODING 'UTF8' LC_COLLATE 'C' LC_CTYPE 'C';"
    FATAL=1
elif [ "${AUTH_POSTGRES_DB}" = "${POSTGRES_DB}" ] \
     && [ "${AUTH_POSTGRES_HOST}" = "${POSTGRES_HOST}" ]; then
    # MAS would run its own migrations inside Synapse's schema.
    log_error "AUTH_POSTGRES_DB is the same database as POSTGRES_DB ('${POSTGRES_DB}')."
    log_error "MAS would create its tables inside Synapse's schema. Refusing to start."
    FATAL=1
fi

# Synapse refuses to start with registration and delegated auth together
# ("Registration cannot be enabled when OAuth delegation is enabled"). The keys
# are stripped below, but the user asked for registration, so say so.
if [ "${ENABLE_REGISTRATION:-false}" = "true" ]; then
    log_warn "ENABLE_REGISTRATION=true cannot be combined with delegated auth: Synapse"
    log_warn "refuses to start in that combination. Ignoring it for Synapse and handing"
    log_warn "registration to MAS instead (see AUTH_ALLOW_REGISTRATION)."
fi

if [ "${FATAL}" -ne 0 ]; then
    log_error "Refusing to start with an incomplete MAS configuration. Fix the above, or set"
    log_error "AUTH_ENABLED=false to run without delegated auth exactly as before."
    exit 1
fi

case "$(printf '%s' "${AUTH_QR_LOGIN:-true}" | tr '[:upper:]' '[:lower:]')" in
    false|0|no|off) AUTH_QR_LOGIN=false ;;
    *)              AUTH_QR_LOGIN=true ;;
esac
case "$(printf '%s' "${AUTH_ALLOW_REGISTRATION:-false}" | tr '[:upper:]' '[:lower:]')" in
    true|1|yes|on) AUTH_ALLOW_REGISTRATION=true ;;
    *)             AUTH_ALLOW_REGISTRATION=false ;;
esac

PUID="${PUID:-99}"
PGID="${PGID:-100}"

log_info "AUTH_PUBLIC_BASE   = ${AUTH_PUBLIC_BASE}"
log_info "AUTH_POSTGRES_DB   = ${AUTH_POSTGRES_DB} (on ${AUTH_POSTGRES_HOST}:${AUTH_POSTGRES_PORT})"
log_info "QR code login      = ${AUTH_QR_LOGIN}"
log_info "MAS registration   = ${AUTH_ALLOW_REGISTRATION}"

# The secrets are generated once and then only read: a new encryption secret makes
# every encrypted value in the MAS database unreadable, and a new signing key
# invalidates every issued token.
mkdir -p "${MAS_DIR}/keys"

if [ ! -s "${MAS_DIR}/encryption.secret" ]; then
    openssl rand -hex 32 | tr -d '\n' > "${MAS_DIR}/encryption.secret"
    log_info "Generated MAS encryption secret."
fi
if [ ! -s "${MAS_DIR}/matrix.secret" ]; then
    openssl rand -hex 32 | tr -d '\n' > "${MAS_DIR}/matrix.secret"
    log_info "Generated MAS <-> Synapse shared secret."
fi
if [ ! -s "${MAS_DIR}/keys/rsa.key" ]; then
    if ! openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
            -out "${MAS_DIR}/keys/rsa.key" 2>/dev/null; then
        log_error "Failed to generate the MAS signing key."
        exit 1
    fi
    log_info "Generated MAS signing key (kid: primary)."
fi

chmod 700 "${MAS_DIR}/keys"
chmod 600 "${MAS_DIR}/encryption.secret" "${MAS_DIR}/matrix.secret" "${MAS_DIR}/keys/rsa.key"
chown -R "${PUID}:${PGID}" "${MAS_DIR}"

log_info "Rendering ${MAS_DIR}/config.yaml from template ..."
export AUTH_PUBLIC_BASE AUTH_POSTGRES_HOST AUTH_POSTGRES_PORT AUTH_POSTGRES_USER \
       AUTH_POSTGRES_PASSWORD AUTH_POSTGRES_DB AUTH_ALLOW_REGISTRATION SERVER_NAME
envsubst < /defaults/mas-config.yaml.tmpl > "${MAS_DIR}/config.yaml"
chown "${PUID}:${PGID}" "${MAS_DIR}/config.yaml"
# Holds AUTH_POSTGRES_PASSWORD.
chmod 600 "${MAS_DIR}/config.yaml"

if [ ! -f "${OVERRIDES_OUT}" ]; then
    log_error "${OVERRIDES_OUT} does not exist; 10-config.sh must run before this script."
    exit 1
fi

# enable_registration and enable_registration_without_verification are a
# ConfigError under delegated auth, and the base template's
# `experimental_features: {}` would duplicate the key the MAS block adds.
sed -i \
    -e '/^enable_registration:/d' \
    -e '/^enable_registration_without_verification:/d' \
    -e '/^experimental_features: {}$/d' \
    "${OVERRIDES_OUT}"

log_info "Appending delegated-auth configuration to homeserver-overrides.yaml ..."
export AUTH_QR_LOGIN
{
    printf '\n'
    envsubst < /defaults/mas-overrides.yaml.tmpl
} >> "${OVERRIDES_OUT}"

# A broken override file would otherwise surface later as a Synapse crash loop.
if ! python3 -c "import sys, yaml; yaml.safe_load(open('${OVERRIDES_OUT}'))" 2>/dev/null; then
    log_error "homeserver-overrides.yaml is not valid YAML after the MAS patch."
    log_error "Refusing to start; this would be a Synapse crash loop otherwise."
    exit 1
fi
if ! python3 -c "import sys, yaml; yaml.safe_load(open('${MAS_DIR}/config.yaml'))" 2>/dev/null; then
    log_error "${MAS_DIR}/config.yaml is not valid YAML."
    exit 1
fi

chown "${PUID}:${PGID}" "${OVERRIDES_OUT}"
chmod 600 "${OVERRIDES_OUT}"

log_info "MAS configuration complete."
log_info "Reverse proxy reminder: /_matrix/client/*/{login,logout,refresh} must go to"
log_info "this container's port 8090, everything else (including /_synapse/mas) to 8008."
log_info "Existing accounts stay in Synapse until you run 'mas-cli syn2mas migrate'."
