#!/bin/bash

# Get script directory for relative paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Cleaning up test environment ==="

# Remove test volumes
echo "Removing test volumes..."
docker volume rm testvol 2>/dev/null || true
docker volume rm clustervol 2>/dev/null || true

# Remove any leftover test containers
echo "Removing test containers..."
docker rm -f test_container1 test_container2 test_kill cluster_c1 cluster_c2 2>/dev/null || true

# Stop and remove single-node GlusterFS
echo "Stopping single-node GlusterFS..."
docker-compose -f "$SCRIPT_DIR/docker-compose.yml" down -v 2>/dev/null || true

# Stop and remove cluster GlusterFS
echo "Stopping cluster GlusterFS..."
docker-compose -f "$SCRIPT_DIR/docker-compose.cluster.yml" down -v 2>/dev/null || true

echo "=== Cleanup complete ==="
