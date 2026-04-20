#!/usr/bin/env bash
set -euo pipefail

date_stamp="$(date +%Y-%m-%d)"
newer_file="${date_stamp}.md"
out_file="${date_stamp}_comp.md"

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

    /^## Combined Listings/ { in_rows=1; next }
    in_rows && /^## / { in_rows=0 }

    in_rows && /^\|/ {
      if ($0 ~ /^\|[[:space:]]*Listing ID[[:space:]]*\|/) next
      if ($0 ~ /^\|[-[:space:]]+\|[-[:space:]]+\|/) next

      if (NF < 15) next

      listing_id = esc_tab(trim($2))
      address    = esc_tab(trim($3))
      city       = esc_tab(trim($4))
      beds       = esc_tab(trim($5))
      rent       = esc_tab(trim($6))
      deposit    = esc_tab(trim($7))
      avail      = esc_tab(trim($8))
      ptype      = esc_tab(trim($9))
      detail     = esc_tab(trim($14))

      if (detail == "") {
        key = listing_id
      } else {
        key = detail
      }

      print key "\t" listing_id "\t" address "\t" city "\t" beds "\t" rent "\t" deposit "\t" avail "\t" ptype "\t" detail
    }
  ' "$file"
}

tmp_old="$(mktemp)"
tmp_new="$(mktemp)"
trap 'rm -f "$tmp_old" "$tmp_new"' EXIT

extract_rows "$older_file" | sort -u > "$tmp_old"
extract_rows "$newer_file" | sort -u > "$tmp_new"

{
  echo "# Sandpiperbot Comparison - ${date_stamp}"
  echo
  echo "Compared newer file ${newer_file} against previous file ${older_file}."
  echo
  echo "| Change | Listing ID | Address | City | Beds/Baths | Rent | Security Deposit | Availability | Type | Detail URL |"
  echo "|---|---|---|---|---|---:|---:|---|---|---|"

  join -t $'\t' -v 2 -1 1 -2 1 "$tmp_old" "$tmp_new" |
  while IFS=$'\t' read -r key listing_id address city beds rent deposit avail ptype detail; do
    printf '| Added | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
      "$listing_id" "$address" "$city" "$beds" "$rent" "$deposit" "$avail" "$ptype" "$detail"
  done

  join -t $'\t' -v 1 -1 1 -2 1 "$tmp_old" "$tmp_new" |
  while IFS=$'\t' read -r key listing_id address city beds rent deposit avail ptype detail; do
    printf '| Removed | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
      "$listing_id" "$address" "$city" "$beds" "$rent" "$deposit" "$avail" "$ptype" "$detail"
  done
} > "$out_file"

echo "Wrote ${out_file}"
echo "Compared ${newer_file} vs ${older_file}"
