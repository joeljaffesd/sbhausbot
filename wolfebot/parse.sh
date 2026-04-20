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

for f in "${TMP_DIR}/santa_barbara.md" "${TMP_DIR}/goleta.md" "${TMP_DIR}/detail_manifest.tsv"; do
  if [[ ! -f "$f" ]]; then
    echo "Error: missing required intermediate file: $f" >&2
    exit 1
  fi
done

python3 - "$OUT_FILE" "$TMP_DIR" <<'PY'
import datetime as dt
import re
import sys
from collections import Counter

OUT_FILE = sys.argv[1]
TMP_DIR = sys.argv[2]

SANTA_BARBARA_URL = "https://www.rlwa.com/santa-barbara-listings"
GOLETA_URL = "https://www.rlwa.com/goleta-listings"


def read_text(path: str) -> str:
    with open(path, "r", encoding="utf-8", errors="ignore") as f:
        return f.read()


def md_escape(value: str) -> str:
    v = str(value or "")
    v = v.replace("|", "\\|")
    v = v.replace("\n", " ")
    v = re.sub(r"\s+", " ", v)
    return v.strip()


def normalize_availability(value: str) -> str:
    value = value.strip()
    if not value:
        return ""
    m = re.match(r"(?i)^available\s+\*\*(.*?)\*\*\s*$", value)
    if m:
        return m.group(1).strip()
    m = re.match(r"(?i)^available\s+(.+)$", value)
    if m:
        return m.group(1).strip()
    return value


def listing_uid(url: str) -> str:
    m = re.search(r"/listings/detail/([a-f0-9\-]+)", url, flags=re.IGNORECASE)
    return m.group(1).lower() if m else ""


def parse_detail_titles(manifest_path: str, detail_root: str):
    by_uid = {}

    with open(manifest_path, "r", encoding="utf-8", errors="ignore") as manifest:
        for row in manifest:
            row = row.rstrip("\n")
            if not row:
                continue

            cols = row.split("\t")
            if cols[0] == "ERROR" or len(cols) < 2:
                continue

            file_name, detail_url = cols[0], cols[1]
            uid = listing_uid(detail_url)
            if not uid:
                continue

            detail_path = f"{detail_root}/{file_name}"
            try:
                text = read_text(detail_path)
            except OSError:
                continue

            title = ""
            for line in text.splitlines():
                line = line.strip()
                if line.startswith("Title:"):
                    title = line.split(":", 1)[1].strip()
                    break

            if not title:
                m = re.search(r"(?m)^#\s+(.+)$", text)
                if m:
                    title = m.group(1).strip()

            if title and title.lower() not in {"listings detail", "santa barbara listings", "goleta listings"}:
                by_uid[uid] = title

    return by_uid


def parse_listings(markdown: str, market: str):
    lines = [ln.strip() for ln in markdown.splitlines()]
    out = []

    i = 0
    while i < len(lines):
        line = lines[i]
        if not re.match(r"^###\s*\$", line):
            i += 1
            continue

        rent_match = re.search(r"\$\s*([0-9][0-9,]*)", line)
        rent_value = f"${rent_match.group(1)}" if rent_match else ""
        rent = f"{rent_value} / MONTH" if rent_value else ""

        beds = ""
        baths = ""
        sqft = ""
        availability = ""
        summary_parts = []
        detail_url = ""
        apply_url = ""

        j = i + 1
        while j < len(lines):
            cur = lines[j]

            if re.match(r"^###\s*\$", cur):
                break

            if cur.startswith("[View Details]("):
                m_detail = re.search(r"\[View Details\]\((https?://[^)]+)\)", cur)
                m_apply = re.search(r"\[Apply Now\]\((https?://[^)]+)\)", cur)
                if m_detail:
                    detail_url = m_detail.group(1).rstrip("/")
                if m_apply:
                    apply_url = m_apply.group(1)
                # Listing payload generally ends at links.
                j += 1
                break

            if re.match(r"(?i)^\d+(?:\.\d+)?\s+beds?$", cur) or cur.lower() == "studio":
                beds = cur
            elif re.match(r"(?i)^\d+(?:\.\d+)?\s+baths?$", cur):
                baths = cur
            elif re.match(r"(?i)^\d[\d,]*\s*sqft\.?$", cur):
                sqft = cur.replace(".", "")
            elif re.match(r"(?i)^available\b", cur):
                availability = normalize_availability(cur)
            elif cur in {"/ MONTH", "", "Markdown Content:", "Goleta Listings", "Santa Barbara Listings", "OK"}:
                pass
            elif not cur.startswith("[") and not cur.startswith("*"):
                summary_parts.append(cur)

            j += 1

        if detail_url:
            out.append(
                {
                    "market": market,
                    "rent": rent,
                    "beds": beds,
                    "baths": baths,
                    "sqft": sqft,
                    "availability": availability,
                    "summary": " ".join(summary_parts).strip(),
                    "detail_url": detail_url,
                    "apply_url": apply_url,
                }
            )

        i = max(j, i + 1)

    return out


def split_city(address: str):
    # Prefer city token immediately before trailing "ST ZIP".
    m = re.search(r",\s*([^,]+),\s*[A-Z]{2}\s+\d{5}(?:-\d{4})?\s*$", address)
    if m:
        return m.group(1).strip()

    parts = [p.strip() for p in address.split(",") if p.strip()]
    if len(parts) >= 2:
        return parts[-2]
    return ""


sb_md = read_text(f"{TMP_DIR}/santa_barbara.md")
goleta_md = read_text(f"{TMP_DIR}/goleta.md")

all_rows = []
all_rows.extend(parse_listings(sb_md, "Santa Barbara"))
all_rows.extend(parse_listings(goleta_md, "Goleta"))

uid_to_title = parse_detail_titles(f"{TMP_DIR}/detail_manifest.tsv", f"{TMP_DIR}/details")

for row in all_rows:
    uid = listing_uid(row["detail_url"])
    address = uid_to_title.get(uid, "")
    row["address"] = address
    row["city"] = split_city(address)
    if row["beds"] and row["baths"]:
        row["beds_baths"] = f"{row['beds']} / {row['baths']}"
    else:
        row["beds_baths"] = row["beds"] or row["baths"]

# Deduplicate by detail URL (same listing can occasionally repeat in feeds).
seen = set()
uniq_rows = []
for row in all_rows:
    key = row["detail_url"]
    if key in seen:
        continue
    seen.add(key)
    uniq_rows.append(row)

all_rows = sorted(
    uniq_rows,
    key=lambda r: (
        r.get("market", ""),
        r.get("city", ""),
        r.get("address", ""),
        r.get("rent", ""),
    ),
)

market_counts = Counter(r["market"] for r in all_rows)
min_rent_num = None
max_rent_num = None
for r in all_rows:
    m = re.search(r"\$([0-9,]+)", r.get("rent", ""))
    if not m:
        continue
    val = int(m.group(1).replace(",", ""))
    min_rent_num = val if min_rent_num is None else min(min_rent_num, val)
    max_rent_num = val if max_rent_num is None else max(max_rent_num, val)

generated_at = dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")

lines = []
lines.append(f"# Wolfe Listings Report ({OUT_FILE.replace('.md', '')})")
lines.append("")
lines.append(f"Generated at: {generated_at}")
lines.append("")
lines.append("## Sources")
lines.append("")
lines.append(f"- {SANTA_BARBARA_URL}")
lines.append(f"- {GOLETA_URL}")
lines.append("")
lines.append("## Snapshot")
lines.append("")
lines.append(f"- Total active listings captured: {len(all_rows)}")
lines.append(f"- Santa Barbara listings captured: {market_counts.get('Santa Barbara', 0)}")
lines.append(f"- Goleta listings captured: {market_counts.get('Goleta', 0)}")
if min_rent_num is not None and max_rent_num is not None:
    lines.append(f"- Rent range in captured listings: ${min_rent_num:,.0f} to ${max_rent_num:,.0f}")
if market_counts.get("Goleta", 0) == 0:
    lines.append("- Goleta page currently shows no available listings.")
lines.append("")

lines.append("## Combined Listings")
lines.append("")
lines.append("| Market | Address | City | Beds/Baths | Rent | Availability | SqFt | Summary | Detail URL | Apply URL |")
lines.append("|---|---|---|---|---:|---|---:|---|---|---|")
for r in all_rows:
    lines.append(
        "| "
        + " | ".join(
            [
                md_escape(r.get("market", "")),
                md_escape(r.get("address", "")),
                md_escape(r.get("city", "")),
                md_escape(r.get("beds_baths", "")),
                md_escape(r.get("rent", "")),
                md_escape(r.get("availability", "")),
                md_escape(r.get("sqft", "")),
                md_escape(r.get("summary", "")),
                md_escape(r.get("detail_url", "")),
                md_escape(r.get("apply_url", "")),
            ]
        )
        + " |"
    )
lines.append("")

with open(OUT_FILE, "w", encoding="utf-8") as f:
    f.write("\n".join(lines))

print(f"Wrote {OUT_FILE} with {len(all_rows)} listings")
PY

echo "Done: ${OUT_FILE}"