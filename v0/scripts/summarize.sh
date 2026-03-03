#!/usr/bin/env bash
set -euo pipefail

RUN_DIR="${1:?Usage: summarize.sh <run-dir>}"

PHASES_FILE="$RUN_DIR/phases.jsonl"
SUMMARY_FILE="$RUN_DIR/summary.csv"

if [ ! -f "$PHASES_FILE" ]; then
  echo "No phases.jsonl found in $RUN_DIR — nothing to summarize."
  exit 0
fi

echo "phase,uuid,exit_code,start_epoch,end_epoch,elapsed_seconds,status" > "$SUMMARY_FILE"

while IFS= read -r line; do
  phase=$(echo "$line"  | sed -n 's/.*"phase":"\([^"]*\)".*/\1/p')
  uuid=$(echo "$line"   | sed -n 's/.*"uuid":"\([^"]*\)".*/\1/p')
  rc=$(echo "$line"     | sed -n 's/.*"rc":\([0-9]*\).*/\1/p')
  start=$(echo "$line"  | sed -n 's/.*"start":\([0-9]*\).*/\1/p')
  end_t=$(echo "$line"  | sed -n 's/.*"end":\([0-9]*\).*/\1/p')
  elapsed=$(echo "$line" | sed -n 's/.*"elapsed_s":\([0-9]*\).*/\1/p')
  if [ "$rc" = "0" ]; then status="pass"; else status="fail"; fi
  echo "${phase},${uuid},${rc},${start},${end_t},${elapsed},${status}" >> "$SUMMARY_FILE"
done < "$PHASES_FILE"

echo "Summary written to $SUMMARY_FILE"
