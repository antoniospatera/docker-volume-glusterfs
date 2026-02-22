# TODO

## ~~2. Retry with Exponential Backoff~~ ✅

Implemented in `main.go` — `unmountVolume()` retries up to 3 times with exponential backoff (100ms → 200ms → 400ms) before falling back to lazy unmount.

## ~~3. Periodic Cleanup for Swarm Environments~~ ✅

Implemented in `main.go` — configurable via `CLEANUP_INTERVAL` env var (seconds, default `0` = disabled). A background goroutine calls `cleanup()` on a `time.Ticker`.

---

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

