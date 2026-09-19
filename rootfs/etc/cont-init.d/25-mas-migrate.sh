#!/command/with-contenv sh
# shellcheck shell=sh
# One-shot syn2mas migration of existing Synapse accounts. It runs in
# cont-init.d, after 20-mas.sh, because Synapse has to be offline during
# `syn2mas migrate`: s6 starts the synapse service only once every cont-init
# script has returned, so the migration cannot race a running homeserver.
#
# It is the one irreversible step of the feature; once anybody has signed in to
# MAS, only a database restore undoes it. So:
#
#   * It runs only when AUTH_MIGRATE is true.
#   * It runs once: a marker file is written on success and checked first, so
#     leaving AUTH_MIGRATE=true set is harmless.
#   * `check` runs first and any error stops it. A `--dry-run` follows, which
#     upstream rolls back to an empty MAS database, so it catches the problems
#     the real run would hit at no cost.
#   * Any failure exits non-zero and stops the container (see
#     S6_BEHAVIOUR_IF_STAGE2_FAILS in the Dockerfile) instead of starting a
#     homeserver whose accounts are half migrated.
#
# syn2mas never writes to the Synapse database, so a failure before the MAS
# database is populated leaves the original untouched.

log_info()  { printf '\033[0;32m[migrate] INFO:  %s\033[0m\n'  "$*"; }
log_warn()  { printf '\033[0;33m[migrate] WARN:  %s\033[0m\n'  "$*"; }
log_error() { printf '\033[0;31m[migrate] ERROR: %s\033[0m\n'  "$*" >&2; }

MAS_DIR=/data/mas
MARKER="${MAS_DIR}/.migrated"

# Both config files, in the order the synapse service loads them: the database
# connection is in the overrides, and homeserver.yaml alone would point syn2mas
# at the generated SQLite defaults.
SYN_ARGS="--synapse-config /data/homeserver.yaml --synapse-config /data/homeserver-overrides.yaml"

case "$(printf '%s' "${AUTH_MIGRATE:-false}" | tr '[:upper:]' '[:lower:]')" in
    true|1|yes|on) : ;;
    *) exit 0 ;;
esac

case "$(printf '%s' "${AUTH_ENABLED:-false}" | tr '[:upper:]' '[:lower:]')" in
    true|1|yes|on) : ;;
    *)
        log_error "AUTH_MIGRATE is set but AUTH_ENABLED is not."
        log_error "Migrating accounts into an auth service that will not be running would lock"
        log_error "everyone out. Enable delegated auth first, or clear AUTH_MIGRATE."
        exit 1
        ;;
esac

if [ -f "${MARKER}" ]; then
    log_info "Accounts were already migrated on $(cat "${MARKER}" 2>/dev/null). Nothing to do."
    log_info "You can clear AUTH_MIGRATE from the template; leaving it set is harmless."
    exit 0
fi

if [ ! -s "${MAS_DIR}/config.yaml" ]; then
    log_error "${MAS_DIR}/config.yaml is missing; 20-mas.sh did not complete."
    exit 1
fi

# Exit code 10 means the setup is not migratable; 11 means warnings only.
log_info "Checking whether this deployment can be migrated ..."
mas-cli syn2mas check --config "${MAS_DIR}/config.yaml" ${SYN_ARGS}
rc=$?
case "${rc}" in
    0)  log_info "Check passed." ;;
    11) log_warn "Check passed with warnings (see above). Continuing." ;;
    *)
        log_error "syn2mas check failed (exit ${rc}). Nothing has been migrated."
        log_error "Fix what it reported above, then restart. Your Synapse database is untouched:"
        log_error "syn2mas only ever reads from it."
        exit 1
        ;;
esac

# The dry run writes to the MAS database and then empties it again.
log_info "Performing a dry run ..."
if ! mas-cli syn2mas migrate --dry-run --config "${MAS_DIR}/config.yaml" ${SYN_ARGS}; then
    log_error "The dry run failed. Nothing has been migrated and both databases are intact."
    exit 1
fi
log_info "Dry run succeeded."

log_warn "Migrating accounts for real now. Synapse is not running yet, which is exactly"
log_warn "the offline window this needs. Do not interrupt the container."
if ! mas-cli syn2mas migrate --config "${MAS_DIR}/config.yaml" ${SYN_ARGS}; then
    log_error "Migration failed partway through."
    log_error "Your Synapse database was not written to. The MAS database may be partly"
    log_error "populated: drop and recreate it before trying again, e.g."
    log_error "  DROP DATABASE ${AUTH_POSTGRES_DB:-mas}; CREATE DATABASE ${AUTH_POSTGRES_DB:-mas} TEMPLATE template0 ENCODING 'UTF8' LC_COLLATE 'C' LC_CTYPE 'C';"
    exit 1
fi

date -u '+%Y-%m-%d %H:%M:%S UTC' > "${MARKER}"
chown "${PUID:-99}:${PGID:-100}" "${MARKER}" 2>/dev/null || true

SEP=$(printf '%72s' '' | tr ' ' '#')
echo ""
echo "$SEP"
echo "###  ACCOUNTS MIGRATED  -  authentication is now handled by the auth service  ###"
echo "$SEP"
echo ""
log_info "Users keep their sessions and devices; nobody has been signed out."
log_info "Passwords now live in the auth service. Password changes, email and session"
log_info "management happen in its web UI from here on."
log_info "This will not run again (marker: ${MARKER})."
