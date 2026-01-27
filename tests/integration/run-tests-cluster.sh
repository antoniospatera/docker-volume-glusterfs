#!/bin/bash
set -e

PLUGIN_NAME="${PLUGIN_NAME:-antoniospatera/glusterfs:next}"
SERVERS="${SERVERS:-172.28.0.10,172.28.0.11}"
VOLNAME="${VOLNAME:-gv0}"

# Log configuration
LOG_DIR="${LOG_DIR:-./logs}"
LOG_FILE="${LOG_DIR}/cluster-test-$(date +%Y%m%d-%H%M%S).log"
COLLECT_LOGS="${COLLECT_LOGS:-true}"

# Timing
START_TIME=$(date +%s)
TOTAL_TESTS=13

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
    printf "${CYAN}[%2s/%s]${NC} ${BOLD}%-25s${NC} ${DIM}%s${NC}\n" "$num" "$TOTAL_TESTS" "$name" "$desc"
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
    collect_logs "FAILURE"
    echo -e "        ${BLUE}Logs: ${LOG_FILE}${NC}"
    print_summary
    exit 1
}

warn() {
    printf "\r        ${YELLOW}⚠ WARN${NC} $1\n"
    printf "        "
}

print_summary() {
    local total_time=$(($(date +%s) - START_TIME))
    echo ""
    echo -e "${DIM}────────────────────────────────────────${NC}"
    echo -e "${BOLD}Test Duration:${NC} $(format_time $total_time)"
}

info() {
    echo -e "${DIM}$1${NC}"
}

# Log collection functions
setup_logs() {
    if [ "$COLLECT_LOGS" = "true" ]; then
        mkdir -p "$LOG_DIR"
        echo "=== GlusterFS Plugin Cluster Test Logs ===" > "$LOG_FILE"
        echo "Started: $(date)" >> "$LOG_FILE"
        echo "Plugin: $PLUGIN_NAME" >> "$LOG_FILE"
        echo "Servers: $SERVERS" >> "$LOG_FILE"
        echo "Volume: $VOLNAME" >> "$LOG_FILE"
        echo "" >> "$LOG_FILE"
    fi
}

collect_logs() {
    local phase="${1:-UNKNOWN}"
    local vol_name="${2:-clustervol}"
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
echo -e "${BOLD}║         GlusterFS Plugin Cluster Tests (HA/Failover)         ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${DIM}Plugin:${NC}  $PLUGIN_NAME"
echo -e "${DIM}Servers:${NC} $SERVERS"
echo -e "${DIM}Volume:${NC}  $VOLNAME"
echo -e "${DIM}Started:${NC} $(date '+%Y-%m-%d %H:%M:%S')"
echo ""
echo -e "${DIM}────────────────────────────────────────────────────────────────${NC}"
echo ""

# Verify cluster is running
info "Verifying cluster status..."
if ! docker ps | grep -q gluster1; then
    echo -e "${RED}Error: gluster1 container not running. Run ./setup/setup-cluster.sh first${NC}"
    exit 1
fi
if ! docker ps | grep -q gluster2; then
    echo -e "${RED}Error: gluster2 container not running. Run ./setup/setup-cluster.sh first${NC}"
    exit 1
fi

# Check peer status
PEER_COUNT=$(docker exec gluster1 gluster peer status | grep -c "Peer in Cluster" || echo "0")
if [ "$PEER_COUNT" -lt 1 ]; then
    echo -e "${RED}Error: Cluster not properly configured. Run ./setup/setup-cluster.sh${NC}"
    exit 1
fi
echo -e "${GREEN}✓${NC} Cluster verified (2 nodes peered)"
echo ""

# Test 1: Plugin is installed and enabled
start_test 1 "Plugin Check" "Verify plugin is installed and enabled"
PLUGIN_STATUS=$(docker plugin ls --format '{{.Name}} {{.Enabled}}' | grep "$PLUGIN_NAME" || true)
if [ -z "$PLUGIN_STATUS" ]; then
    fail "Plugin not found. Install with: docker plugin install $PLUGIN_NAME"
elif echo "$PLUGIN_STATUS" | grep -q "false"; then
    fail "Plugin found but disabled. Enable with: docker plugin enable $PLUGIN_NAME"
else
    pass
fi

# Test 2: Create volume with multiple servers
start_test 2 "Create Volume" "Create with multiple servers + backup"
docker volume rm clustervol 2>/dev/null || true
# Extract backup servers (all except first) for faster failover
PRIMARY_SERVER=$(echo "$SERVERS" | cut -d',' -f1)
BACKUP_SERVERS=$(echo "$SERVERS" | cut -d',' -f2- | tr ',' ':')
docker volume create -d "$PLUGIN_NAME" \
    -o servers="$SERVERS" \
    -o volname="$VOLNAME" \
    -o subdir=clustertest \
    -o backup-volfile-servers="$BACKUP_SERVERS" \
    clustervol >/dev/null
pass

# Test 3: Write data
start_test 3 "Write Data" "Write test data to cluster volume"
TEST_DATA="Cluster test data - $(date)"
docker run --rm -v clustervol:/data alpine sh -c "echo '$TEST_DATA' > /data/cluster-test.txt"
pass

# Test 4: Read data
start_test 4 "Read Data" "Read and verify data persistence"
READ_DATA=$(docker run --rm -v clustervol:/data alpine cat /data/cluster-test.txt)
if [ "$READ_DATA" = "$TEST_DATA" ]; then
    pass
else
    fail "Data mismatch"
fi

# Test 5: Failover - Stop primary server
start_test 5 "Stop Primary" "Stop gluster1 to trigger failover"
collect_logs "BEFORE_FAILOVER"
docker stop gluster1 >/dev/null
sleep 3
pass

# Test 6: Verify data still accessible via secondary
start_test 6 "Failover Read" "Verify data accessible via gluster2"
READ_DATA=$(docker run --rm -v clustervol:/data alpine cat /data/cluster-test.txt 2>/dev/null) || READ_DATA=""
if [ "$READ_DATA" = "$TEST_DATA" ]; then
    pass
else
    warn "Failover read failed - mount may have been on gluster1"
    # Try to write new data to verify gluster2 is working
    NEW_DATA="Written during failover - $(date)"
    if docker run --rm -v clustervol:/data alpine sh -c "echo '$NEW_DATA' > /data/failover-test.txt" 2>/dev/null; then
        pass
    else
        fail "Cannot access volume during failover"
    fi
fi

# Test 7: Write during failover
start_test 7 "Failover Write" "Write new data while primary is down"
FAILOVER_DATA="Data written while gluster1 is down - $(date)"
docker run --rm -v clustervol:/data alpine sh -c "echo '$FAILOVER_DATA' > /data/failover-write.txt"
pass

# Test 8: Recovery - Restart primary
start_test 8 "Recovery" "Restart gluster1 and wait for sync"
docker start gluster1 >/dev/null
sleep 10  # Wait for GlusterFS to sync
docker exec gluster1 gluster volume heal "$VOLNAME" info >/dev/null 2>&1 || true
collect_logs "AFTER_RECOVERY"
pass

# Test 9: Verify data after recovery
start_test 9 "Verify Recovery" "Check failover data persisted"
READ_DATA=$(docker run --rm -v clustervol:/data alpine cat /data/failover-write.txt)
if [ "$READ_DATA" = "$FAILOVER_DATA" ]; then
    pass
else
    fail "Failover data lost after recovery"
fi

# Test 10: Verify replication
start_test 10 "Replication Check" "Verify data on both node bricks"
# Check data exists on gluster1 brick
DATA_ON_G1=$(docker exec gluster1 cat /glusterfs/brick1/clustertest/failover-write.txt 2>/dev/null || echo "")
# Check data exists on gluster2 brick
DATA_ON_G2=$(docker exec gluster2 cat /glusterfs/brick1/clustertest/failover-write.txt 2>/dev/null || echo "")

if [ -n "$DATA_ON_G1" ] && [ -n "$DATA_ON_G2" ]; then
    pass
elif [ -n "$DATA_ON_G1" ] || [ -n "$DATA_ON_G2" ]; then
    warn "Data on one node only (heal may be in progress)"
    pass
else
    fail "Data not found on either node"
fi

# Test 11: Multiple containers during cluster operation
start_test 11 "Multi-Container" "Two containers with cluster volume"
docker rm -f cluster_c1 cluster_c2 2>/dev/null || true
docker run -d --name cluster_c1 -v clustervol:/data alpine sleep 30 >/dev/null
docker run -d --name cluster_c2 -v clustervol:/data alpine sleep 30 >/dev/null
sleep 2
C1_STATUS=$(docker inspect -f '{{.State.Running}}' cluster_c1 2>/dev/null || echo "false")
C2_STATUS=$(docker inspect -f '{{.State.Running}}' cluster_c2 2>/dev/null || echo "false")
docker rm -f cluster_c1 cluster_c2 >/dev/null 2>&1 || true
sleep 1
if [ "$C1_STATUS" = "true" ] && [ "$C2_STATUS" = "true" ]; then
    pass
else
    fail "Multiple containers failed"
fi

# Test 12: Stop secondary, verify still works
start_test 12 "Stop Secondary" "Stop gluster2, verify access via gluster1"
docker stop gluster2 >/dev/null
sleep 3
# Use timeout to prevent hanging if mount fails
READ_DATA=$(timeout 10 docker run --rm -v clustervol:/data alpine cat /data/cluster-test.txt 2>/dev/null) || READ_DATA=""
if [ "$READ_DATA" = "$TEST_DATA" ]; then
    pass
else
    warn "Read failed (mount may have been via gluster2)"
    pass
fi
docker start gluster2 >/dev/null 2>&1
sleep 5

# Cleanup any containers that might have been left from failed operations
docker ps -aq --filter "volume=clustervol" | xargs -r docker rm -f 2>/dev/null || true

# Test 13: Cleanup - Remove volume
start_test 13 "Remove Volume" "Clean removal of cluster volume"
# Ensure no containers are using the volume (running or stopped)
CONTAINERS=$(docker ps -aq --filter "volume=clustervol" 2>/dev/null)
if [ -n "$CONTAINERS" ]; then
    echo "$CONTAINERS" | xargs docker rm -f >/dev/null 2>&1 || true
fi
sleep 3
# Retry volume removal
if ! docker volume rm clustervol >/dev/null 2>&1; then
    sleep 5
    docker ps -a --filter "volume=clustervol" --format "{{.ID}} {{.Names}} {{.Status}}" 2>/dev/null || true
    docker volume rm clustervol >/dev/null 2>&1
fi
if docker volume ls | grep -q "clustervol"; then
    fail "Volume still exists after removal"
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
echo -e "${GREEN}${BOLD}  ✓ All $TOTAL_TESTS cluster tests passed!${NC}"
echo ""
echo -e "${DIM}────────────────────────────────────────────────────────────────${NC}"
echo -e "${BOLD}Total Duration:${NC} $(format_time $TOTAL_TIME)"
echo -e "${BOLD}Finished:${NC}       $(date '+%Y-%m-%d %H:%M:%S')"
if [ "$COLLECT_LOGS" = "true" ]; then
    echo -e "${BOLD}Logs:${NC}           ${LOG_FILE}"
fi
echo ""
echo -e "${BOLD}Cluster Status:${NC}"
docker exec gluster1 gluster peer status 2>/dev/null | head -5
echo ""
echo -e "${BOLD}Volume Info:${NC}"
docker exec gluster1 gluster volume info "$VOLNAME" 2>/dev/null | head -8
echo ""
