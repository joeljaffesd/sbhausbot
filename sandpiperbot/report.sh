#!/usr/bin/env bash

set -euo pipefail

RECIPIENT="${1:-}"
DRY_RUN="${2:-}"

if [[ -z "$RECIPIENT" ]]; then
  echo "Usage: $0 <recipient> [--dry-run]" >&2
  exit 1
fi

COMP_FILE="$(ls -1t ./*_comp.md 2>/dev/null | head -n1 || true)"
if [[ -z "$COMP_FILE" ]]; then
  echo "No *_comp.md files found in $(pwd)" >&2
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

    listing_id = trim($3)
    address = trim($4)
    city = trim($5)
    beds = trim($6)
    rent = trim($7)
    deposit = trim($8)
    avail = trim($9)
    ptype = trim($10)

    if (rent == "") rent = "n/a"
    if (deposit == "") deposit = "n/a"
    if (avail == "") avail = "n/a"
    if (beds == "") beds = "n/a"
    if (ptype == "") ptype = "n/a"

    count += 1
    printf "%d) %s\n", count, change
    printf "   Listing ID: %s\n", listing_id
    printf "   Address: %s", address
    if (city != "") {
        printf ", %s", city
    }
    printf "\n"
    printf "   Beds/Baths: %s\n", beds
    printf "   Rent: %s\n", rent
    printf "   Security Deposit: %s\n", deposit
    printf "   Availability: %s\n", avail
    printf "   Type: %s\n", ptype
}
END {
    if (count == 0) {
        printf "No listing changes found.\n"
    }
}
' "$COMP_FILE")"

MESSAGE="Sandpiperbot update: $REPORT_DATE
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
