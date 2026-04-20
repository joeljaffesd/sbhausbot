#!/usr/bin/env bash
set -euo pipefail

RENTALS_URL="https://www.bartlein.com/rentals/"
FALLBACK_URL_1="https://www.bartlein.com/wp-content/uploads/2021/07/SBList.pdf"
FALLBACK_URL_2="https://www.bartlein.com/wp-content/uploads/2021/06/SBList.pdf"
OUT_FILE="SBList.pdf"

if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
  echo "Error: neither curl nor wget is installed." >&2
  exit 1
fi

fetch_text() {
  local url="$1"
  if command -v curl >/dev/null 2>&1; then
    curl --fail --location --silent --show-error "$url"
  else
    wget -qO - "$url"
  fi
}

download_file() {
  local url="$1"
  local out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl --fail --location --silent --show-error --output "$out" "$url"
  else
    wget -qO "$out" "$url"
  fi
}

candidates=()
if [[ $# -ge 1 ]]; then
  candidates+=("$1")
else
  discovered="$(fetch_text "$RENTALS_URL" \
    | tr '"' '\n' \
    | grep -E 'https?://[^[:space:]]*/SBList\.pdf' \
    | head -n 1 || true)"

  if [[ -n "$discovered" ]]; then
    candidates+=("$discovered")
  fi
  candidates+=("$FALLBACK_URL_1" "$FALLBACK_URL_2")
fi

tmp_file="${OUT_FILE}.tmp"
rm -f "$tmp_file"

used_url=""
for url in "${candidates[@]}"; do
  if download_file "$url" "$tmp_file" 2>/dev/null && [[ -s "$tmp_file" ]]; then
    used_url="$url"
    break
  fi
done

if [[ -z "$used_url" ]]; then
  echo "Error: unable to download SBList.pdf from known URLs." >&2
  exit 1
fi

mv "$tmp_file" "$OUT_FILE"

if [[ ! -s "$OUT_FILE" ]]; then
  echo "Error: downloaded file is empty: $OUT_FILE" >&2
  exit 1
fi

echo "Saved $OUT_FILE from $used_url"
