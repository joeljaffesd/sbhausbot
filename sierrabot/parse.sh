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

if [[ ! -f "${TMP_DIR}/residential.html" ]]; then
  echo "Error: missing required intermediate file: ${TMP_DIR}/residential.html" >&2
  exit 1
fi

python3 - "$OUT_FILE" "$TMP_DIR" <<'PY'
import datetime as dt
import html
import re
import sys
from collections import Counter

OUT_FILE = sys.argv[1]
TMP_DIR = sys.argv[2]
SOURCE_URL = "https://sierrapropsb.com/residential/"


def read_text(path: str) -> str:
    with open(path, "r", encoding="utf-8", errors="ignore") as f:
        return f.read()


def md_escape(value: str) -> str:
    v = str(value or "")
    v = v.replace("|", "\\|")
    v = v.replace("\n", " ")
    v = re.sub(r"\s+", " ", v)
    return v.strip()


def strip_tags(value: str) -> str:
    text = re.sub(r"(?is)<script.*?</script>|<style.*?</style>", " ", value)
    text = re.sub(r"(?i)<br\s*/?>", "\n", text)
    text = re.sub(r"(?i)</p>|</li>|</div>|</h[1-6]>", "\n", text)
    text = re.sub(r"(?s)<[^>]+>", " ", text)
    text = html.unescape(text)
    text = text.replace("\xa0", " ")
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r"\n\s*\n+", "\n", text)
    return text.strip()


def clean_text(value: str) -> str:
    return re.sub(r"\s+", " ", strip_tags(value)).strip()


def decode_attr(value: str) -> str:
    return html.unescape(value or "").strip()


def extract_sentences(text: str, tokens):
    parts = re.split(r"(?<=[.!?])\s+", text)
    hits = []
    for sentence in parts:
        s = sentence.strip()
        if not s:
            continue
        lo = s.lower()
        if any(tok in lo for tok in tokens):
            hits.append(s)
    return " ".join(hits)


def parse_city_state_zip(raw_address: str):
    address = decode_attr(raw_address)
    address = re.sub(r"\s+", " ", address)

    m = re.match(r"^(.*?)\s+([^,]+),\s*([A-Z]{2})\s+(\d{5})(?:-\d{4})?$", address)
    if m:
        return m.group(1).strip(), m.group(2).strip(), m.group(3).strip(), m.group(4).strip()

    m2 = re.match(r"^(.*?),\s*([^,]+),\s*([A-Z]{2})\s+(\d{5})(?:-\d{4})?$", address)
    if m2:
        return m2.group(1).strip(), m2.group(2).strip(), m2.group(3).strip(), m2.group(4).strip()

    return address, "", "", ""


def parse_csz(raw_csz: str):
    csz = decode_attr(raw_csz)
    m = re.match(r"^([^,]+),\s*([A-Z]{2})\s+(\d{5})(?:-\d{4})?$", csz)
    if m:
        return m.group(1).strip(), m.group(2).strip(), m.group(3).strip()
    return "", "", ""


def parse_unit_type(unit_type: str):
    if not unit_type:
        return "", ""
    bed_m = re.search(r"([0-9]+(?:\.[0-9]+)?)\s*bed", unit_type, flags=re.IGNORECASE)
    bath_m = re.search(r"([0-9]+(?:\.[0-9]+)?)\s*bath", unit_type, flags=re.IGNORECASE)
    return (bed_m.group(1) if bed_m else "", bath_m.group(1) if bath_m else "")


html_text = read_text(f"{TMP_DIR}/residential.html")
chunks = html_text.split('<div class="rmwb_listing-wrapper')
listings = []

for raw_chunk in chunks[1:]:
    chunk = '<div class="rmwb_listing-wrapper' + raw_chunk

    title_m = re.search(r"<h2>\s*(.*?)\s*</h2>", chunk, flags=re.IGNORECASE | re.DOTALL)
    title = clean_text(title_m.group(1)) if title_m else ""

    data_address_m = re.search(r'data-address="(.*?)"', chunk, flags=re.IGNORECASE)
    data_address = decode_attr(data_address_m.group(1)) if data_address_m else ""
    data_csz_m = re.search(r'data-csz="(.*?)"', chunk, flags=re.IGNORECASE)
    data_csz = decode_attr(data_csz_m.group(1)) if data_csz_m else ""

    detail_href_m = re.search(
        r'href="(/unit/\?uid=[0-9]+&#038;locationid=1&#038;type=Residential)"',
        chunk,
        flags=re.IGNORECASE,
    )
    detail_url = "https://sierrapropsb.com" + html.unescape(detail_href_m.group(1)) if detail_href_m else ""

    apply_href_m = re.search(
        r'href="(https://sbspm\.twa\.rentmanager\.com/ApplyNow\?[^"]+)"',
        chunk,
        flags=re.IGNORECASE,
    )
    apply_url = html.unescape(apply_href_m.group(1)) if apply_href_m else ""

    desc_m = re.search(r'<p class="rmwb_description">(.*?)</p>', chunk, flags=re.IGNORECASE | re.DOTALL)
    description = clean_text(desc_m.group(1)) if desc_m else ""

    info = {}
    for m in re.finditer(
        r'<li>\s*<span class="rmwb_info-title[^"]*">\s*(.*?)\s*</span>\s*<span class="rmwb_info-detail">\s*(.*?)\s*</span>',
        chunk,
        flags=re.IGNORECASE | re.DOTALL,
    ):
        label = clean_text(m.group(1)).rstrip(":").lower()
        value = clean_text(m.group(2))
        if label:
            info[label] = value

    availability = info.get("available", "")
    unit_type = info.get("unit type", "")
    bedrooms = info.get("bedrooms", "")
    bathrooms = info.get("bathrooms", "")
    rent = info.get("rent", "")
    deposit = info.get("security deposit", "")
    zip_code = info.get("zip code", "")

    if (not bedrooms or not bathrooms) and unit_type:
        beds_from_type, baths_from_type = parse_unit_type(unit_type)
        if not bedrooms:
            bedrooms = beds_from_type
        if not bathrooms:
            bathrooms = baths_from_type

    if not title and not data_address:
        continue

    street, city, state, parsed_zip = parse_city_state_zip(data_address)
    csz_city, csz_state, csz_zip = parse_csz(data_csz)
    if csz_city:
        city = csz_city
    if csz_state:
        state = csz_state
    if csz_zip:
        zip_code = csz_zip
    elif not zip_code:
        zip_code = parsed_zip

    if title:
        street = title

    beds_baths = ""
    if bedrooms or bathrooms:
        beds_baths = f"{bedrooms}/{bathrooms}".strip("/")

    utility_notes = extract_sentences(
        description,
        ["water", "trash", "electric", "gas", "utilities", "included", "tenant pays"],
    )
    parking_laundry = extract_sentences(
        description,
        ["parking", "carport", "laundry", "washer", "dryer", "garage", "storage"],
    )
    restrictions = extract_sentences(
        description,
        ["no pets", "pets", "no smoking", "smoking", "co-signer", "guarantor", "lease"],
    )

    summary = description
    if len(summary) > 240:
        summary = summary[:237].rstrip() + "..."

    listings.append(
        {
            "title": title,
            "street": street,
            "city": city,
            "state": state,
            "zip": zip_code,
            "beds_baths": beds_baths,
            "rent": rent,
            "security_deposit": deposit,
            "availability": availability,
            "unit_type": unit_type,
            "utilities": utility_notes,
            "parking_laundry": parking_laundry,
            "restrictions": restrictions,
            "summary": summary,
            "detail_url": detail_url,
            "apply_url": apply_url,
        }
    )

seen = set()
uniq = []
for row in listings:
    key = row["detail_url"] or f"{row['title']}::{row['street']}"
    if key in seen:
        continue
    seen.add(key)
    uniq.append(row)

listings = sorted(
    uniq,
    key=lambda r: (
        r.get("city", ""),
        r.get("street", ""),
        r.get("unit_type", ""),
        r.get("rent", ""),
    ),
)

rent_values = []
for row in listings:
    m = re.search(r"([0-9][0-9,]*(?:\.[0-9]+)?)", row.get("rent", ""))
    if m:
        rent_values.append(float(m.group(1).replace(",", "")))

city_counts = Counter(row.get("city", "") for row in listings if row.get("city"))

office_info = {
    "address": "",
    "office_phone": "",
    "iv_leasing": "",
    "after_hours": "",
    "fax": "",
    "hours": "",
    "email": "",
    "iv_email": "",
}

address_m = re.search(r"<span>\s*(5290\s+Overpass\s+Road,\s*Bldg\.\s*C.*?)\s*</span>", html_text, flags=re.IGNORECASE)
if address_m:
    office_info["address"] = clean_text(address_m.group(1))

office_phone_m = re.search(r"Office\s*:\s*</span>\s*<a[^>]*>\s*([^<]+)\s*</a>", html_text, flags=re.IGNORECASE)
if office_phone_m:
    office_info["office_phone"] = clean_text(office_phone_m.group(1))

iv_phone_m = re.search(r"IV Leasing Questions\s*:\s*</span>\s*<a[^>]*>\s*([^<]+)\s*</a>", html_text, flags=re.IGNORECASE)
if iv_phone_m:
    office_info["iv_leasing"] = clean_text(iv_phone_m.group(1))

after_hours_m = re.search(r"After Hours Emergency Phone\s*:\s*</span>\s*<a[^>]*>\s*([^<]+)\s*</a>", html_text, flags=re.IGNORECASE)
if after_hours_m:
    office_info["after_hours"] = clean_text(after_hours_m.group(1))

fax_m = re.search(r"Fax\s*:\s*</span>\s*<a[^>]*>\s*([^<]+)\s*</a>", html_text, flags=re.IGNORECASE)
if fax_m:
    office_info["fax"] = clean_text(fax_m.group(1))

hours_m = re.search(r"Monday through Friday[^<]+", html_text, flags=re.IGNORECASE)
if hours_m:
    office_info["hours"] = clean_text(hours_m.group(0))

if re.search(r"mailto:spm@sierrapropsb\.com", html_text, flags=re.IGNORECASE):
    office_info["email"] = "spm@sierrapropsb.com"

if re.search(r"leasing@sierrapropsb\.com", html_text, flags=re.IGNORECASE):
    office_info["iv_email"] = "leasing@sierrapropsb.com"

now = dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
lines = []
lines.append(f"# Sierra Listings Report ({OUT_FILE.replace('.md', '')})")
lines.append("")
lines.append(f"Generated at: {now}")
lines.append("")
lines.append("## Sources")
lines.append("")
lines.append(f"- {SOURCE_URL}")
lines.append("")
lines.append("## Snapshot")
lines.append("")
lines.append(f"- Total active listings captured: {len(listings)}")
if rent_values:
    lines.append(f"- Rent range in captured listings: ${min(rent_values):,.0f} to ${max(rent_values):,.0f}")
if city_counts:
    lines.append("- Cities represented: " + ", ".join(f"{c} ({n})" for c, n in city_counts.most_common()))
lines.append("")

lines.append("## Combined Listings")
lines.append("")
lines.append("| Address | City | Beds/Baths | Rent | Security Deposit | Availability | Unit Type | Utilities | Parking/Laundry | Restrictions | Summary | Detail URL | Apply URL |")
lines.append("|---|---|---|---:|---:|---|---|---|---|---|---|---|---|")
for row in listings:
    address_display = row.get("street") or row.get("title", "")
    lines.append(
        "| "
        + " | ".join(
            [
                md_escape(address_display),
                md_escape(row.get("city", "")),
                md_escape(row.get("beds_baths", "")),
                md_escape(row.get("rent", "")),
                md_escape(row.get("security_deposit", "")),
                md_escape(row.get("availability", "")),
                md_escape(row.get("unit_type", "")),
                md_escape(row.get("utilities", "")),
                md_escape(row.get("parking_laundry", "")),
                md_escape(row.get("restrictions", "")),
                md_escape(row.get("summary", "")),
                md_escape(row.get("detail_url", "")),
                md_escape(row.get("apply_url", "")),
            ]
        )
        + " |"
    )
lines.append("")

lines.append("## Office Contact")
lines.append("")
lines.append("| Field | Value |")
lines.append("|---|---|")
for key, label in [
    ("address", "Address"),
    ("office_phone", "Office Phone"),
    ("iv_leasing", "IV Leasing Phone"),
    ("after_hours", "After Hours Emergency"),
    ("fax", "Fax"),
    ("hours", "Hours"),
    ("email", "General Email"),
    ("iv_email", "IV Leasing Email"),
]:
    lines.append(f"| {label} | {md_escape(office_info.get(key, ''))} |")
lines.append("")

with open(OUT_FILE, "w", encoding="utf-8") as f:
    f.write("\n".join(lines))

print(f"Wrote {OUT_FILE} with {len(listings)} listings")
PY

echo "Done: ${OUT_FILE}"
