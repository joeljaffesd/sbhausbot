#!/usr/bin/env bash
set -euo pipefail

OUT_DATE="${1:-$(date +%F)}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

"${SCRIPT_DIR}/fetch.sh" "$OUT_DATE"
"${SCRIPT_DIR}/parse.sh" "$OUT_DATE"