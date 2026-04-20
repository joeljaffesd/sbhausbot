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

for f in "${TMP_DIR}/residential.html" "${TMP_DIR}/rent_list.html" "${TMP_DIR}/detail_manifest.tsv"; do
  if [[ ! -f "$f" ]]; then
    echo "Error: missing required intermediate file: $f" >&2
    exit 1
  fi
done

python3 - "$OUT_FILE" "$TMP_DIR" <<'PY'
import datetime as dt
import html
import os
import re
import sys
from collections import Counter

OUT_FILE = sys.argv[1]
TMP_DIR = sys.argv[2]
RESIDENTIAL_URL = "https://meridiangrouprem.com/properties/?ptype=residential"
RENT_LIST_URL = "https://meridiangrouprem.com/rent-list/?list=residential"


def read_text(path: str) -> str:
    with open(path, "r", encoding="utf-8", errors="ignore") as f:
        return f.read()


def strip_tags(value: str) -> str:
    text = re.sub(r"(?is)<script.*?</script>|<style.*?</style>", " ", value)
    text = re.sub(r"(?i)<br\s*/?>", "\n", text)
    text = re.sub(r"(?i)</p>|</tr>|</li>|</h[1-6]>", "\n", text)
    text = re.sub(r"(?s)<[^>]+>", " ", text)
    text = html.unescape(text)
    text = text.replace("\xa0", " ")
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r"\n\s*\n+", "\n", text)
    return text.strip()


def oneline(value: str) -> str:
    value = strip_tags(value)
    value = re.sub(r"\s+", " ", value)
    return value.strip()


def md_escape(value: str) -> str:
    v = str(value or "")
    v = v.replace("|", "\\|")
    v = v.replace("\n", "<br>")
    return v


def money_to_float(value: str):
    if not value:
        return None
    m = re.search(r"([0-9][0-9,]*(?:\.[0-9]+)?)", value)
    if not m:
        return None
    return float(m.group(1).replace(",", ""))


def split_address_city(value: str):
    raw = strip_tags(value)
    lines = [ln.strip(" ,") for ln in raw.split("\n") if ln.strip()]
    if not lines:
        return "", ""
    if len(lines) == 1:
        return lines[0], ""
    return lines[0], lines[1]


def parse_location(loc: str):
    loc = oneline(loc)
    m = re.match(r"^(.*?)\s+([A-Z]{2})\s+(\d{5})$", loc)
    if not m:
        return loc, "", ""
    city, state, zip_code = m.group(1), m.group(2), m.group(3)
    return city.strip(), state, zip_code


def parse_rent_list(html_text: str):
    unit_rows = []

    chunks = re.split(r'(?i)(?=<table\s+width="1200px")', html_text)
    for chunk in chunks:
        first_row = re.search(r"(?is)<tr>\s*(.*?)\s*</tr>", chunk)
        if not first_row:
            continue

        cols = re.findall(r"(?is)<td[^>]*>(.*?)</td>", first_row.group(1))
        if len(cols) < 8:
            continue

        if any("Monthly Rent" in oneline(c) for c in cols):
            continue

        status = oneline(cols[0])
        address, city = split_address_city(cols[1])
        size = oneline(cols[2])
        vacate_date = oneline(cols[3])
        monthly_rent = oneline(cols[4])
        annual_parking_fee = oneline(cols[5])
        utilities = oneline(cols[6])
        laundry = oneline(cols[7])

        def detail(label: str) -> str:
            m = re.search(rf"(?is){re.escape(label)}:\s*</span>\s*(.*?)</td>", chunk)
            return oneline(m.group(1)) if m else ""

        description = detail("Description")
        lease_term = detail("Lease Term")
        guarantor = detail("Guarantor")
        pets = detail("Pets")

        if not (address and monthly_rent):
            continue

        unit_rows.append(
            {
                "status": status,
                "address": address,
                "city": city,
                "size": size,
                "vacate_date": vacate_date,
                "monthly_rent": monthly_rent,
                "annual_parking_fee": annual_parking_fee,
                "utilities": utilities,
                "laundry": laundry,
                "description": description,
                "lease_term": lease_term,
                "guarantor": guarantor,
                "pets": pets,
            }
        )

    return unit_rows


def parse_availability_units(clean_text: str):
    units = []
    pattern = re.compile(
        r"Unit\s+(.+?)\s+Bed\s+(.+?)\s+Bath\s+(.+?)\s+Sq\.Ft\.\s+(.+?)\s+Avail\.\s+(.+?)\s+\$([0-9,]+(?:\.[0-9]+)?)\/month",
        flags=re.IGNORECASE,
    )
    for m in pattern.finditer(clean_text):
        units.append(
            {
                "unit": oneline(m.group(1)),
                "bed": oneline(m.group(2)),
                "bath": oneline(m.group(3)),
                "sqft": oneline(m.group(4)),
                "avail": oneline(m.group(5)),
                "rent": "$" + m.group(6),
                "rent_num": float(m.group(6).replace(",", "")),
            }
        )

    pattern_fallback = re.compile(
        r"Unit\s+(.+?)\s+Sq\.Ft\.\s+(.+?)\s+Avail\.\s+(.+?)\s+\$([0-9,]+(?:\.[0-9]+)?)\/month",
        flags=re.IGNORECASE,
    )
    for m in pattern_fallback.finditer(clean_text):
        unit_name = oneline(m.group(1))
        if any(u["unit"] == unit_name for u in units):
            continue
        units.append(
            {
                "unit": unit_name,
                "bed": "",
                "bath": "",
                "sqft": oneline(m.group(2)),
                "avail": oneline(m.group(3)),
                "rent": "$" + m.group(4),
                "rent_num": float(m.group(4).replace(",", "")),
            }
        )

    return units


def parse_detail_page(html_text: str, url: str):
    text = strip_tags(html_text)

    h2 = re.search(r"(?is)<h2[^>]*>\s*([^<]+?)\s*</h2>", html_text)
    h3s = re.findall(r"(?is)<h3[^>]*>\s*([^<]*?)\s*</h3>", html_text)

    address = oneline(h2.group(1)) if h2 else ""
    location = oneline(h3s[0]) if len(h3s) > 0 else ""
    prop_type = oneline(h3s[1]) if len(h3s) > 1 else ""

    desc_match = re.search(
        r"(?is)<h3[^>]*>\s*[^<]*\s*</h3>\s*(.*?)\s*(?:<h3[^>]*>\s*Building Amenities\s*</h3>|<h3[^>]*>\s*Availability\s*</h3>)",
        html_text,
    )
    description = strip_tags(desc_match.group(1)) if desc_match else ""

    amenities = []
    am_block = re.search(
        r"(?is)<h3[^>]*>\s*Building Amenities\s*</h3>\s*(.*?)\s*<h3[^>]*>\s*Availability\s*</h3>",
        html_text,
    )
    if am_block:
        lines = [oneline(x) for x in strip_tags(am_block.group(1)).split("\n")]
        amenities = [x for x in lines if x]

    pet_policy = ""
    for sentence in re.split(r"(?<=[.!?])\s+", description):
        if "pet" in sentence.lower():
            pet_policy = sentence.strip()
            break

    units = parse_availability_units(text)

    city, state, zip_code = parse_location(location)
    min_rent = None
    if units:
        min_rent = min(u["rent_num"] for u in units)

    return {
        "url": url,
        "address": address,
        "city": city,
        "state": state,
        "zip": zip_code,
        "property_type": prop_type,
        "description": description,
        "amenities": amenities,
        "pet_policy": pet_policy,
        "units": units,
        "starting_rent": f"${min_rent:,.0f}" if min_rent is not None else "",
        "starting_rent_num": min_rent,
    }


residential_html = read_text(os.path.join(TMP_DIR, "residential.html"))
rent_list_html = read_text(os.path.join(TMP_DIR, "rent_list.html"))

properties = []
manifest_path = os.path.join(TMP_DIR, "detail_manifest.tsv")
with open(manifest_path, "r", encoding="utf-8", errors="ignore") as manifest:
    for row in manifest:
        row = row.rstrip("\n")
        if not row:
            continue
        cols = row.split("\t")
        if cols[0] == "ERROR":
            url = cols[1] if len(cols) > 1 else ""
            reason = cols[2] if len(cols) > 2 else "unknown error"
            properties.append(
                {
                    "url": url,
                    "address": "",
                    "city": "",
                    "state": "",
                    "zip": "",
                    "property_type": "",
                    "description": f"Failed to fetch detail page: {reason}",
                    "amenities": [],
                    "pet_policy": "",
                    "units": [],
                    "starting_rent": "",
                    "starting_rent_num": None,
                }
            )
            continue

        if len(cols) < 2:
            continue

        file_name, url = cols[0], cols[1]
        detail_path = os.path.join(TMP_DIR, "details", file_name)
        if not os.path.exists(detail_path):
            properties.append(
                {
                    "url": url,
                    "address": "",
                    "city": "",
                    "state": "",
                    "zip": "",
                    "property_type": "",
                    "description": "Failed to parse detail page: cached HTML missing",
                    "amenities": [],
                    "pet_policy": "",
                    "units": [],
                    "starting_rent": "",
                    "starting_rent_num": None,
                }
            )
            continue

        try:
            html_text = read_text(detail_path)
            properties.append(parse_detail_page(html_text, url))
        except Exception as exc:
            properties.append(
                {
                    "url": url,
                    "address": "",
                    "city": "",
                    "state": "",
                    "zip": "",
                    "property_type": "",
                    "description": f"Failed to parse detail page: {exc}",
                    "amenities": [],
                    "pet_policy": "",
                    "units": [],
                    "starting_rent": "",
                    "starting_rent_num": None,
                }
            )

unit_rows = parse_rent_list(rent_list_html)

city_counter = Counter()
for p in properties:
    if p["city"]:
        city_counter[p["city"]] += 1

numeric_rents = []
for u in unit_rows:
    num = money_to_float(u.get("monthly_rent", ""))
    if num is not None:
        numeric_rents.append(num)

min_rent = f"${min(numeric_rents):,.0f}" if numeric_rents else "N/A"
max_rent = f"${max(numeric_rents):,.0f}" if numeric_rents else "N/A"

generated_at = dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")

lines = []
lines.append(f"# Residential Scrape Report ({OUT_FILE.replace('.md', '')})")
lines.append("")
lines.append(f"Generated at: {generated_at}")
lines.append("")
lines.append("## Sources")
lines.append("")
lines.append(f"- {RESIDENTIAL_URL}")
lines.append(f"- {RENT_LIST_URL}")
lines.append("")
lines.append("## Snapshot")
lines.append("")
lines.append(f"- Properties discovered from residential page: {len(properties)}")
lines.append(f"- Unit-level records parsed from rent list: {len(unit_rows)}")
lines.append(f"- Unit rent range from parsed records: {min_rent} to {max_rent}")
if city_counter:
    top_cities = ", ".join(f"{city} ({count})" for city, count in city_counter.most_common())
    lines.append(f"- Cities represented in property pages: {top_cities}")
lines.append("")

lines.append("## Property Inventory")
lines.append("")
lines.append("| Address | City | State | ZIP | Type | Starting Rent | Amenities | Pet Policy | Detail URL |")
lines.append("|---|---|---|---|---|---:|---|---|---|")
for p in sorted(properties, key=lambda x: (x.get("city", ""), x.get("address", ""))):
    amenities = ", ".join(p.get("amenities") or [])
    lines.append(
        "| "
        + " | ".join(
            [
                md_escape(p.get("address", "")),
                md_escape(p.get("city", "")),
                md_escape(p.get("state", "")),
                md_escape(p.get("zip", "")),
                md_escape(p.get("property_type", "")),
                md_escape(p.get("starting_rent", "")),
                md_escape(amenities),
                md_escape(p.get("pet_policy", "")),
                md_escape(p.get("url", "")),
            ]
        )
        + " |"
    )
lines.append("")

lines.append("## Unit-Level Availability (Printer-Friendly Feed)")
lines.append("")
lines.append(
    "| Status | Address | City | Size | Vacate Date | Monthly Rent | Annual Parking Fee | Utilities | Laundry | Lease Term | Guarantor | Pets | Description |"
)
lines.append("|---|---|---|---|---|---:|---:|---|---|---|---|---|---|")
for u in unit_rows:
    lines.append(
        "| "
        + " | ".join(
            [
                md_escape(u.get("status", "")),
                md_escape(u.get("address", "")),
                md_escape(u.get("city", "")),
                md_escape(u.get("size", "")),
                md_escape(u.get("vacate_date", "")),
                md_escape(u.get("monthly_rent", "")),
                md_escape(u.get("annual_parking_fee", "")),
                md_escape(u.get("utilities", "")),
                md_escape(u.get("laundry", "")),
                md_escape(u.get("lease_term", "")),
                md_escape(u.get("guarantor", "")),
                md_escape(u.get("pets", "")),
                md_escape(u.get("description", "")),
            ]
        )
        + " |"
    )
lines.append("")

with open(OUT_FILE, "w", encoding="utf-8") as f:
    f.write("\n".join(lines))

print(f"Wrote {OUT_FILE} with {len(properties)} properties and {len(unit_rows)} unit rows")
PY

echo "Done: ${OUT_FILE}"
