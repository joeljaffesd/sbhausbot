#!/usr/bin/env bash
set -euo pipefail

date_stamp="$(date +%Y-%m-%d)"
out_file="${date_stamp}_comp.md"

newer_file="${date_stamp}.md"
if [[ ! -f "$newer_file" ]]; then
  echo "Error: missing today's report file: ${newer_file}" >&2
  echo "Run parse for today's live postings first." >&2
  exit 1
fi

older_file="$(ls -1t ./*.md 2>/dev/null | sed 's|^\./||' | grep -Ev '_comp\.md$' | grep -vx "${newer_file}" | head -n1 || true)"

if [[ -z "$older_file" ]]; then
  echo "Error: need at least one prior non-comparison .md file to compare against ${newer_file}." >&2
  exit 1
fi

extract_rows() {
  local file="$1"
  awk -F'|' '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    function esc_tab(s) { gsub(/\t/, " ", s); return s }

    /^## Unit-Level Availability \(Printer-Friendly Feed\)/ { in_units=1; next }
    in_units && /^## / { in_units=0 }

    in_units && /^\|/ {
      if ($0 ~ /^\|[[:space:]]*Status[[:space:]]*\|/) next
      if ($0 ~ /^\|[-[:space:]]+\|[-[:space:]]+\|/) next

      if (NF < 15) next

      status      = esc_tab(trim($2))
      address     = esc_tab(trim($3))
      city        = esc_tab(trim($4))
      size        = esc_tab(trim($5))
      vacate      = esc_tab(trim($6))
      rent        = esc_tab(trim($7))
      parking_fee = esc_tab(trim($8))
      utilities   = esc_tab(trim($9))
      laundry     = esc_tab(trim($10))
      lease_term  = esc_tab(trim($11))
      guarantor   = esc_tab(trim($12))
      pets        = esc_tab(trim($13))
      desc        = esc_tab(trim($14))

      if (address == "") next

      key = address "\t" city "\t" size "\t" rent
      print key "\t" status "\t" vacate "\t" parking_fee "\t" utilities "\t" laundry "\t" lease_term "\t" guarantor "\t" pets "\t" desc
    }
  ' "$file"
}

tmp_old="$(mktemp)"
tmp_new="$(mktemp)"
trap 'rm -f "$tmp_old" "$tmp_new"' EXIT

extract_rows "$older_file" | sort -u > "$tmp_old"
extract_rows "$newer_file" | sort -u > "$tmp_new"

{
  echo "# Meribot Comparison - ${date_stamp}"
  echo
  echo "Compared newer file ${newer_file} against previous file ${older_file}."
  echo
  echo "| Change | Address | City | Size | Monthly Rent | Status | Vacate Date | Annual Parking Fee | Utilities | Laundry | Lease Term | Guarantor | Pets | Description |"
  echo "|---|---|---|---|---:|---|---|---:|---|---|---|---|---|---|"

  join -t $'\t' -v 2 -1 1 -2 1 "$tmp_old" "$tmp_new" |
  while IFS=$'\t' read -r address city size rent status vacate parking_fee utilities laundry lease_term guarantor pets desc; do
    printf '| Added | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
      "$address" "$city" "$size" "$rent" "$status" "$vacate" "$parking_fee" "$utilities" "$laundry" "$lease_term" "$guarantor" "$pets" "$desc"
  done

  join -t $'\t' -v 1 -1 1 -2 1 "$tmp_old" "$tmp_new" |
  while IFS=$'\t' read -r address city size rent status vacate parking_fee utilities laundry lease_term guarantor pets desc; do
    printf '| Removed | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
      "$address" "$city" "$size" "$rent" "$status" "$vacate" "$parking_fee" "$utilities" "$laundry" "$lease_term" "$guarantor" "$pets" "$desc"
  done
} > "$out_file"

echo "Wrote ${out_file}"
echo "Compared ${newer_file} vs ${older_file}"
