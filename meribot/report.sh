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

    address = trim($3)
    city = trim($4)
    size = trim($5)
    rent = trim($6)
    status = trim($7)
    vacate = trim($8)
    utilities = trim($10)

    if (rent == "") rent = "n/a"
    if (status == "") status = "n/a"
    if (vacate == "") vacate = "n/a"
    if (utilities == "") utilities = "n/a"
    if (size == "") size = "n/a"

    count += 1
    printf "%d) %s\n", count, change
    printf "   Address: %s, %s\n", address, city
    printf "   Size: %s\n", size
    printf "   Monthly Rent: %s\n", rent
    printf "   Status: %s\n", status
    printf "   Vacate Date: %s\n", vacate
    printf "   Utilities: %s\n", utilities
}
END {
    if (count == 0) {
        printf "No unit-level listing changes found.\n"
    }
}
' "$COMP_FILE")"

MESSAGE="Meribot update: $REPORT_DATE
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
