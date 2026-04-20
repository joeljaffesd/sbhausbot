#!/usr/bin/env bash
set -euo pipefail

OUT_DATE="${1:-$(date +%F)}"
OUTPUT_ROOT="output"
TMP_DIR="${OUTPUT_ROOT}/${OUT_DATE}_intermediate"
RESIDENTIAL_URL="https://sierrapropsb.com/residential/"

mkdir -p "$TMP_DIR"

if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
  echo "Error: neither curl nor wget is installed." >&2
  exit 1
fi

fetch_text() {
  local url="$1"
  local out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl --fail --location --silent --show-error --output "$out" "$url"
  else
    wget -qO "$out" "$url"
  fi
}

echo "Fetching residential listings page..."
fetch_text "$RESIDENTIAL_URL" "${TMP_DIR}/residential.html"

echo "Wrote intermediate data to ${TMP_DIR}"
