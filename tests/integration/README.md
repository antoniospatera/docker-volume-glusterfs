# Integration Tests

This directory contains scripts to set up a local GlusterFS cluster and run integration tests for the Docker volume plugin.

## Directory Structure

```
test/
├── setup/                          # Environment setup
│   ├── docker-compose.yml          # Single node GlusterFS
│   ├── docker-compose.cluster.yml  # 2-node cluster
│   ├── setup-gluster.sh            # Setup single node
│   ├── setup-cluster.sh            # Setup cluster
│   └── cleanup.sh                  # Cleanup all
├── run-tests.sh                    # Basic tests (10 tests)
├── run-tests-cluster.sh            # Cluster tests with failover (13 tests)
├── README.md
├── .gitignore
└── logs/                           # Generated logs (git ignored)
```

## Prerequisites

- Docker with Docker Compose
- Plugin built and installed (`make clean rootfs create` from parent directory)

## Quick Start - Single Node

```bash
# 1. Build and install plugin (from parent directory)
cd ..
sudo make clean rootfs create
sudo docker plugin enable antoniospatera/glusterfs:next

# 2. Start GlusterFS single node
cd test
chmod +x setup/*.sh *.sh
sudo ./setup/setup-gluster.sh

# 3. Run tests
sudo ./run-tests.sh

# 4. Cleanup
sudo ./setup/cleanup.sh
```

## Quick Start - 2-Node Cluster (HA/Failover Testing)

```bash
# 1. Build and install plugin (from parent directory)
cd ..
sudo make clean rootfs create
sudo docker plugin enable antoniospatera/glusterfs:next

# 2. Start GlusterFS 2-node cluster
cd test
chmod +x setup/*.sh *.sh
sudo ./setup/setup-cluster.sh

# 3. Run cluster tests (includes failover tests)
sudo ./run-tests-cluster.sh

# 4. Cleanup
sudo ./setup/cleanup.sh
```

## Test Environment

### Single Node (Local Testing)

```
┌─────────────────────────────────────────┐
│              Host Machine               │
│                                         │
│  ┌─────────────────────────────────┐   │
│  │  GlusterFS Container (gluster1) │   │
│  │  network_mode: host             │   │
│  │                                 │   │
│  │  brick: /glusterfs/brick1       │   │
│  │  volume: gv0                    │   │
│  └─────────────────────────────────┘   │
│                                         │
│  ┌─────────────────────────────────┐   │
│  │  Docker Plugin                  │   │
│  │  servers=$(hostname)            │   │
│  └─────────────────────────────────┘   │
└─────────────────────────────────────────┘
```

### 2-Node Cluster (HA Testing)

```
┌─────────────────────────────────────────┐
│              Host Machine               │
│                                         │
│  ┌───────────────┐  ┌───────────────┐  │
│  │   gluster1    │  │   gluster2    │  │
│  │ 172.28.0.10   │  │ 172.28.0.11   │  │
│  │               │  │               │  │
│  │ brick1 ◄──────┼──┼─────► brick1  │  │
│  └───────────────┘  └───────────────┘  │
│          │                  │          │
│          └────────┬─────────┘          │
│                   ▼                    │
│          Volume: gv0 (replica 2)       │
│                                        │
│  ┌─────────────────────────────────┐   │
│  │  Docker Plugin                  │   │
│  │  servers=172.28.0.10,172.28.0.11│   │
│  │  backup-volfile-servers=.11     │   │
│  └─────────────────────────────────┘   │
└─────────────────────────────────────────┘
```

## Test Cases - Single Node (run-tests.sh)

| # | Test | Description |
|---|------|-------------|
| 1 | Plugin installed | Verify plugin is installed and enabled |
| 2 | Create volume | Create a Docker volume with GlusterFS backend |
| 3 | List volume | Verify volume appears in `docker volume ls` |
| 4 | Write data | Mount volume and write test data |
| 5 | Read data | Mount volume and verify data persistence |
| 6 | Multiple containers | Two containers mounting same volume |
| 7 | Container kill | SIGKILL and verify volume still accessible |
| 8 | Data persistence | Verify data after full unmount cycle |
| 9 | Volume inspect | `docker volume inspect` works |
| 10 | Remove volume | Clean removal of volume |

## Test Cases - Cluster (run-tests-cluster.sh)

| # | Test | Description |
|---|------|-------------|
| 1 | Plugin installed | Verify plugin is installed and enabled |
| 2 | Create volume | Create volume with multiple servers + backup-volfile-servers |
| 3 | Write data | Write test data to cluster volume |
| 4 | Read data | Verify data readable |
| 5 | Failover - stop primary | Stop gluster1 (primary node) |
| 6 | Read during failover | Verify data accessible via gluster2 |
| 7 | Write during failover | Write new data while primary is down |
| 8 | Recovery | Restart gluster1 and wait for sync |
| 9 | Verify after recovery | Check failover data persisted |
| 10 | Replication check | Verify data on both node bricks |
| 11 | Multiple containers | Two containers with cluster volume |
| 12 | Stop secondary | Stop gluster2, verify access via gluster1 |
| 13 | Remove volume | Clean removal of cluster volume |

## Manual Testing

```bash
# Create volume with failover support
docker volume create -d antoniospatera/glusterfs:next \
  -o servers=172.28.0.10,172.28.0.11 \
  -o volname=gv0 \
  -o subdir=mydata \
  -o backup-volfile-servers=172.28.0.11 \
  testvol

# Use volume
docker run -it --rm -v testvol:/data alpine sh

# Inside container
echo "Hello GlusterFS" > /data/test.txt
cat /data/test.txt
exit

# Remove volume
docker volume rm testvol
```

## Troubleshooting

### Plugin logs
```bash
# View logs (syslog)
sudo tail -f /var/log/messages | grep -i gluster

# Or via journalctl
journalctl -u docker.service | grep -i gluster

# Plugin info
docker plugin inspect antoniospatera/glusterfs:next
```

### GlusterFS status
```bash
# Peer status
docker exec gluster1 gluster peer status

# Volume status
docker exec gluster1 gluster volume info gv0
docker exec gluster1 gluster volume status gv0

# Heal status (cluster)
docker exec gluster1 gluster volume heal gv0 info
```

### Mount issues
```bash
# Check host mounts
mount | grep gluster
cat /proc/mounts | grep gluster

# Check plugin state
PLUGIN_ID=$(docker plugin inspect antoniospatera/glusterfs:next --format '{{.Id}}')
sudo cat /var/lib/docker/plugins/${PLUGIN_ID}/propagated-mount/.state/gfs-state.json
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PLUGIN_NAME` | `antoniospatera/glusterfs:next` | Plugin name to test |
| `SERVERS` | `172.28.0.10,172.28.0.11` | GlusterFS servers |
| `VOLNAME` | `gv0` | GlusterFS volume name |
| `COLLECT_LOGS` | `true` | Enable/disable log collection |
| `LOG_DIR` | `./logs` | Directory for log files |

Example:
```bash
PLUGIN_NAME=myregistry/glusterfs:v1.0 ./run-tests.sh
```

## Log Collection

Tests automatically collect diagnostic logs to `./logs/` directory:

- **On success**: Logs saved at end of test run
- **On failure**: Logs saved immediately with failure context
- **Cluster tests**: Additional logs during failover and recovery

Log files include:
- Plugin status and inspect output
- Docker volumes list
- GlusterFS mounts (`/proc/mounts`)
- Plugin logs from journalctl and /var/log/messages
- GlusterFS volume info and status
- GlusterFS heal info (cluster tests)

### Disable log collection
```bash
COLLECT_LOGS=false ./run-tests.sh
```

### Custom log directory
```bash
LOG_DIR=/var/log/glusterfs-tests ./run-tests-cluster.sh
```

### View logs
```bash
# List log files
ls -la ./logs/

# View latest log
cat ./logs/cluster-test-*.log | less

# Filter plugin messages
grep -i "plugin=" ./logs/*.log
```
