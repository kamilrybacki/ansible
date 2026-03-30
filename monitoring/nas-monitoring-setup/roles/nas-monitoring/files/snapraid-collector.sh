#!/bin/bash
# SnapRAID metrics for Prometheus textfile collector
# Outputs .prom files for Alloy to pick up via prometheus.exporter.unix textfile_directory
set -euo pipefail

OUTPUT_DIR="${1:-/opt/nas-monitoring/textfile}"
TEMP_FILE=$(mktemp)
trap "rm -f $TEMP_FILE" EXIT

{
  echo "# HELP snapraid_disk_fail_probability Annual disk failure probability from SMART data"
  echo "# TYPE snapraid_disk_fail_probability gauge"

  snapraid smart 2>/dev/null | grep -E '^\s+[0-9]+%' | while read -r line; do
    pct=$(echo "$line" | awk '{print $1}' | tr -d '%')
    disk=$(echo "$line" | awk '{print $NF}')
    echo "snapraid_disk_fail_probability{disk=\"$disk\"} $(echo "scale=4; $pct / 100" | bc)"
  done

  echo "# HELP snapraid_sync_age_seconds Seconds since last successful sync"
  echo "# TYPE snapraid_sync_age_seconds gauge"
  sync_log="/var/log/snapraid-sync.log"
  if [ -f "$sync_log" ]; then
    sync_time=$(stat -c %Y "$sync_log")
    now=$(date +%s)
    echo "snapraid_sync_age_seconds $((now - sync_time))"
  fi

  echo "# HELP snapraid_scrub_age_seconds Seconds since last successful scrub"
  echo "# TYPE snapraid_scrub_age_seconds gauge"
  scrub_log="/var/log/snapraid-scrub.log"
  if [ -f "$scrub_log" ]; then
    scrub_time=$(stat -c %Y "$scrub_log")
    now=$(date +%s)
    echo "snapraid_scrub_age_seconds $((now - scrub_time))"
  fi
} > "$TEMP_FILE"

mv "$TEMP_FILE" "$OUTPUT_DIR/snapraid.prom"
