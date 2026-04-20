#!/usr/bin/env bash
set -euo pipefail

OUT_DATE="${1:-$(date +%F)}"
OUTPUT_ROOT="output"
TMP_DIR="${OUTPUT_ROOT}/${OUT_DATE}_intermediate"
DETAIL_DIR="${TMP_DIR}/details"

PAGE_URL="https://www.sandpiperpropertymanagement.com/santa-barbara-homes-for-rent"
LISTINGS_URL="https://www.sandpiperpropertymanagement.com/_system/api/listings?pageSize=500&pg=1"
API_BASE="https://www.sandpiperpropertymanagement.com/_system/api/listings"

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

echo "Fetching Sandpiper rentals page and listing feed..."
fetch_text "$PAGE_URL" "${TMP_DIR}/rentals_page.html"
fetch_text "$LISTINGS_URL" "${TMP_DIR}/listings.json"

python3 - "${TMP_DIR}/listings.json" "${TMP_DIR}/listing_ids.txt" <<'PY'
import json
import sys

in_file, out_file = sys.argv[1:3]

with open(in_file, "r", encoding="utf-8", errors="ignore") as f:
    payload = json.load(f)

rows = payload.get("listings") or []
ids = []
seen = set()
for row in rows:
    listing_id = str(row.get("listingID", "")).strip()
    if not listing_id or listing_id in seen:
        continue
    seen.add(listing_id)
    ids.append(listing_id)

ids.sort(key=lambda s: (0, int(s)) if s.isdigit() else (1, s))

with open(out_file, "w", encoding="utf-8") as out:
    for listing_id in ids:
        out.write(listing_id + "\n")

print(f"Discovered {len(ids)} listing IDs")
PY

python3 - "${TMP_DIR}/listing_ids.txt" "$DETAIL_DIR" "${TMP_DIR}/detail_manifest.tsv" "$API_BASE" <<'PY'
import json
import os
import sys
import time
import urllib.request

ids_file, detail_dir, manifest_file, api_base = sys.argv[1:5]

with open(ids_file, "r", encoding="utf-8") as f:
    ids = [line.strip() for line in f if line.strip()]

headers = {
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0 Safari/537.36"
}

count = 0
with open(manifest_file, "w", encoding="utf-8") as manifest:
    for idx, listing_id in enumerate(ids, start=1):
        url = f"{api_base}/{listing_id}"
        out_name = f"detail_{idx:03d}.json"
        out_path = os.path.join(detail_dir, out_name)

        body = None
        last_exc = None

        for _ in range(3):
            req = urllib.request.Request(url, headers=headers)
            try:
                with urllib.request.urlopen(req, timeout=45) as resp:
                    body = resp.read().decode("utf-8", errors="ignore")
                break
            except Exception as exc:
                last_exc = exc
                time.sleep(0.4)

        if body is None:
            manifest.write(f"ERROR\t{listing_id}\t{url}\t{last_exc}\n")
            continue

        try:
            parsed = json.loads(body)
        except Exception as exc:
            manifest.write(f"ERROR\t{listing_id}\t{url}\tinvalid-json: {exc}\n")
            continue

        with open(out_path, "w", encoding="utf-8") as out:
            json.dump(parsed, out, ensure_ascii=True)

        manifest.write(f"{out_name}\t{listing_id}\t{url}\n")
        count += 1
        time.sleep(0.15)

print(f"Fetched {count} detail payloads")
PY

echo "Wrote intermediate data to ${TMP_DIR}"
