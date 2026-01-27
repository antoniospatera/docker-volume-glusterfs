#!/bin/bash
set -e

# Get script directory for relative paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Get the actual hostname of the machine
HOST_NAME=$(hostname)
HOST_IP=$(hostname -I | awk '{print $1}')

echo "=== Setting up GlusterFS Single Node ==="
echo "Hostname: $HOST_NAME"
echo "IP: $HOST_IP"
echo ""

# Stop existing containers
docker-compose -f "$SCRIPT_DIR/docker-compose.yml" down -v 2>/dev/null || true

# Start GlusterFS container
echo "Starting GlusterFS container..."
docker-compose -f "$SCRIPT_DIR/docker-compose.yml" up -d

# Wait for container to be ready
echo "Waiting for GlusterFS to start..."
sleep 10

# Check glusterd is running
echo "Checking glusterd..."
docker exec gluster1 systemctl status glusterd || docker exec gluster1 glusterd

sleep 3

# Create brick directory
echo "Creating brick directory..."
docker exec gluster1 mkdir -p /glusterfs/brick1

# Remove existing volume if present
echo "Removing existing volume (if any)..."
docker exec gluster1 gluster volume stop gv0 force 2>/dev/null || true
docker exec gluster1 gluster volume delete gv0 2>/dev/null || true

# Create volume using the HOST hostname (not container hostname)
echo "Creating volume gv0 with hostname $HOST_NAME..."
docker exec gluster1 gluster volume create gv0 \
    ${HOST_NAME}:/glusterfs/brick1 \
    force

# Start volume
echo "Starting volume gv0..."
docker exec gluster1 gluster volume start gv0

# Volume info
echo ""
echo "=== Volume Info ==="
docker exec gluster1 gluster volume info gv0

echo ""
echo "=== GlusterFS ready! ==="
echo ""
echo "Server: $HOST_NAME (or $HOST_IP)"
echo "Volume: gv0"
echo ""
echo "Test with:"
echo "  docker volume create -d antoniospatera/glusterfs:next \\"
echo "    -o servers=$HOST_NAME \\"
echo "    -o volname=gv0 \\"
echo "    testvol"
