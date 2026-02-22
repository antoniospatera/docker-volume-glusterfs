#!/bin/bash
set -e

PLUGIN_NAME="${PLUGIN_NAME:-antoniospatera/glusterfs:latest}"
#SERVERS="${SERVERS:-$(hostname)}"
SERVERS="${SERVERS:-172.28.0.10,172.28.0.11}"
VOLNAME="${VOLNAME:-gv0}"

# Log configuration
LOG_DIR="${LOG_DIR:-./logs}"
LOG_FILE="${LOG_DIR}/test-$(date +%Y%m%d-%H%M%S).log"
COLLECT_LOGS="${COLLECT_LOGS:-true}"

# Timing
START_TIME=$(date +%s)
TEST_TIMES=()

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# Current test info
CURRENT_TEST=""
CURRENT_DESC=""
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
    CURRENT_DESC="$name"
    TEST_START=$(date +%s)
    printf "${CYAN}[%2s/10]${NC} ${BOLD}%-30s${NC} ${DIM}%s${NC}\n" "$num" "$name" "$desc"
    printf "        "
}

pass() {
    local elapsed=$(($(date +%s) - TEST_START))
    TEST_TIMES+=("$CURRENT_TEST:$elapsed")
    printf "\r        ${GREEN}✓ PASS${NC} ${DIM}(%s)${NC}\n" "$(format_time $elapsed)"
}

fail() {
    local elapsed=$(($(date +%s) - TEST_START))
    printf "\r        ${RED}✗ FAIL${NC} ${DIM}(%s)${NC}\n" "$(format_time $elapsed)"
    echo -e "        ${RED}Error: $1${NC}"
    collect_logs "FAILURE"
    echo -e "        ${BLUE}Logs: ${LOG_FILE}${NC}"
    print_summary
    exit 1
}

print_summary() {
    local total_time=$(($(date +%s) - START_TIME))
    echo ""
    echo -e "${DIM}────────────────────────────────────────${NC}"
    echo -e "${BOLD}Test Duration:${NC} $(format_time $total_time)"
}

# Log collection functions
setup_logs() {
    if [ "$COLLECT_LOGS" = "true" ]; then
        mkdir -p "$LOG_DIR"
        echo "=== GlusterFS Plugin Test Logs ===" > "$LOG_FILE"
        echo "Started: $(date)" >> "$LOG_FILE"
        echo "Plugin: $PLUGIN_NAME" >> "$LOG_FILE"
        echo "Servers: $SERVERS" >> "$LOG_FILE"
        echo "Volume: $VOLNAME" >> "$LOG_FILE"
        echo "" >> "$LOG_FILE"
    fi
}

collect_logs() {
    local phase="${1:-UNKNOWN}"
    local vol_name="${2:-testvol}"
    if [ "$COLLECT_LOGS" != "true" ]; then
        return
    fi

    echo "" >> "$LOG_FILE"
    echo "========================================" >> "$LOG_FILE"
    echo "=== Log Collection: $phase ===" >> "$LOG_FILE"
    echo "=== Timestamp: $(date) ===" >> "$LOG_FILE"
    echo "========================================" >> "$LOG_FILE"

    # Plugin info
    echo "" >> "$LOG_FILE"
    echo "--- Plugin Status ---" >> "$LOG_FILE"
    docker plugin ls >> "$LOG_FILE" 2>&1 || true

    # Plugin inspect
    echo "" >> "$LOG_FILE"
    echo "--- Plugin Inspect ---" >> "$LOG_FILE"
    docker plugin inspect "$PLUGIN_NAME" >> "$LOG_FILE" 2>&1 || true

    # Docker volumes
    echo "" >> "$LOG_FILE"
    echo "--- Docker Volumes ---" >> "$LOG_FILE"
    docker volume ls >> "$LOG_FILE" 2>&1 || true

    # Volume inspect (if exists)
    echo "" >> "$LOG_FILE"
    echo "--- Volume Inspect ($vol_name) ---" >> "$LOG_FILE"
    docker volume inspect "$vol_name" >> "$LOG_FILE" 2>&1 || echo "Volume not found" >> "$LOG_FILE"

    # GlusterFS mounts
    echo "" >> "$LOG_FILE"
    echo "--- GlusterFS Mounts ---" >> "$LOG_FILE"
    grep gluster /proc/mounts >> "$LOG_FILE" 2>&1 || echo "No GlusterFS mounts" >> "$LOG_FILE"

    # Plugin logs from journalctl
    echo "" >> "$LOG_FILE"
    echo "--- Plugin Logs (journalctl) ---" >> "$LOG_FILE"
    journalctl -u docker.service --no-pager -n 100 2>&1 | grep -i gluster >> "$LOG_FILE" || echo "No journalctl logs found" >> "$LOG_FILE"

    # Plugin logs from /var/log/messages (for systems using syslog)
    echo "" >> "$LOG_FILE"
    echo "--- Plugin Logs (/var/log/messages) ---" >> "$LOG_FILE"
    tail -200 /var/log/messages 2>&1 | grep -i gluster >> "$LOG_FILE" || echo "No messages logs found" >> "$LOG_FILE"

    # Cluster peer status
    echo "" >> "$LOG_FILE"
    echo "--- Cluster Peer Status ---" >> "$LOG_FILE"
    docker exec gluster1 gluster peer status >> "$LOG_FILE" 2>&1 || echo "gluster1 not available" >> "$LOG_FILE"

    # GlusterFS volume info
    echo "" >> "$LOG_FILE"
    echo "--- GlusterFS Volume Info ---" >> "$LOG_FILE"
    docker exec gluster1 gluster volume info "$VOLNAME" >> "$LOG_FILE" 2>&1 || echo "GlusterFS volume not available" >> "$LOG_FILE"

    # GlusterFS volume status
    echo "" >> "$LOG_FILE"
    echo "--- GlusterFS Volume Status ---" >> "$LOG_FILE"
    docker exec gluster1 gluster volume status "$VOLNAME" >> "$LOG_FILE" 2>&1 || echo "GlusterFS volume not available" >> "$LOG_FILE"

    # GlusterFS heal info
    echo "" >> "$LOG_FILE"
    echo "--- GlusterFS Heal Info ---" >> "$LOG_FILE"
    docker exec gluster1 gluster volume heal "$VOLNAME" info >> "$LOG_FILE" 2>&1 || echo "Heal info not available" >> "$LOG_FILE"

    # Container status
    echo "" >> "$LOG_FILE"
    echo "--- Docker Containers ---" >> "$LOG_FILE"
    docker ps -a >> "$LOG_FILE" 2>&1 || true
}

# Initialize logs
setup_logs

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║         GlusterFS Plugin Integration Tests                   ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${DIM}Plugin:${NC}  $PLUGIN_NAME"
echo -e "${DIM}Servers:${NC} $SERVERS"
echo -e "${DIM}Volume:${NC}  $VOLNAME"
echo -e "${DIM}Started:${NC} $(date '+%Y-%m-%d %H:%M:%S')"
echo ""
echo -e "${DIM}────────────────────────────────────────────────────────────────${NC}"
echo ""

# Test 1: Plugin is installed and enabled
start_test 1 "Plugin Check" "Verify plugin is installed and enabled"
PLUGIN_STATUS=$(docker plugin ls --format '{{.Name}} {{.Enabled}}' | grep "$PLUGIN_NAME" || true)
if [ -z "$PLUGIN_STATUS" ]; then
    fail "Plugin not found"
elif echo "$PLUGIN_STATUS" | grep -q "false"; then
    fail "Plugin disabled"
else
    pass
fi

# Test 2: Create volume
start_test 2 "Create Volume" "Create Docker volume with GlusterFS backend"
docker volume rm testvol >/dev/null 2>&1 || true
docker volume create -d "$PLUGIN_NAME" \
    -o servers="$SERVERS" \
    -o volname="$VOLNAME" \
    -o subdir=testdata \
    testvol >/dev/null
pass

# Test 3: List volume
start_test 3 "List Volume" "Verify volume appears in docker volume ls"
if docker volume ls | grep -q "testvol"; then
    pass
else
    fail "Volume not in list"
fi

# Test 4: Mount and write data
start_test 4 "Write Data" "Mount volume in container and write test file"
TEST_DATA="Hello from GlusterFS plugin test - $(date)"
docker run --rm -v testvol:/data alpine sh -c "echo '$TEST_DATA' > /data/testfile.txt"
pass

# Test 5: Mount and read data
start_test 5 "Read Data" "Mount volume and verify data persistence"
READ_DATA=$(docker run --rm -v testvol:/data alpine cat /data/testfile.txt)
if [ "$READ_DATA" = "$TEST_DATA" ]; then
    pass
else
    fail "Data mismatch"
fi

# Test 6: Multiple containers same volume
start_test 6 "Multi-Container" "Two containers mounting same volume simultaneously"
docker run -d --name test_container1 -v testvol:/data alpine sleep 30 >/dev/null
docker run -d --name test_container2 -v testvol:/data alpine sleep 30 >/dev/null
sleep 2
C1_STATUS=$(docker inspect -f '{{.State.Running}}' test_container1)
C2_STATUS=$(docker inspect -f '{{.State.Running}}' test_container2)
docker rm -f test_container1 test_container2 >/dev/null
if [ "$C1_STATUS" = "true" ] && [ "$C2_STATUS" = "true" ]; then
    pass
else
    fail "Multiple containers failed"
fi

# Test 7: Container kill (SIGKILL)
start_test 7 "Container Kill" "SIGKILL container, verify volume still accessible"
docker run -d --name test_kill -v testvol:/data alpine sleep 60 >/dev/null
sleep 2
docker kill test_kill >/dev/null
docker rm test_kill >/dev/null
sleep 1
docker run --rm -v testvol:/data alpine ls /data/testfile.txt >/dev/null
pass

# Test 8: Data persistence after unmount
start_test 8 "Data Persistence" "Verify data survives full unmount cycle"
sleep 2
READ_DATA=$(docker run --rm -v testvol:/data alpine cat /data/testfile.txt)
if [ "$READ_DATA" = "$TEST_DATA" ]; then
    pass
else
    fail "Data lost after unmount"
fi

# Test 9: Volume inspect
start_test 9 "Volume Inspect" "docker volume inspect returns valid JSON"
if docker volume inspect testvol >/dev/null 2>&1; then
    pass
else
    fail "Volume inspect failed"
fi

# Test 10: Remove volume
start_test 10 "Remove Volume" "Clean removal of volume"
docker volume rm testvol >/dev/null
if docker volume ls | grep -q "testvol"; then
    fail "Volume still exists"
else
    pass
fi

# Collect final logs
collect_logs "SUCCESS"

# Final summary
TOTAL_TIME=$(($(date +%s) - START_TIME))
echo ""
echo -e "${DIM}────────────────────────────────────────────────────────────────${NC}"
echo ""
echo -e "${GREEN}${BOLD}  ✓ All 10 tests passed!${NC}"
echo ""
echo -e "${DIM}────────────────────────────────────────────────────────────────${NC}"
echo -e "${BOLD}Total Duration:${NC} $(format_time $TOTAL_TIME)"
echo -e "${BOLD}Finished:${NC}       $(date '+%Y-%m-%d %H:%M:%S')"
if [ "$COLLECT_LOGS" = "true" ]; then
    echo -e "${BOLD}Logs:${NC}           ${LOG_FILE}"
fi
echo ""
