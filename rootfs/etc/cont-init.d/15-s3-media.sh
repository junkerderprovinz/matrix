#!/command/with-contenv sh
# shellcheck shell=sh
# =============================================================================
# 15-s3-media.sh — Optional S3-compatible media storage provider
#
# Runs after 10-config.sh (lexicographic order), because it PATCHES the
# homeserver-overrides.yaml that 10-config.sh renders from scratch on every
# boot. Numbered below 20-mas.sh: this feature is independent of delegated
# auth, touches a disjoint set of YAML keys, and has no migration step, so
# there is no ordering requirement against MAS — 15 just keeps "patches to the
# base render" grouped together and ahead of MAS's own append.
#
# The shebang MUST be with-contenv, exactly as in 10-config.sh: without it
# s6-overlay v3 hands this script an empty environment and S3_MEDIA_ENABLED
# would read as unset — which, for a feature switch, would silently mean
# "off" forever.
#
# ------------------------------------------------------------------ opt-in ---
# THE CONTRACT: with S3_MEDIA_ENABLED off, this script must leave the
# container in exactly the state it would be in if this feature did not
# exist. No config written, not a single byte changed in the rendered Synapse
# config. Existing homeservers pull new images unattended; this mirrors
# 20-mas.sh's own opt-in contract exactly.
# =============================================================================

log_info()  { printf '\033[0;32m[s3-media] INFO:  %s\033[0m\n'  "$*"; }
log_warn()  { printf '\033[0;33m[s3-media] WARN:  %s\033[0m\n'  "$*"; }
log_error() { printf '\033[0;31m[s3-media] ERROR: %s\033[0m\n'  "$*" >&2; }

OVERRIDES_OUT=/data/homeserver-overrides.yaml

# =============================================================================
# 1. The switch
#
# Always ':-' and never '-', same reasoning as AUTH_ENABLED in 20-mas.sh: a
# blank Unraid template field arrives as `-e S3_MEDIA_ENABLED=`, i.e. SET but
# EMPTY, and only ':-' falls back to false in that case.
# =============================================================================
case "$(printf '%s' "${S3_MEDIA_ENABLED:-false}" | tr '[:upper:]' '[:lower:]')" in
    true|1|yes|on) S3_MEDIA_ENABLED=true ;;
    *)             S3_MEDIA_ENABLED=false ;;
esac

if [ "${S3_MEDIA_ENABLED}" != "true" ]; then
    log_info "S3 media storage = disabled (set S3_MEDIA_ENABLED=true to offload media to an S3-compatible bucket)"
    exit 0
fi

log_info "S3 media storage = ENABLED"

# =============================================================================
# 2. Preconditions — checked before anything is written
# =============================================================================
FATAL=0

if [ -z "${S3_MEDIA_BUCKET}" ]; then
    log_error "S3_MEDIA_BUCKET is not set. Create the bucket on your S3-compatible backend first."
    FATAL=1
fi
if [ -z "${S3_MEDIA_ENDPOINT}" ]; then
    log_error "S3_MEDIA_ENDPOINT is not set, e.g. http://192.168.20.73:8333 for SeaweedFS."
    log_error "This feature targets a self-hosted S3-compatible backend, so there is no default endpoint."
    FATAL=1
fi
if [ -z "${S3_MEDIA_ACCESS_KEY_ID}" ] || [ -z "${S3_MEDIA_SECRET_ACCESS_KEY}" ]; then
    log_error "S3_MEDIA_ACCESS_KEY_ID and S3_MEDIA_SECRET_ACCESS_KEY are both required."
    FATAL=1
fi

if [ "${FATAL}" -ne 0 ]; then
    log_error "Refusing to start with an incomplete S3 media configuration. Fix the above, or set"
    log_error "S3_MEDIA_ENABLED=false to run without it exactly as before."
    exit 1
fi

S3_MEDIA_REGION="${S3_MEDIA_REGION:-us-east-1}"
S3_MEDIA_STORAGE_CLASS="${S3_MEDIA_STORAGE_CLASS:-STANDARD}"

log_info "S3_MEDIA_BUCKET   = ${S3_MEDIA_BUCKET}"
log_info "S3_MEDIA_ENDPOINT = ${S3_MEDIA_ENDPOINT}"
log_info "S3_MEDIA_REGION   = ${S3_MEDIA_REGION}"

# =============================================================================
# 3. Patch the Synapse overrides
#
# 10-config.sh has already rendered the file fresh; we only append here (no
# strip needed, unlike 20-mas.sh — this feature does not touch any key the
# base template already sets).
# =============================================================================
if [ ! -f "${OVERRIDES_OUT}" ]; then
    log_error "${OVERRIDES_OUT} does not exist — 10-config.sh must run before this script."
    exit 1
fi

log_info "Appending S3 media storage configuration to homeserver-overrides.yaml ..."
export S3_MEDIA_BUCKET S3_MEDIA_REGION S3_MEDIA_ENDPOINT S3_MEDIA_ACCESS_KEY_ID \
       S3_MEDIA_SECRET_ACCESS_KEY S3_MEDIA_STORAGE_CLASS
{
    printf '\n'
    envsubst < /defaults/s3-media-overrides.yaml.tmpl
} >> "${OVERRIDES_OUT}"

# =============================================================================
# 4. Prove the merged config still parses
#
# Same cheap insurance as 20-mas.sh: a broken override file otherwise shows up
# as a Synapse crash loop several seconds later, one abstraction layer away.
# =============================================================================
if ! python3 -c "import sys, yaml; yaml.safe_load(open('${OVERRIDES_OUT}'))" 2>/dev/null; then
    log_error "homeserver-overrides.yaml is not valid YAML after the S3 media patch."
    log_error "Refusing to start; this would be a Synapse crash loop otherwise."
    exit 1
fi

PUID="${PUID:-99}"
PGID="${PGID:-100}"
chown "${PUID}:${PGID}" "${OVERRIDES_OUT}"
# Contains S3_MEDIA_SECRET_ACCESS_KEY, same treatment as homeserver-overrides.yaml.
chmod 600 "${OVERRIDES_OUT}"

log_info "S3 media storage configuration complete."
log_info "New uploads are copied to the bucket; existing local media is not migrated retroactively."
