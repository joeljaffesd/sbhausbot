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
      if ($0 ~ /^\|[[:space:]]*Address[[:space:]]*\|/) next
      if ($0 ~ /^\|[-[:space:]]+\|[-[:space:]]+\|/) next

      if (NF < 14) next

      address  = esc_tab(trim($2))
      city     = esc_tab(trim($3))
      beds     = esc_tab(trim($4))
      rent     = esc_tab(trim($5))
      deposit  = esc_tab(trim($6))
      avail    = esc_tab(trim($7))
      unittype = esc_tab(trim($8))
      detail   = esc_tab(trim($13))

      if (detail == "") {
        key = address "\t" city "\t" unittype
      } else {
        key = detail
      }

      print key "\t" address "\t" city "\t" beds "\t" rent "\t" deposit "\t" avail "\t" unittype "\t" detail
    }
  ' "$file"
}

tmp_old="$(mktemp)"
tmp_new="$(mktemp)"
trap 'rm -f "$tmp_old" "$tmp_new"' EXIT

extract_rows "$older_file" | sort -u > "$tmp_old"
extract_rows "$newer_file" | sort -u > "$tmp_new"

{
  echo "# Sierrabot Comparison - ${date_stamp}"
  echo
  echo "Compared newer file ${newer_file} against previous file ${older_file}."
  echo
  echo "| Change | Address | City | Beds/Baths | Rent | Security Deposit | Availability | Unit Type | Detail URL |"
  echo "|---|---|---|---|---:|---:|---|---|---|"

  join -t $'\t' -v 2 -1 1 -2 1 "$tmp_old" "$tmp_new" |
  while IFS=$'\t' read -r key address city beds rent deposit avail unittype detail; do
    printf '| Added | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
      "$address" "$city" "$beds" "$rent" "$deposit" "$avail" "$unittype" "$detail"
  done

  join -t $'\t' -v 1 -1 1 -2 1 "$tmp_old" "$tmp_new" |
  while IFS=$'\t' read -r key address city beds rent deposit avail unittype detail; do
    printf '| Removed | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
      "$address" "$city" "$beds" "$rent" "$deposit" "$avail" "$unittype" "$detail"
  done
} > "$out_file"

echo "Wrote ${out_file}"
echo "Compared ${newer_file} vs ${older_file}"
