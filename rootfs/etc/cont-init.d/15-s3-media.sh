#!/command/with-contenv sh
# shellcheck shell=sh
# Optional S3-compatible media storage. Runs after 10-config.sh because it
# appends to the homeserver-overrides.yaml rendered there; it touches none of the
# keys MAS changes, so running before 20-mas.sh only groups it with the base render.
#
# The shebang needs with-contenv as in 10-config.sh. Without it S3_MEDIA_ENABLED
# would read as unset, and the feature would stay off without a word.
#
# With S3_MEDIA_ENABLED off the script writes nothing and the rendered Synapse
# config is unchanged, the same opt-in contract as 20-mas.sh, since existing
# homeservers pull new images unattended.

log_info()  { printf '\033[0;32m[s3-media] INFO:  %s\033[0m\n'  "$*"; }
log_warn()  { printf '\033[0;33m[s3-media] WARN:  %s\033[0m\n'  "$*"; }
log_error() { printf '\033[0;31m[s3-media] ERROR: %s\033[0m\n'  "$*" >&2; }

OVERRIDES_OUT=/data/homeserver-overrides.yaml

# ':-' rather than '-': a blank template field arrives as S3_MEDIA_ENABLED= (set
# but empty), and only ':-' falls back to false then.
case "$(printf '%s' "${S3_MEDIA_ENABLED:-false}" | tr '[:upper:]' '[:lower:]')" in
    true|1|yes|on) S3_MEDIA_ENABLED=true ;;
    *)             S3_MEDIA_ENABLED=false ;;
esac

if [ "${S3_MEDIA_ENABLED}" != "true" ]; then
    log_info "S3 media storage = disabled (set S3_MEDIA_ENABLED=true to offload media to an S3-compatible bucket)"
    exit 0
fi

log_info "S3 media storage = ENABLED"

# Checked before anything is written.
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

# Append only: unlike MAS, this feature sets no key the base template has.
if [ ! -f "${OVERRIDES_OUT}" ]; then
    log_error "${OVERRIDES_OUT} does not exist; 10-config.sh must run before this script."
    exit 1
fi

log_info "Appending S3 media storage configuration to homeserver-overrides.yaml ..."
export S3_MEDIA_BUCKET S3_MEDIA_REGION S3_MEDIA_ENDPOINT S3_MEDIA_ACCESS_KEY_ID \
       S3_MEDIA_SECRET_ACCESS_KEY S3_MEDIA_STORAGE_CLASS
{
    printf '\n'
    envsubst < /defaults/s3-media-overrides.yaml.tmpl
} >> "${OVERRIDES_OUT}"

# A broken override file would otherwise surface later as a Synapse crash loop.
if ! python3 -c "import sys, yaml; yaml.safe_load(open('${OVERRIDES_OUT}'))" 2>/dev/null; then
    log_error "homeserver-overrides.yaml is not valid YAML after the S3 media patch."
    log_error "Refusing to start; this would be a Synapse crash loop otherwise."
    exit 1
fi

PUID="${PUID:-99}"
PGID="${PGID:-100}"
chown "${PUID}:${PGID}" "${OVERRIDES_OUT}"
# The file holds S3_MEDIA_SECRET_ACCESS_KEY as well.
chmod 600 "${OVERRIDES_OUT}"

log_info "S3 media storage configuration complete."
log_info "New uploads are copied to the bucket; existing local media is not migrated retroactively."
