#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

RECIPIENT="${1:-}"
DRY_RUN="${2:-}"

if [[ -n "$DRY_RUN" && "$DRY_RUN" != "--dry-run" ]]; then
  echo "Usage: $0 [recipient] [--dry-run]" >&2
  exit 1
fi

"${SCRIPT_DIR}/fetch.sh"
"${SCRIPT_DIR}/parse.sh" "${SCRIPT_DIR}/SBList.pdf"
"${SCRIPT_DIR}/compare.sh"

if [[ -n "$RECIPIENT" ]]; then
  "${SCRIPT_DIR}/report.sh" "$RECIPIENT" "$DRY_RUN"
fi

echo "Completed bartbot run"
