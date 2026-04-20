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

    /^\|/ {
      # Skip header and separator rows.
      if ($0 ~ /^\|[[:space:]]*Location[[:space:]]*\|/) next
      if ($0 ~ /^\|[-[:space:]]+\|[-[:space:]]+\|[-:[:space:]]+\|/) next

      if (NF < 8) next

      location = esc_tab(trim($2))
      beds     = esc_tab(trim($3))
      rent     = esc_tab(trim($4))
      avail    = esc_tab(trim($5))
      util     = esc_tab(trim($6))
      other    = esc_tab(trim($7))

      if (location == "") next

      # Emit: key + full row payload, tab-delimited for stable joins.
      print location "\t" beds "\t" rent "\t" avail "\t" util "\t" other
    }
  ' "$file"
}

tmp_old="$(mktemp)"
tmp_new="$(mktemp)"
trap 'rm -f "$tmp_old" "$tmp_new"' EXIT

extract_rows "$older_file" | sort -u > "$tmp_old"
extract_rows "$newer_file" | sort -u > "$tmp_new"

{
  echo "# Property Comparison - ${date_stamp}"
  echo
  echo "Compared newer file ${newer_file} against previous file ${older_file}."
  echo
  echo "| Change | Location | Beds/Baths | Net Rent | avail | util paid | other info |"
  echo "|---|---|---|---:|---|---|---|"

  # Added in newer (present in new, absent in old by location key).
  join -t $'\t' -v 2 -1 1 -2 1 "$tmp_old" "$tmp_new" |
  while IFS=$'\t' read -r location beds rent avail util other; do
    printf '| Added | %s | %s | %s | %s | %s | %s |\n' \
      "$location" "$beds" "$rent" "$avail" "$util" "$other"
  done

  # Removed from newer (present in old, absent in new by location key).
  join -t $'\t' -v 1 -1 1 -2 1 "$tmp_old" "$tmp_new" |
  while IFS=$'\t' read -r location beds rent avail util other; do
    printf '| Removed | %s | %s | %s | %s | %s | %s |\n' \
      "$location" "$beds" "$rent" "$avail" "$util" "$other"
  done
} > "$out_file"

echo "Wrote ${out_file}"
echo "Compared ${newer_file} vs ${older_file}"