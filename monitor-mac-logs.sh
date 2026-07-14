#!/bin/bash
# Monitor SoniqueBar logs from Mac Mini in real-time

LOG_DIR="$HOME/Library/Logs/SoniqueBar"
STDOUT_LOG="$LOG_DIR/stdout.log"
STDERR_LOG="$LOG_DIR/stderr.log"

echo "=== Monitoring SoniqueBar logs from Mac Mini ==="
echo "STDOUT: $STDOUT_LOG"
echo "STDERR: $STDERR_LOG"
echo "Press Ctrl+C to stop"
echo ""

# Check SoniqueBar is running
if ! ps aux | grep -v grep | grep SoniqueBar > /dev/null; then
    echo "⚠️  WARNING: SoniqueBar is NOT running!"
    echo ""
fi

# Show last 50 lines from both logs, then tail -f
echo "=== Last 50 lines from logs ==="
if [ -f "$STDOUT_LOG" ]; then
    echo "--- STDOUT ---"
    tail -50 "$STDOUT_LOG"
fi

if [ -f "$STDERR_LOG" ] && [ -s "$STDERR_LOG" ]; then
    echo "--- STDERR ---"
    tail -50 "$STDERR_LOG"
fi

echo ""
echo "=== Live monitoring (new entries appear below) ==="
tail -f "$STDOUT_LOG" "$STDERR_LOG" 2>/dev/null
