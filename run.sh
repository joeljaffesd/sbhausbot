#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

OUT_DATE="$(date +%F)"
RECIPIENT=""
DRY_RUN=""

ARG1="${1:-}"
ARG2="${2:-}"
ARG3="${3:-}"

if [[ "$ARG1" == "--help" || "$ARG1" == "-h" ]]; then
  cat <<'USAGE'
Usage: ./run.sh [recipient] [--dry-run]

Runs all rental bots, collects each bot's report in dry-run mode,
and sends one consolidated iMessage.

Defaults:
  date:      system date
  recipient: none (required unless --dry-run)
USAGE
  exit 0
fi

if [[ -n "$ARG3" ]]; then
  echo "Usage: $0 [recipient] [--dry-run]" >&2
  exit 1
fi

if [[ -n "$ARG1" ]]; then
  if [[ "$ARG1" == "--dry-run" ]]; then
    DRY_RUN="--dry-run"
  else
    RECIPIENT="$ARG1"
  fi
fi

if [[ -n "$ARG2" ]]; then
  if [[ "$ARG2" == "--dry-run" ]]; then
    DRY_RUN="--dry-run"
  else
    echo "Usage: $0 [recipient] [--dry-run]" >&2
    exit 1
  fi
fi

if [[ "$DRY_RUN" != "--dry-run" && -z "$RECIPIENT" ]]; then
  echo "Error: recipient is required unless --dry-run is set." >&2
  echo "Usage: $0 [recipient] [--dry-run]" >&2
  exit 1
fi

# Report scripts require a non-empty recipient even in dry-run mode.
INTERNAL_RECIPIENT="${RECIPIENT:-__dry_run__}"

BOTS=(bartbot meribot sandpiperbot sierrabot wolfebot)

run_bot() {
  local bot="$1"
  local bot_dir="${SCRIPT_DIR}/${bot}"
  local bot_runner="${bot_dir}/run.sh"

  if [[ ! -d "$bot_dir" ]]; then
    echo "Error: missing bot directory: $bot_dir" >&2
    exit 1
  fi

  if [[ ! -x "$bot_runner" ]]; then
    echo "Error: missing executable bot runner: $bot_runner" >&2
    exit 1
  fi

  echo "Running ${bot}..."
  if ! (cd "$bot_dir" && ./run.sh); then
    echo "Error: ${bot} run failed; aborting consolidated run." >&2
    exit 1
  fi
}

collect_bot_report() {
  local bot="$1"
  local bot_dir="${SCRIPT_DIR}/${bot}"

  if [[ ! -x "${bot_dir}/report.sh" ]]; then
    echo "Error: missing executable report script for ${bot}: ${bot_dir}/report.sh" >&2
    exit 1
  fi

  # Use each bot's existing formatter, but keep it local by forcing dry-run.
  (cd "$bot_dir" && ./report.sh "$INTERNAL_RECIPIENT" --dry-run)
}

for bot in "${BOTS[@]}"; do
  run_bot "$bot"
done

sections=()
for bot in "${BOTS[@]}"; do
  report_text="$(collect_bot_report "$bot")"
  sections+=("${report_text}")
done

MESSAGE="Hausbot consolidated rental update: ${OUT_DATE}

$(printf '%s

' "${sections[@]}")"

if [[ "$DRY_RUN" == "--dry-run" ]]; then
  printf '%s\n' "$MESSAGE"
  exit 0
fi

osascript - "$RECIPIENT" "$MESSAGE" <<'EOF'
on run argv
  set recipient to item 1 of argv
  set msg to item 2 of argv

  tell application "Messages"
    set svc to first service whose service type is iMessage
    set b to buddy recipient of svc
    send msg to b
  end tell
end run
EOF

echo "Sent consolidated Hausbot update to ${RECIPIENT}"