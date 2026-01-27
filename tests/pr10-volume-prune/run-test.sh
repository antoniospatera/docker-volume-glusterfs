#!/bin/bash
set -e

# Test for multiple volumes with same settings (PR #10 regression test)
# If we create multiple volumes with same settings but different names,
# then there should not be a problem with mounting and unmounting.
#
# This situation resulted in complete volume removal in older versions.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Timing
START_TIME=$(date +%s)
TOTAL_TESTS=4

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# Current test info
CURRENT_TEST=""
TEST_START=0

# Helper functions
format_time() {
    local seconds=$1
    if [ "$seconds" -lt 1 ]; then
        echo "<1s"
    elif [ "$seconds" -lt 60 ]; then
        echo "${seconds}s"
    else
        local mins=$((seconds / 60))
        local secs=$((seconds % 60))
        echo "${mins}m ${secs}s"
    fi
}

start_test() {
    local num="$1"
    local name="$2"
    local desc="$3"
    CURRENT_TEST="$num"
    TEST_START=$(date +%s)
    printf "${CYAN}[%s/%s]${NC} ${BOLD}%-20s${NC} ${DIM}%s${NC}\n" "$num" "$TOTAL_TESTS" "$name" "$desc"
    printf "        "
}

pass() {
    local elapsed=$(($(date +%s) - TEST_START))
    printf "\r        ${GREEN}✓ PASS${NC} ${DIM}(%s)${NC}\n" "$(format_time $elapsed)"
}

fail() {
    local elapsed=$(($(date +%s) - TEST_START))
    printf "\r        ${RED}✗ FAIL${NC} ${DIM}(%s)${NC}\n" "$(format_time $elapsed)"
    echo -e "        ${RED}Error: $1${NC}"
    cleanup
    exit 1
}

cleanup() {
    echo ""
    echo -e "${DIM}Cleaning up...${NC}"
    docker-compose -f "$SCRIPT_DIR/stacka/docker-compose.yml" down -v 2>/dev/null || true
    docker-compose -f "$SCRIPT_DIR/stackb/docker-compose.yml" down -v 2>/dev/null || true
}

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║         Volume Prune Bug Test (PR #10)                       ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${DIM}Tests that removing one volume doesn't prune another volume's data${NC}"
echo -e "${DIM}Started:${NC} $(date '+%Y-%m-%d %H:%M:%S')"
echo ""
echo -e "${DIM}────────────────────────────────────────────────────────────────${NC}"
echo ""

# Cleanup any existing volumes
docker volume rm stackb_test-volume 2>/dev/null || true
docker volume rm stacka_test-volume 2>/dev/null || true

# Test 1: Start stacka and write test data
start_test 1 "Start stacka" "Create volume and write test data"
docker-compose -f "$SCRIPT_DIR/stacka/docker-compose.yml" up -d 2>/dev/null
sleep 2
docker-compose -f "$SCRIPT_DIR/stacka/docker-compose.yml" exec -T alpine2 rm -rf /data/* 2>/dev/null || true
docker-compose -f "$SCRIPT_DIR/stacka/docker-compose.yml" exec -T alpine2 sh -c 'echo "test" > /data/test_data' 2>/dev/null
pass

# Test 2: Start stackb with same settings
start_test 2 "Start stackb" "Create second volume with same settings"
docker-compose -f "$SCRIPT_DIR/stackb/docker-compose.yml" up -d 2>/dev/null
sleep 2
pass

# Test 3: Remove stackb volume
start_test 3 "Remove stackb" "Stop stackb and remove its volume"
docker-compose -f "$SCRIPT_DIR/stackb/docker-compose.yml" down 2>/dev/null
docker volume rm stackb_test-volume >/dev/null 2>&1 || true
pass

# Test 4: Verify stacka data preserved
start_test 4 "Verify stacka" "Check stacka data was NOT pruned"
RESULT=$(docker-compose -f "$SCRIPT_DIR/stacka/docker-compose.yml" exec -T alpine2 sh -c 'if [ -f "/data/test_data" ]; then echo "OK"; else echo "FAIL"; fi' 2>/dev/null)
if [ "$RESULT" = "OK" ]; then
    pass
else
    fail "stacka data was incorrectly pruned!"
fi

# Cleanup
cleanup

# Final summary
TOTAL_TIME=$(($(date +%s) - START_TIME))
echo ""
echo -e "${DIM}────────────────────────────────────────────────────────────────${NC}"
echo ""
echo -e "${GREEN}${BOLD}  ✓ All $TOTAL_TESTS tests passed!${NC}"
echo ""
echo -e "${DIM}────────────────────────────────────────────────────────────────${NC}"
echo -e "${BOLD}Total Duration:${NC} $(format_time $TOTAL_TIME)"
echo -e "${BOLD}Finished:${NC}       $(date '+%Y-%m-%d %H:%M:%S')"
echo ""
