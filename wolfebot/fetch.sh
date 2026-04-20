#!/usr/bin/env bash
set -euo pipefail

OUT_DATE="${1:-$(date +%F)}"
OUTPUT_ROOT="output"
TMP_DIR="${OUTPUT_ROOT}/${OUT_DATE}_intermediate"
DETAIL_DIR="${TMP_DIR}/details"

SANTA_BARBARA_URL="https://www.rlwa.com/santa-barbara-listings"
GOLETA_URL="https://www.rlwa.com/goleta-listings"
R_JINA_PREFIX="https://r.jina.ai/http://"

mkdir -p "$DETAIL_DIR"

if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
  echo "Error: neither curl nor wget is installed." >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "Error: python3 is required." >&2
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

render_url() {
  local raw_url="$1"
  # r.jina.ai expects an http:// source URL string after the prefix.
  local no_scheme="${raw_url#https://}"
  no_scheme="${no_scheme#http://}"
  printf '%s%s' "$R_JINA_PREFIX" "$no_scheme"
}

echo "Fetching rendered listing pages..."
fetch_text "$(render_url "$SANTA_BARBARA_URL")" "${TMP_DIR}/santa_barbara.md"
fetch_text "$(render_url "$GOLETA_URL")" "${TMP_DIR}/goleta.md"

python3 - "${TMP_DIR}/santa_barbara.md" "${TMP_DIR}/goleta.md" "${TMP_DIR}/detail_urls.txt" <<'PY'
import re
import sys

in_files = [sys.argv[1], sys.argv[2]]
out_file = sys.argv[3]

url_re = re.compile(r"https?://www\.rlwa\.com/listings/detail/[a-f0-9\-]+", re.IGNORECASE)

seen = set()
urls = []

for path in in_files:
    text = open(path, "r", encoding="utf-8", errors="ignore").read()
    for url in url_re.findall(text):
        # Normalize to https without trailing slash.
        norm = re.sub(r"^http://", "https://", url.rstrip("/"), flags=re.IGNORECASE)
        if norm in seen:
            continue
        seen.add(norm)
        urls.append(norm)

with open(out_file, "w", encoding="utf-8") as f:
    for url in sorted(urls):
        f.write(url + "\n")

print(f"Discovered {len(urls)} detail URLs")
PY

python3 - "${TMP_DIR}/detail_urls.txt" "$DETAIL_DIR" "${TMP_DIR}/detail_manifest.tsv" "$R_JINA_PREFIX" <<'PY'
import os
import sys
import time
import urllib.request

urls_file, detail_dir, manifest_file, r_jina_prefix = sys.argv[1:5]

with open(urls_file, "r", encoding="utf-8") as f:
    urls = [line.strip() for line in f if line.strip()]

headers = {
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0 Safari/537.36"
}

count = 0
with open(manifest_file, "w", encoding="utf-8") as manifest:
    for idx, url in enumerate(urls, start=1):
        rendered_url = r_jina_prefix + url.replace("https://", "").replace("http://", "")
        out_name = f"detail_{idx:03d}.md"
        out_path = os.path.join(detail_dir, out_name)

        body = None
        last_exc = None

        # Try rendered markdown first, then raw page HTML as fallback.
        candidate_urls = [rendered_url, url]
        for candidate in candidate_urls:
            for _ in range(3):
                req = urllib.request.Request(candidate, headers=headers)
                try:
                    with urllib.request.urlopen(req, timeout=60) as resp:
                        body = resp.read().decode("utf-8", errors="ignore")
                    break
                except Exception as exc:
                    last_exc = exc
                    time.sleep(0.5)
            if body is not None:
                break

        if body is None:
            manifest.write(f"ERROR\t{url}\t{last_exc}\n")
            continue

        with open(out_path, "w", encoding="utf-8") as out:
            out.write(body)
        manifest.write(f"{out_name}\t{url}\n")
        count += 1
        time.sleep(0.2)

print(f"Fetched {count} detail pages")
PY

echo "Wrote intermediate data to ${TMP_DIR}"