#!/bin/bash
# Comprehensive test suite for SoniqueBar

echo "=== SoniqueBar Command Test Suite ==="
echo

# Function to test a command
test_command() {
    local name="$1"
    local payload="$2"
    echo "[$name]"
    curl -s -X POST http://localhost:8890/command \
      -H "Content-Type: application/json" \
      -d "$payload" | python3 -c "import json,sys; r=json.load(sys.stdin); print(r['response'][:200])"
    echo
    echo
}

# Health check first
echo "[Health Check]"
curl -s http://localhost:8890/health | python3 -m json.tool
echo
echo

# Conversational
test_command "Time Query" '{"text":"what time is it?"}'

# Infrastructure - Docker
test_command "Restart Container" '{"text":"restart n8n"}'
test_command "Docker Status" '{"text":"check docker status"}'

# Infrastructure - Helmsman
test_command "Helmsman Queue" '{"text":"what is in the queue?"}'

# Infrastructure - Shell
test_command "Shell Command" '{"text":"run uptime"}'

# Infrastructure - Safari
test_command "Open URL" '{"text":"open https://github.com/charlieseay"}'

# Infrastructure - Slack
test_command "Slack Relay" '{"text":"tell the team I am testing Sonique voice integration"}'

# Screenshot (will fail without Screen Recording permission)
test_command "Screenshot" '{"text":"take a screenshot"}'

echo "=== Test Suite Complete ==="
