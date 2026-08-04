#!/command/with-contenv sh
# shellcheck shell=sh
# =============================================================================
# 25-mas-migrate.sh — one-shot syn2mas migration of existing Synapse accounts
#
# Runs after 20-mas.sh, and — this is the whole point of putting it here —
# BEFORE any service starts.
#
# ------------------------------------------------------- why cont-init.d -----
# Upstream is emphatic that Synapse must be offline during `syn2mas migrate`.
# Every "run this by hand" recipe therefore depends on the operator remembering
# to stop the homeserver first, and on nothing restarting it midway. In
# cont-init.d that requirement is not a instruction to follow but a property of
# the environment: s6 has not started the synapse service yet and will not until
# every cont-init script has returned. The migration simply cannot race a
# running homeserver from here.
#
# ------------------------------------------------------------ safety ---------
# This is the one irreversible step in the whole feature. Once MAS has been
# started and anybody has signed in, only a database restore undoes it. So:
#
#   * It never runs unless AUTH_MIGRATE is explicitly true. Default is off.
#   * It never runs twice: a marker file is written on success and checked first.
#     Leaving AUTH_MIGRATE=true set is therefore harmless, which matters because
#     people forget to unset things.
#   * It runs `check` first and refuses on any error. Then a `--dry-run`, which
#     upstream restores to an empty MAS database afterwards, so a failure there
#     costs nothing and catches the same problems the real run would hit.
#   * Any failure exits non-zero, which stops the container (see
#     S6_BEHAVIOUR_IF_STAGE2_FAILS in the Dockerfile) rather than starting a
#     homeserver whose accounts are in an unknown half-migrated state.
#
# syn2mas never writes to the Synapse database, so a failure before the MAS
# database is populated leaves the original untouched.
# =============================================================================

log_info()  { printf '\033[0;32m[migrate] INFO:  %s\033[0m\n'  "$*"; }
log_warn()  { printf '\033[0;33m[migrate] WARN:  %s\033[0m\n'  "$*"; }
log_error() { printf '\033[0;31m[migrate] ERROR: %s\033[0m\n'  "$*" >&2; }

MAS_DIR=/data/mas
MARKER="${MAS_DIR}/.migrated"

# Both Synapse config files, in the same order the synapse service loads them.
# The database connection lives in the OVERRIDES file, not in homeserver.yaml —
# passing only the latter would point syn2mas at the generated SQLite defaults
# instead of the real PostgreSQL database.
SYN_ARGS="--synapse-config /data/homeserver.yaml --synapse-config /data/homeserver-overrides.yaml"

# --- Gating ------------------------------------------------------------------
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
    log_error "${MAS_DIR}/config.yaml is missing — 20-mas.sh did not complete."
    exit 1
fi

# --- 1. Check ----------------------------------------------------------------
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

# --- 2. Dry run --------------------------------------------------------------
# Writes to the MAS database and then restores it to empty, so this exercises
# the real code path without committing to anything.
log_info "Performing a dry run ..."
if ! mas-cli syn2mas migrate --dry-run --config "${MAS_DIR}/config.yaml" ${SYN_ARGS}; then
    log_error "The dry run failed. Nothing has been migrated and both databases are intact."
    exit 1
fi
log_info "Dry run succeeded."

# --- 3. The real thing -------------------------------------------------------
log_warn "Migrating accounts for real now. Synapse is not running yet, which is exactly"
log_warn "the offline window this needs. Do not interrupt the container."
if ! mas-cli syn2mas migrate --config "${MAS_DIR}/config.yaml" ${SYN_ARGS}; then
    log_error "Migration FAILED partway through."
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
