# TODO

## 1. Prometheus Metrics Support

Add optional Prometheus endpoint for monitoring.

### Configuration

```bash
docker plugin install antoniospatera/glusterfs \
  METRICS_ENABLED=true \
  METRICS_PORT=9713
```

| Variable | Default | Description |
|----------|---------|-------------|
| `METRICS_ENABLED` | `false` | Enable Prometheus metrics endpoint |
| `METRICS_PORT` | `9713` | Port for metrics endpoint |

### Metrics Exposed

```
# Volumes
glusterfs_volumes_total              # Total volumes created
glusterfs_volumes_mounted            # Currently mounted volumes
glusterfs_volume_connections{volume} # Connections per volume

# Operations
glusterfs_mount_operations_total{operation="mount|unmount",status="success|error"}
glusterfs_mount_duration_seconds{operation="mount|unmount"}
glusterfs_mount_errors_total{error_type="connection|timeout|busy"}
```

### Prometheus Scrape Config

```yaml
scrape_configs:
  - job_name: 'glusterfs-plugin'
    static_configs:
      - targets: ['docker-node1:9713', 'docker-node2:9713']
```

### Dependencies

```
github.com/prometheus/client_golang/prometheus
github.com/prometheus/client_golang/prometheus/promhttp
```

---

## 2. Retry with Exponential Backoff

Add retry mechanism before falling back to lazy unmount (handles temporary I/O errors).

### Configuration

```bash
docker plugin install antoniospatera/glusterfs \
  UNMOUNT_RETRIES=3 \
  UNMOUNT_BACKOFF_MS=100
```

| Variable | Default | Description |
|----------|---------|-------------|
| `UNMOUNT_RETRIES` | `3` | Number of retries before lazy unmount |
| `UNMOUNT_BACKOFF_MS` | `100` | Initial backoff in milliseconds |

### Behavior

```
unmount attempt 1 → FAIL → wait 100ms
unmount attempt 2 → FAIL → wait 200ms
unmount attempt 3 → FAIL → wait 400ms
unmount attempt 4 → FAIL → lazy unmount (fallback)
```

### Implementation

```go
func unmountWithRetry(path string, maxRetries int, initialBackoff time.Duration) error {
    backoff := initialBackoff
    for i := 0; i <= maxRetries; i++ {
        if err := syscall.Unmount(path, 0); err == nil {
            return nil
        }
        if i < maxRetries {
            log.Printf("Unmount attempt %d failed, retrying in %v", i+1, backoff)
            time.Sleep(backoff)
            backoff *= 2
        }
    }
    // Fallback to lazy unmount
    log.Printf("All retries failed, using lazy unmount")
    return syscall.Unmount(path, syscall.MNT_DETACH)
}
```

---

## 3. Periodic Cleanup for Swarm Environments

Add optional background goroutine for periodic state synchronization in heavy Docker Swarm environments.

### Configuration

```bash
docker plugin install antoniospatera/glusterfs \
  CLEANUP_INTERVAL=300
```

| Variable | Default | Description |
|----------|---------|-------------|
| `CLEANUP_INTERVAL` | `0` | Cleanup interval in seconds (0 = disabled) |

### Behavior

- `CLEANUP_INTERVAL=0` (default): disabled
- `CLEANUP_INTERVAL=300`: run cleanup every 5 minutes

### Cleanup Actions

1. Sync connection counter with actual mount state
2. Reset `Connections=0` for volumes not mounted
3. Force unmount orphan mounts (mounted but `Connections=0`)

### Implementation

```go
func startPeriodicCleanup(interval time.Duration) {
    if interval == 0 {
        log.Println("Periodic cleanup disabled")
        return
    }

    log.Printf("Starting periodic cleanup every %v", interval)
    ticker := time.NewTicker(interval)

    go func() {
        for range ticker.C {
            log.Println("Running periodic cleanup...")
            d.cleanup()
        }
    }()
}
```

### Use Cases

- Docker Swarm with high container churn
- Environments where containers are frequently killed (not stopped gracefully)
- Systems with unreliable networking causing mount state inconsistencies
