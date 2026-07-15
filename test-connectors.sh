#!/bin/bash
# Test all Sonique Quinn connectors

echo "=========================================="
echo "Sonique Quinn Connector Test Suite"
echo "=========================================="

BASE_URL="http://127.0.0.1:5912"

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Test counter
TESTS_PASSED=0
TESTS_FAILED=0

test_result() {
    if [ $1 -eq 0 ]; then
        echo -e "${GREEN}✓ PASS${NC} - $2"
        ((TESTS_PASSED++))
    else
        echo -e "${RED}✗ FAIL${NC} - $2"
        ((TESTS_FAILED++))
    fi
}

echo ""
echo "========== PHASE 1: HEALTH CHECKS =========="

# Test Quinn service health
echo ""
echo "1.1 Quinn Brain Service Health"
RESPONSE=$(curl -s "$BASE_URL/health")
if echo "$RESPONSE" | grep -q "ok"; then
    test_result 0 "Quinn Brain Service is healthy"
else
    test_result 1 "Quinn Brain Service health check failed"
fi

# Test connector health
echo ""
echo "1.2 Connector Health Status"
HEALTH=$(curl -s "$BASE_URL/connectors/health")

# Check individual connectors
for CONNECTOR in helmsman docker slack; do
    if echo "$HEALTH" | grep -q "\"$CONNECTOR\""; then
        STATUS=$(echo "$HEALTH" | grep -A 2 "\"$CONNECTOR\"" | grep "success" | head -1)
        if echo "$STATUS" | grep -q "true"; then
            test_result 0 "$CONNECTOR connector is healthy"
        else
            test_result 1 "$CONNECTOR connector failed health check"
        fi
    else
        test_result 1 "$CONNECTOR connector not found"
    fi
done

echo ""
echo "========== PHASE 2: HELMSMAN INTEGRATION =========="

# Test 2.1: Query pending tasks
echo ""
echo "2.1 Query Pending Tasks"
RESPONSE=$(curl -s -X POST "$BASE_URL/respond" \
    -H "Content-Type: application/json" \
    -d '{"text":"What tasks are pending?"}')
if echo "$RESPONSE" | grep -q "pending"; then
    test_result 0 "Helmsman pending tasks query works"
else
    test_result 1 "Helmsman pending tasks query failed"
fi

# Test 2.2: Create a task
echo ""
echo "2.2 Create Task via Quinn"
RESPONSE=$(curl -s -X POST "$BASE_URL/respond" \
    -H "Content-Type: application/json" \
    -d '{"text":"Create task: Test Sonique integration complete"}')
if echo "$RESPONSE" | grep -q "success\|created"; then
    test_result 0 "Task creation command processed"
else
    test_result 1 "Task creation failed"
fi

echo ""
echo "========== PHASE 3: DOCKER INTEGRATION =========="

# Test 3.1: List containers
echo ""
echo "3.1 List Docker Containers"
RESPONSE=$(curl -s -X POST "$BASE_URL/respond" \
    -H "Content-Type: application/json" \
    -d '{"text":"List running containers"}')
if echo "$RESPONSE" | grep -q "container"; then
    test_result 0 "Docker list containers works"
else
    test_result 1 "Docker list containers failed"
fi

echo ""
echo "========== PHASE 4: SLACK INTEGRATION =========="

# Test 4.1: Post message
echo ""
echo "4.1 Post to Slack"
RESPONSE=$(curl -s -X POST "$BASE_URL/respond" \
    -H "Content-Type: application/json" \
    -d '{"text":"Post to #alerts: Quinn is online and ready"}')
if echo "$RESPONSE" | grep -q "Posted\|alerts"; then
    test_result 0 "Slack message posting works"
else
    test_result 1 "Slack message posting failed"
fi

echo ""
echo "========== PHASE 5: PERSONALITY =========="

# Test 5.1: Verify personality is loaded
echo ""
echo "5.1 Quinn Personality Loaded"
RESPONSE=$(curl -s -X POST "$BASE_URL/respond" \
    -H "Content-Type: application/json" \
    -d '{"text":"Hi Quinn, how are you?"}')
if echo "$RESPONSE" | grep -q "response"; then
    test_result 0 "Quinn personality loaded and responding"
else
    test_result 1 "Quinn personality not loaded"
fi

# Test 5.2: Model escalation (Sonnet for complex)
echo ""
echo "5.2 Model Escalation - Sonnet for Complex"
RESPONSE=$(curl -s -X POST "$BASE_URL/respond" \
    -H "Content-Type: application/json" \
    -d '{"text":"Why is the sky blue? Explain the science."}')
if echo "$RESPONSE" | grep -q "sonnet"; then
    test_result 0 "Model escalation to Sonnet works"
else
    test_result 1 "Model escalation failed"
fi

echo ""
echo "========== TEST SUMMARY =========="
echo ""
echo -e "Tests Passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Tests Failed: ${RED}$TESTS_FAILED${NC}"
echo "Total Tests: $((TESTS_PASSED + TESTS_FAILED))"
echo ""

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed. Review output above.${NC}"
    exit 1
fi
