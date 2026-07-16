#!/bin/bash
# Monitor SoniqueBar macOS backend logs in real-time

set -e

LOG_FILE="${1:-/tmp/soniquebar-$(date +%Y%m%d-%H%M%S).log}"

echo "🔍 Monitoring SoniqueBar on macOS"
echo "📝 Logging to: $LOG_FILE"
echo "🎯 Subsystem: com.seayniclabs.soniquebar"
echo ""
echo "Press Ctrl+C to stop"
echo "---"

# Stream logs with color
log stream \
  --predicate 'subsystem == "com.seayniclabs.soniquebar"' \
  --style compact \
  --color always \
  2>&1 | tee "$LOG_FILE"
