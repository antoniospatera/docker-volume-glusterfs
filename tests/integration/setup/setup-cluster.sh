#!/bin/bash
set -e

# Get script directory for relative paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Setting up GlusterFS 2-node Cluster ==="

# Stop existing containers
docker-compose -f "$SCRIPT_DIR/docker-compose.cluster.yml" down -v 2>/dev/null || true

# Start GlusterFS cluster
echo "Starting GlusterFS containers..."
docker-compose -f "$SCRIPT_DIR/docker-compose.cluster.yml" up -d

# Wait for containers to be ready
echo "Waiting for GlusterFS to start..."
sleep 15

# Check glusterd is running on both nodes
echo "Checking glusterd on both nodes..."
docker exec gluster1 systemctl status glusterd || docker exec gluster1 glusterd
docker exec gluster2 systemctl status glusterd || docker exec gluster2 glusterd

sleep 5

# Probe peer using IP address
echo "Probing peer..."
docker exec gluster1 gluster peer probe 172.28.0.11

sleep 5

# Check peer status
echo ""
echo "Peer status:"
docker exec gluster1 gluster peer status

# Create brick directories
echo "Creating brick directories..."
docker exec gluster1 mkdir -p /glusterfs/brick1
docker exec gluster2 mkdir -p /glusterfs/brick1

# Remove existing volume
echo "Removing existing volume (if any)..."
docker exec gluster1 gluster volume stop gv0 force 2>/dev/null || true
docker exec gluster1 gluster volume delete gv0 2>/dev/null || true

# Create replicated volume using IP addresses (required for external access)
echo "Creating replicated volume gv0..."
docker exec gluster1 gluster volume create gv0 replica 2 \
    172.28.0.10:/glusterfs/brick1 \
    172.28.0.11:/glusterfs/brick1 \
    force

# Start volume
echo "Starting volume gv0..."
docker exec gluster1 gluster volume start gv0

# Volume info
echo ""
echo "=== Volume Info ==="
docker exec gluster1 gluster volume info gv0

echo ""
echo "=== Cluster Ready! ==="
echo ""
echo "Servers: 172.28.0.10, 172.28.0.11"
echo "Volume:  gv0 (replica 2)"
echo ""
echo "Test with:"
echo "  docker volume create -d antoniospatera/glusterfs:next \\"
echo "    -o servers=172.28.0.10,172.28.0.11 \\"
echo "    -o volname=gv0 \\"
echo "    testvol"
echo ""
echo "NOTE: The plugin must be able to reach 172.28.0.0/24 network."
echo "      Since plugin uses 'network: host', it should work on Linux."
