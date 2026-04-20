#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 /path/to/file.pdf" >&2
  exit 1
fi

PDF_PATH="$1"

if [[ ! -f "$PDF_PATH" ]]; then
  echo "Error: PDF not found: $PDF_PATH" >&2
  exit 1
fi

for cmd in pdftoppm tesseract; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: required command not found: $cmd" >&2
    exit 1
  fi
done

output_dir="output"
mkdir -p "$output_dir"

pdf_base="$(basename "$PDF_PATH")"
pdf_base="${pdf_base%.*}"
safe_base="$(printf '%s' "$pdf_base" | tr ' /' '__' | tr -cd 'A-Za-z0-9._-')"
tmp_dir="$output_dir/${safe_base}_intermediate"

# Recreate intermediates on each run so output/ always matches the latest parse.
rm -rf "$tmp_dir"
mkdir -p "$tmp_dir"

# Render each PDF page to PNG, then OCR all pages into one text file.
pdftoppm -png -r 300 "$PDF_PATH" "$tmp_dir/page" >/dev/null
for img in "$tmp_dir"/page-*.png; do
  tesseract "$img" stdout 2>/dev/null
  echo
done > "$tmp_dir/ocr.txt"

raw_date="$(grep -Eo '(January|February|March|April|May|June|July|August|September|October|November|December)[[:space:]]+[0-9]{1,2},[[:space:]]+[0-9]{4}' "$tmp_dir/ocr.txt" | head -n 1 || true)"

# Output filename is always based on current system date.
file_date="$(date +%Y-%m-%d)"

output_file="$file_date.md"

{
  echo "# Rental List - ${raw_date:-$file_date}"
  echo
  echo "| Location | Beds/Baths | Net Rent | avail | util paid | other info |"
  echo "|---|---|---:|---|---|---|"

  awk '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    function esc(s)  { gsub(/\|/, "\\|", s); return s }

    {
      line = $0
      gsub(/\r/, "", line)
      line = trim(line)
      gsub(/^[.]+[[:space:]]*/, "", line)

      if (line == "") next

      # Skip header/footer/noise lines.
      if (line ~ /RENTAL LIST|BEDS \/|LOCATION BATHS|UTILITIES KEY|^NOTE:|Copyright|Suite 200|Fax:|www\.|\(OVER\)|All Rights Reserved/) next

      # Track section headings to preserve city/property-type context.
      if (line ~ /--/ && line !~ /[[:space:]]Now[[:space:]]/ && line ~ /(House|Apartment|Condo|Cottage|Duplex|Office)/) {
        section = line
        gsub(/[[:space:]]+[_:]+[[:space:]]*$/, "", section)
        if (section ~ /House/) sub(/House.*/, "House", section)
        else if (section ~ /Apartment/) sub(/Apartment.*/, "Apartment", section)
        else if (section ~ /Condo/) sub(/Condo.*/, "Condo", section)
        else if (section ~ /Cottage/) sub(/Cottage.*/, "Cottage", section)
        else if (section ~ /Duplex/) sub(/Duplex.*/, "Duplex", section)
        else if (section ~ /Office/) sub(/Office.*/, "Office", section)
        section = trim(section)
        next
      }

      if (line !~ /[[:space:]]Now[[:space:]]/) next

      n_parts = split(line, parts, /[[:space:]]+Now[[:space:]]+/)
      if (n_parts < 2) next

      left = trim(parts[1])
      right = trim(parts[2])

      location = left
      beds = ""
      rent = ""
      avail = "Now"

      # Portable parse from right-most tokens:
      # 1) last token must be rent like 2,495
      # 2) previous token may be beds/baths like 1/1 or S/1
      n_toks = split(left, ltoks, /[[:space:]]+/)
      if (n_toks < 2) next

      rent = ltoks[n_toks]
      if (rent !~ /^[0-9],[0-9][0-9][0-9]$/) next

      loc_end = n_toks - 1
      candidate_beds = ltoks[n_toks - 1]
      if (candidate_beds ~ /^[A-Za-z0-9$.]+\/[A-Za-z0-9.]+$/) {
        beds = candidate_beds
        loc_end = n_toks - 2
      }

      if (loc_end < 1) next
      location = ltoks[1]
      for (i = 2; i <= loc_end; i++) {
        location = location " " ltoks[i]
      }
      location = trim(location)
      gsub(/[;~|]+$/, "", location)
      location = trim(location)

      util = ""
      other = ""
      split(right, rtoks, /[[:space:]]+/)
      util = trim(rtoks[1])
      sub(/^[^[:space:]]+[[:space:]]*/, "", right)
      other = trim(right)
      gsub(/[[:space:]]+/, " ", other)

      # Keep util paid meaningful; avoid OCR words (for example "Approx").
      if (util !~ /^(none|all|nnn|[wtegc\/]{1,5}|wit|wig|wtg)$/) {
        other = trim(util " " other)
        util = ""
      }

      full_location = location
      if (section != "") full_location = section " / " location

      print "| " esc(full_location) " | " esc(beds) " | " esc(rent) " | " esc(avail) " | " esc(util) " | " esc(other) " |"
    }
  ' "$tmp_dir/ocr.txt"
} > "$output_file"

echo "Wrote $output_file"
echo "Intermediates in $tmp_dir"
