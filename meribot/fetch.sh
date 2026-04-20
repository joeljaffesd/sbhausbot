#!/usr/bin/env bash
set -euo pipefail

OUT_DATE="${1:-$(date +%F)}"
OUTPUT_ROOT="output"
TMP_DIR="${OUTPUT_ROOT}/${OUT_DATE}_intermediate"
DETAIL_DIR="${TMP_DIR}/details"
RESIDENTIAL_URL="https://meridiangrouprem.com/properties/?ptype=residential"
RENT_LIST_URL="https://meridiangrouprem.com/rent-list/?list=residential"

mkdir -p "$DETAIL_DIR"

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

echo "Fetching source pages..."
fetch_text "$RESIDENTIAL_URL" "${TMP_DIR}/residential.html"
fetch_text "$RENT_LIST_URL" "${TMP_DIR}/rent_list.html"

python3 - "${TMP_DIR}/residential.html" "${TMP_DIR}/detail_urls.txt" <<'PY'
import re
import sys

html = open(sys.argv[1], "r", encoding="utf-8", errors="ignore").read()
out_file = sys.argv[2]

matches = re.findall(
    r'https://meridiangrouprem\.com/properties/[a-z0-9\-]+(?:/[a-z0-9\-]+)*/',
    html,
    flags=re.IGNORECASE,
)

seen = set()
urls = []
for url in matches:
    if "?" in url or url.rstrip("/").endswith("properties"):
        continue
    if url in seen:
        continue
    seen.add(url)
    urls.append(url)

with open(out_file, "w", encoding="utf-8") as f:
    for url in sorted(urls):
        f.write(url + "\n")

print(f"Discovered {len(urls)} detail URLs")
PY

python3 - "${TMP_DIR}/detail_urls.txt" "$DETAIL_DIR" "${TMP_DIR}/detail_manifest.tsv" <<'PY'
import os
import sys
import urllib.request

urls_file, detail_dir, manifest_file = sys.argv[1], sys.argv[2], sys.argv[3]

with open(urls_file, "r", encoding="utf-8") as f:
    urls = [line.strip() for line in f if line.strip()]

headers = {
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0 Safari/537.36"
}

count = 0
with open(manifest_file, "w", encoding="utf-8") as manifest:
    for idx, url in enumerate(urls, start=1):
        req = urllib.request.Request(url, headers=headers)
        out_name = f"detail_{idx:03d}.html"
        out_path = os.path.join(detail_dir, out_name)

        try:
            with urllib.request.urlopen(req, timeout=45) as resp:
                html = resp.read().decode("utf-8", errors="ignore")
            with open(out_path, "w", encoding="utf-8") as out:
                out.write(html)
            manifest.write(f"{out_name}\t{url}\n")
            count += 1
        except Exception as exc:
            manifest.write(f"ERROR\t{url}\t{exc}\n")

print(f"Fetched {count} detail pages")
PY

echo "Wrote intermediate data to ${TMP_DIR}"
