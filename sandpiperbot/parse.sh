#!/usr/bin/env bash
set -euo pipefail

OUT_DATE="${1:-$(date +%F)}"
OUT_FILE="${OUT_DATE}.md"
TMP_DIR="output/${OUT_DATE}_intermediate"

if [[ ! -d "$TMP_DIR" ]]; then
  echo "Error: intermediate directory not found: $TMP_DIR" >&2
  echo "Run ./fetch.sh ${OUT_DATE} first." >&2
  exit 1
fi

for f in "${TMP_DIR}/listings.json" "${TMP_DIR}/detail_manifest.tsv"; do
  if [[ ! -f "$f" ]]; then
    echo "Error: missing required intermediate file: $f" >&2
    exit 1
  fi
done

python3 - "$OUT_FILE" "$TMP_DIR" "$OUT_DATE" <<'PY'
import datetime as dt
import html
import json
import os
import re
import sys
from collections import Counter

OUT_FILE, TMP_DIR, OUT_DATE = sys.argv[1:4]
SOURCE_PAGE = "https://www.sandpiperpropertymanagement.com/santa-barbara-homes-for-rent"
SOURCE_API = "https://www.sandpiperpropertymanagement.com/_system/api/listings?pageSize=500&pg=1"
BASE_URL = "https://www.sandpiperpropertymanagement.com"


def read_json(path: str):
    with open(path, "r", encoding="utf-8", errors="ignore") as f:
        return json.load(f)


def parse_money(value):
    if value in (None, ""):
        return None
    try:
        return float(str(value).replace(",", ""))
    except Exception:
        m = re.search(r"([0-9][0-9,]*(?:\.[0-9]+)?)", str(value))
        if not m:
            return None
        return float(m.group(1).replace(",", ""))


def fmt_money(value):
    num = parse_money(value)
    if num is None:
        return ""
    if abs(num - int(num)) < 1e-9:
        return f"${int(num):,}"
    return f"${num:,.2f}"


def clean_html_text(value: str) -> str:
    if not value:
        return ""
    text = re.sub(r"(?is)<script.*?</script>|<style.*?</style>", " ", value)
    text = re.sub(r"(?i)<br\s*/?>", "\n", text)
    text = re.sub(r"(?i)</p>|</li>|</div>|</h[1-6]>", "\n", text)
    text = re.sub(r"(?s)<[^>]+>", " ", text)
    text = html.unescape(text)
    text = text.replace("\xa0", " ")
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r"\n\s*\n+", "\n", text)
    text = re.sub(r"\s+", " ", text)
    return text.strip()


def md_escape(value: str) -> str:
    v = str(value or "")
    v = v.replace("|", "\\|")
    v = v.replace("\n", " ")
    v = re.sub(r"\s+", " ", v)
    return v.strip()


def normalize_availability(raw: str) -> str:
    val = (raw or "").strip()
    if not val:
        return ""
    # Format dates from YYYY-MM-DD to MM/DD/YYYY for readability.
    if re.match(r"^\d{4}-\d{2}-\d{2}$", val):
        if val <= OUT_DATE:
            return "Immediately"
        d = dt.datetime.strptime(val, "%Y-%m-%d").date()
        return d.strftime("%m/%d/%Y")
    return val


payload = read_json(os.path.join(TMP_DIR, "listings.json"))
rows = payload.get("listings") or []

image_count_by_id = {}
with open(os.path.join(TMP_DIR, "detail_manifest.tsv"), "r", encoding="utf-8", errors="ignore") as manifest:
    for line in manifest:
        line = line.rstrip("\n")
        if not line:
            continue
        cols = line.split("\t")
        if cols[0] == "ERROR" or len(cols) < 2:
            continue

        file_name = cols[0]
        listing_id = cols[1]
        detail_path = os.path.join(TMP_DIR, "details", file_name)
        if not os.path.exists(detail_path):
            continue

        try:
            detail_payload = read_json(detail_path)
        except Exception:
            continue

        images = detail_payload.get("images") or []
        image_count_by_id[str(listing_id)] = len(images)

records = []
for row in rows:
    listing_id = str(row.get("listingID", "")).strip()
    if not listing_id:
        continue

    rent = fmt_money(row.get("rent"))
    deposit = fmt_money(row.get("deposit"))
    beds = str(row.get("beds") or "").strip()
    baths_raw = row.get("baths")
    baths = ""
    if baths_raw not in (None, ""):
        try:
            bnum = float(str(baths_raw))
            baths = str(int(bnum)) if abs(bnum - int(bnum)) < 1e-9 else str(bnum)
        except Exception:
            baths = str(baths_raw).strip()

    beds_baths = ""
    if beds or baths:
        beds_baths = f"{beds}/{baths}".strip("/")

    desc = clean_html_text(str(row.get("description") or ""))
    if len(desc) > 220:
        desc = desc[:217].rstrip() + "..."

    detail_rel = row.get("pageUrl") or row.get("systemUrl") or ""
    detail_url = f"{BASE_URL}{detail_rel}" if detail_rel else ""

    records.append(
        {
            "listing_id": listing_id,
            "address": str(row.get("address") or "").strip(),
            "city": str(row.get("city") or "").strip(),
            "state": str(row.get("stateID") or "").strip(),
            "zip": str(row.get("postalCode") or "").strip(),
            "beds_baths": beds_baths,
            "rent": rent,
            "rent_num": parse_money(row.get("rent")),
            "deposit": deposit,
            "availability": normalize_availability(str(row.get("dateAvailable") or "")),
            "property_type": str(row.get("propertyTypeName") or "").strip(),
            "parking_type": str(row.get("parkingTypeName") or "").strip(),
            "phone": str(row.get("phone") or "").strip(),
            "email": str(row.get("email") or "").strip(),
            "image_count": image_count_by_id.get(listing_id, 0),
            "detail_url": detail_url,
            "summary": desc,
        }
    )

records.sort(key=lambda r: (r.get("city", ""), r.get("address", ""), r.get("listing_id", "")))

city_counts = Counter(r["city"] for r in records if r.get("city"))
type_counts = Counter(r["property_type"] for r in records if r.get("property_type"))

rents = [r["rent_num"] for r in records if r["rent_num"] is not None]
min_rent = f"${min(rents):,.0f}" if rents else "N/A"
max_rent = f"${max(rents):,.0f}" if rents else "N/A"

immediate_count = sum(1 for r in records if (r.get("availability") == "Immediately"))

generated_at = dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")

lines = []
lines.append(f"# Sandpiper Listings Report ({OUT_FILE.replace('.md', '')})")
lines.append("")
lines.append(f"Generated at: {generated_at}")
lines.append("")
lines.append("## Sources")
lines.append("")
lines.append(f"- {SOURCE_PAGE}")
lines.append(f"- {SOURCE_API}")
lines.append("")
lines.append("## Snapshot")
lines.append("")
lines.append(f"- Total active listings captured: {len(records)}")
lines.append(f"- Rent range in captured listings: {min_rent} to {max_rent}")
lines.append(f"- Immediate availability count: {immediate_count}")
if city_counts:
    lines.append("- Cities represented: " + ", ".join(f"{city} ({count})" for city, count in city_counts.most_common()))
if type_counts:
    lines.append("- Property types: " + ", ".join(f"{ptype} ({count})" for ptype, count in type_counts.most_common()))
lines.append("")

lines.append("## Combined Listings")
lines.append("")
lines.append("| Listing ID | Address | City | Beds/Baths | Rent | Security Deposit | Availability | Type | Parking | Images | Contact Phone | Contact Email | Detail URL | Summary |")
lines.append("|---|---|---|---|---:|---:|---|---|---|---:|---|---|---|---|")
for r in records:
    lines.append(
        "| "
        + " | ".join(
            [
                md_escape(r.get("listing_id", "")),
                md_escape(r.get("address", "")),
                md_escape(r.get("city", "")),
                md_escape(r.get("beds_baths", "")),
                md_escape(r.get("rent", "")),
                md_escape(r.get("deposit", "")),
                md_escape(r.get("availability", "")),
                md_escape(r.get("property_type", "")),
                md_escape(r.get("parking_type", "")),
                md_escape(r.get("image_count", "")),
                md_escape(r.get("phone", "")),
                md_escape(r.get("email", "")),
                md_escape(r.get("detail_url", "")),
                md_escape(r.get("summary", "")),
            ]
        )
        + " |"
    )
lines.append("")

with open(OUT_FILE, "w", encoding="utf-8") as f:
    f.write("\n".join(lines))

print(f"Wrote {OUT_FILE} with {len(records)} listings")
PY

echo "Done: ${OUT_FILE}"
