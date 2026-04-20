#!/bin/bash

set -euo pipefail

RECIPIENT="${1:-}"
DRY_RUN="${2:-}"

if [[ -z "$RECIPIENT" ]]; then
    echo "Usage: $0 <recipient> [--dry-run]"
    exit 1
fi

COMP_FILE="$(ls -1t ./*_comp.md 2>/dev/null | head -n1 || true)"
if [[ -z "$COMP_FILE" ]]; then
    echo "No *_comp.md files found in $(pwd)"
    exit 1
fi

REPORT_DATE="$(basename "$COMP_FILE" | sed 's/_comp\.md$//')"

CHANGE_LINES="$(awk -F'|' '
function trim(s) {
    gsub(/^[ \t]+|[ \t]+$/, "", s)
    return s
}
/^\|/ {
    if ($0 ~ /^\|---/) next
    change = trim($2)
    if (change == "" || change == "Change") next
    if (change != "Added") next

    location = trim($3)
    beds_baths = trim($4)
    rent = trim($5)
    avail = trim($6)
    util = trim($7)
    other = trim($8)

    if (rent == "") rent = "n/a"
    if (avail == "") avail = "n/a"
    if (util == "") util = "n/a"
    if (beds_baths == "") beds_baths = "n/a"

    count += 1
    printf "%d) %s\n", count, change
    printf "   Location: %s\n", location
    printf "   Beds/Baths: %s\n", beds_baths
    printf "   Net Rent: $%s\n", rent
    printf "   Availability: %s\n", avail
    printf "   Utilities Paid: %s\n", util
    if (other != "" && other != "-") {
        printf "   Notes: %s\n", other
    }
}
END {
    if (count == 0) {
        printf "No new listings found.\n"
    }
}
' "$COMP_FILE")"

MESSAGE="Bartbot update: $REPORT_DATE
$CHANGE_LINES"

if [[ "$DRY_RUN" == "--dry-run" ]]; then
    printf '%s\n' "$MESSAGE"
    exit 0
fi

osascript - "$RECIPIENT" "$MESSAGE" <<'EOF'
on run argv
    set recipient to item 1 of argv
    set msg to item 2 of argv

    tell application "Messages"
        set svc to first service whose service type is iMessage
        set b to buddy recipient of svc
        send msg to b
    end tell
end run
EOF