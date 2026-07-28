#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────
# print-banner.sh <container-name> <subtitle>
# Einheitlicher Init-Log-Banner für alle Junker-der-Provinz-Container
# ─────────────────────────────────────────────────────────────────

CONTAINER="${1:-Container}"
SUBTITLE="${2:-}"
BANNER_FILE="/usr/local/share/banner.txt"

echo ""

if [ -f "${BANNER_FILE}" ]; then
    cat "${BANNER_FILE}"
    # The shared banner file has no trailing newline; add blank lines so the
    # banner gets breathing room before the title block.
    echo ""
    echo ""
else
    echo ""
    echo "  Junker der Provinz"
    echo ""
fi

# Clean title block: name + subtitle only, no rules (house look).
printf '  %s\n' "${CONTAINER}"
[ -n "${SUBTITLE}" ] && printf '  %s\n' "${SUBTITLE}"
echo ""
