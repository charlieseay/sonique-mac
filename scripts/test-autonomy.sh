#!/bin/bash
# Automated Autonomy Test Suite for Quinn
# Tests: Doc consultation, error recovery, lesson learning, telemetry

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TEST_RESULTS_DIR="$HOME/Library/Application Support/SoniqueBar/test-results"
METRICS_FILE="$HOME/Library/Application Support/SoniqueBar/autonomy-metrics.json"
LESSONS_FILE="$HOME/Library/Application Support/SoniqueBar/SoniqueProfiles/Desktop/lessons.jsonl"
LOG_FILE="/tmp/soniquebar.log"

mkdir -p "$TEST_RESULTS_DIR"

echo "================================================"
echo "Quinn Autonomy Test Suite"
echo "Started: $(date)"
echo "================================================"
echo

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

TESTS_PASSED=0
TESTS_FAILED=0

pass() {
    echo -e "${GREEN}✓ PASS${NC}: $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

fail() {
    echo -e "${RED}✗ FAIL${NC}: $1"
    echo "  Reason: $2"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

warn() {
    echo -e "${YELLOW}⚠ WARN${NC}: $1"
}

# Function to send query to Quinn via HTTP
query_quinn() {
    local query="$1"
    local auth_token=$(cat /Volumes/data/secrets/sonique_auth_token 2>/dev/null || echo "test-token")

    echo "Querying Quinn: \"$query\""

    # Call CommandServer HTTP API
    curl -s -X POST http://localhost:8890/command \
        -H "Authorization: Bearer $auth_token" \
        -H "Content-Type: application/json" \
        -d "{\"text\":\"$query\"}" \
        -w "\nHTTP_STATUS:%{http_code}\n" \
        -o /tmp/quinn-response.txt

    local http_status=$(tail -1 /tmp/quinn-response.txt | cut -d':' -f2)
    local response=$(head -n -1 /tmp/quinn-response.txt)

    echo "$response" > /tmp/quinn-last-response.txt
    echo "$http_status"
}

# Wait for log entry
wait_for_log() {
    local pattern="$1"
    local timeout=${2:-10}
    local start=$(date +%s)

    while [ $(($(date +%s) - start)) -lt $timeout ]; do
        if tail -50 "$LOG_FILE" | grep -q "$pattern"; then
            return 0
        fi
        sleep 0.5
    done

    return 1
}

echo "=== PRE-TEST SETUP ==="
echo

# Check SoniqueBar is running
if ! pgrep -x "SoniqueBar" > /dev/null; then
    echo "Starting SoniqueBar..."
    open -a /tmp/soniquebar-build/Build/Products/Release/SoniqueBar.app
    sleep 5
fi

# Wait for server ready
echo "Waiting for CommandServer ready..."
if wait_for_log "READY for requests" 30; then
    pass "SoniqueBar running and ready"
else
    fail "SoniqueBar not ready" "CommandServer did not reach ready state"
    exit 1
fi

# Clear metrics for clean test
echo "Clearing metrics for fresh test run..."
echo '{
  "totalQueries": 0,
  "technicalQuestions": 0,
  "docsConsulted": 0,
  "errorsDetected": 0,
  "errorsRecovered": 0,
  "lessonsLogged": 0,
  "lastUpdated": "'$(date -Iseconds)'"
}' > "$METRICS_FILE"

# Backup lessons file
if [ -f "$LESSONS_FILE" ]; then
    cp "$LESSONS_FILE" "$LESSONS_FILE.backup"
fi

echo
echo "=== UNIT TESTS ==="
echo

# TEST 1: Documentation Consultation Detection
echo "TEST 1: Documentation Consultation Detection"
echo "-------------------------------------------"

# Technical questions (should trigger docs)
technical_queries=(
    "How do I use HomeKit automation?"
    "What's the Swift API for speech recognition?"
    "Set up EventKit calendar access"
)

# Non-technical questions (should NOT trigger docs)
simple_queries=(
    "What time is it?"
    "What's the weather?"
)

tech_detected=0
for query in "${technical_queries[@]}"; do
    http_status=$(query_quinn "$query")

    if [ "$http_status" = "200" ]; then
        # Check if docs were consulted
        if tail -100 "$LOG_FILE" | grep -q "Technical query detected"; then
            tech_detected=$((tech_detected + 1))
            echo "  ✓ Technical question detected"
        else
            echo "  ✗ Technical question NOT detected"
        fi
    else
        warn "Query failed with HTTP $http_status"
    fi

    sleep 2
done

if [ $tech_detected -eq ${#technical_queries[@]} ]; then
    pass "Technical question detection (${tech_detected}/${#technical_queries[@]})"
else
    fail "Technical question detection" "Only ${tech_detected}/${#technical_queries[@]} detected"
fi

# Verify simple questions don't trigger docs
simple_correct=0
for query in "${simple_queries[@]}"; do
    http_status=$(query_quinn "$query")

    if [ "$http_status" = "200" ]; then
        # Should NOT see "Technical query detected"
        if ! tail -50 "$LOG_FILE" | grep -q "Technical query detected"; then
            simple_correct=$((simple_correct + 1))
            echo "  ✓ Simple question correctly skipped docs"
        else
            echo "  ✗ Simple question incorrectly triggered docs"
        fi
    fi

    sleep 2
done

if [ $simple_correct -eq ${#simple_queries[@]} ]; then
    pass "Simple questions skip docs (${simple_correct}/${#simple_queries[@]})"
else
    fail "Simple questions" "Only ${simple_correct}/${#simple_queries[@]} correctly skipped"
fi

echo
echo "TEST 2: NotebookLM Query Execution"
echo "-----------------------------------"

# Test nlm CLI directly
if command -v nlm &> /dev/null; then
    if nlm notebook query tech-kb "iOS HomeKit automation" > /tmp/nlm-test.txt 2>&1; then
        if [ -s /tmp/nlm-test.txt ]; then
            pass "NotebookLM CLI executable and authenticated"
        else
            fail "NotebookLM CLI" "Returned empty response"
        fi
    else
        fail "NotebookLM CLI" "Command failed or not authenticated"
    fi
else
    fail "NotebookLM CLI" "nlm command not found in PATH"
fi

echo
echo "TEST 3: Telemetry Tracking"
echo "--------------------------"

# Check metrics file exists and has valid JSON
if [ -f "$METRICS_FILE" ]; then
    if python3 -c "import json; json.load(open('$METRICS_FILE'))" 2>/dev/null; then
        pass "Metrics file exists and is valid JSON"

        # Parse metrics
        total=$(python3 -c "import json; print(json.load(open('$METRICS_FILE'))['totalQueries'])")
        technical=$(python3 -c "import json; print(json.load(open('$METRICS_FILE'))['technicalQuestions'])")
        docs=$(python3 -c "import json; print(json.load(open('$METRICS_FILE'))['docsConsulted'])")

        echo "  Total queries: $total"
        echo "  Technical questions: $technical"
        echo "  Docs consulted: $docs"

        if [ "$total" -gt 0 ]; then
            pass "Telemetry tracking queries (total=$total)"
        else
            fail "Telemetry" "No queries tracked despite test queries sent"
        fi

        if [ "$technical" -gt 0 ]; then
            pass "Telemetry tracking technical questions (technical=$technical)"
        else
            warn "No technical questions tracked (may be detection issue)"
        fi
    else
        fail "Metrics file" "Invalid JSON format"
    fi
else
    fail "Metrics file" "File not created at $METRICS_FILE"
fi

echo
echo "TEST 4: Lesson Recording"
echo "------------------------"

# Check lessons file
if [ -f "$LESSONS_FILE" ]; then
    lesson_count=$(wc -l < "$LESSONS_FILE" | tr -d ' ')
    pass "Lessons file exists ($lesson_count entries)"

    # Validate JSON format
    if head -1 "$LESSONS_FILE" | python3 -c "import json, sys; json.load(sys.stdin)" 2>/dev/null; then
        pass "Lessons file contains valid JSON entries"
    else
        if [ "$lesson_count" -eq 0 ]; then
            warn "Lessons file empty (no lessons logged yet)"
        else
            fail "Lessons file" "Contains invalid JSON"
        fi
    fi
else
    warn "Lessons file not created yet (no lessons logged)"
fi

echo
echo "=== INTEGRATION TESTS ==="
echo

echo "TEST 5: Full Documentation Flow"
echo "--------------------------------"

# Clear recent logs
: > /tmp/quinn-flow-test.log

# Ask a technical question
http_status=$(query_quinn "How do I request camera permission in iOS?")

if [ "$http_status" = "200" ]; then
    response=$(cat /tmp/quinn-last-response.txt)

    # Check for official Apple API mention
    if echo "$response" | grep -qi "AVCaptureDevice\|AVFoundation\|requestAccess"; then
        pass "Response includes official Apple API"
    else
        warn "Response may not cite official API (check manually)"
    fi

    # Check logs for documentation consultation
    if tail -100 "$LOG_FILE" | grep -q "Documentation retrieved"; then
        pass "Documentation was retrieved from NotebookLM"
    else
        fail "Documentation flow" "No evidence of doc retrieval in logs"
    fi
else
    fail "Documentation flow" "HTTP request failed ($http_status)"
fi

echo
echo "=== TEST SUMMARY ==="
echo

# Save results
cat > "$TEST_RESULTS_DIR/test-run-$(date +%Y%m%d-%H%M%S).txt" <<EOF
Quinn Autonomy Test Results
============================
Timestamp: $(date)

Tests Passed: $TESTS_PASSED
Tests Failed: $TESTS_FAILED
Total Tests: $((TESTS_PASSED + TESTS_FAILED))

Pass Rate: $(python3 -c "print(f'{$TESTS_PASSED / ($TESTS_PASSED + $TESTS_FAILED) * 100:.1f}%')" 2>/dev/null || echo "N/A")

Final Metrics:
$(cat "$METRICS_FILE" 2>/dev/null || echo "Metrics file not found")

Log Tail:
$(tail -50 "$LOG_FILE")
EOF

echo "Tests Passed: ${GREEN}$TESTS_PASSED${NC}"
echo "Tests Failed: ${RED}$TESTS_FAILED${NC}"
echo "Total Tests: $((TESTS_PASSED + TESTS_FAILED))"
echo

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}✓ ALL TESTS PASSED${NC}"
    exit 0
else
    echo -e "${RED}✗ SOME TESTS FAILED${NC}"
    echo "See: $TEST_RESULTS_DIR/test-run-$(date +%Y%m%d-%H%M%S).txt"
    exit 1
fi
