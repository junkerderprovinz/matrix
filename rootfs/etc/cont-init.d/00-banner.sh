#!/command/with-contenv sh
# shellcheck shell=sh
# =============================================================================
# 00-banner.sh — print the Junker-der-Provinz init-log banner
# Runs first in the s6-overlay cont-init.d phase (lexicographically before
# 10-config.sh) so the banner heads the container log on every start.
# =============================================================================
/usr/local/bin/print-banner.sh \
    "Matrix All-in-One for Unraid" \
    "Synapse + coturn + Element Web + Synapse-Admin"
