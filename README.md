# Docker volume plugin for GlusterFS

![Docker Pulls](https://img.shields.io/docker/pulls/antoniospatera/glusterfs)
![GitHub stars](https://img.shields.io/github/stars/antoniospatera/docker-volume-glusterfs)
![License](https://img.shields.io/github/license/antoniospatera/docker-volume-glusterfs)

This is a managed Docker volume plugin to allow Docker containers to access
GlusterFS volumes. The GlusterFS client does not need to be installed on the
host and everything is managed within the plugin.

## Usage

1 - Install the plugin

```
docker plugin install --alias glusterfs antoniospatera/glusterfs:latest

# optional you can set a default server list and/or volume
docker plugin install --alias glusterfs antoniospatera/glusterfs SERVERS=<server1,server2,...,serverN> VOLNAME=<volname>

# or to enable debug
docker plugin install --alias glusterfs antoniospatera/glusterfs DEBUG=1
```

2 - Create a volume

> Make sure the **_gluster volume exists_**.
>
> Or the mounting of the volume will fail.

```
$ docker volume create -d glusterfs -o servers=<server1,server2,...,serverN> -o volname=<volname> -o subdir=<subdir> glustervolume
glustervolume
$ docker volume ls
DRIVER           VOLUME NAME
glusterfs:next   glustervolume
```

or if you set the defaults for the plugin, you can create a volume without any options:

```
$ docker volume create -d glusterfs glustervolume
glustervolume
$ docker volume ls
DRIVER           VOLUME NAME
glusterfs:next   glustervolume
```

3 - Use the volume

```
$ docker run -it -v glustervolume:<path> bash ls <path>
```

## Options

- servers [required, if no default set]: A comma-separated list of servers e.g.: 192.168.2.1,192.168.1.1
- volname [required, if no default set]: The name of the glusterfs volume e.g.: gv0. Needs to be defined on the glusterfs cluster.
- subdir [optional, default: volume name]: The name of the subdir. Will be created, if not found.

For additional options see [man mount.glusterfs](https://github.com/gluster/glusterfs/blob/release-6/doc/mount.glusterfs.8).

## High Availability and Failover

GlusterFS supports native failover when multiple servers are specified:

```bash
# Multiple servers for HA
docker volume create -d glusterfs \
  -o servers=srv1,srv2,srv3 \
  -o volname=gv0 \
  testvol

# Or with backup-volfile-servers option (recommended for faster failover)
docker volume create -d glusterfs \
  -o servers=srv1 \
  -o volname=gv0 \
  -o backup-volfile-servers=srv2:srv3 \
  testvol
```

**Failover behavior:**

```
Initial mount:                    During operation:

srv1,srv2:/gv0                    Container using volume
    │                                     │
    ▼                                     ▼
┌───────┐  ┌───────┐              ┌───────┐  ┌───────┐
│ srv1  │  │ srv2  │              │ srv1  │  │ srv2  │
│ DOWN  │  │  UP   │              │ conn  │  │ stdby │
└───────┘  └───────┘              └───────┘  └───────┘
    │          │                      │
    ▼          │                  srv1 DOWN!
  FAIL ────────┘                      │
               │                      ▼
               ▼              Auto-reconnect to srv2
         CONNECT OK                   │
         Mount success                ▼
                              I/O continues (brief pause)
```

## Volume Mount Lifecycle

### Normal Flow

```
1. CREATE VOLUME
   docker volume create -d glusterfs ...
   └─► Plugin saves config, Connections=0, saveState()

2. FIRST CONTAINER MOUNTS
   docker run -v testvol:/data ...
   └─► Plugin checks isMounted() → NO
       └─► mount -t glusterfs srv:/vol /mnt/volumes/xxx
       └─► Connections++ (0→1), saveState()

3. SECOND CONTAINER MOUNTS (same volume)
   docker run -v testvol:/data ...
   └─► Plugin checks isMounted() → YES, Connections > 0
       └─► Skip mount (already mounted)
       └─► Connections++ (1→2), saveState()

4. CONTAINER STOPS
   docker stop container1
   └─► Connections-- (2→1), saveState()
       └─► Connections > 0, skip unmount

5. LAST CONTAINER STOPS
   docker stop container2
   └─► Connections-- (1→0), saveState()
       └─► unmountVolume()
           ├─► isMounted()? YES
           ├─► umount /mnt/volumes/xxx
           │   ├─► OK → done
           │   └─► FAIL → umount -l (lazy fallback)
           └─► done

6. REMOVE VOLUME
   docker volume rm testvol
   └─► Connections == 0? YES
       └─► isMounted()? → force unmount if orphan
       └─► rm -rf mountpoint
       └─► delete from state, saveState()
```

### Cleanup Mechanism

The plugin automatically synchronizes the `Connections` counter with actual mount state to handle edge cases like crashes or killed containers.

**Cleanup runs:**
- At plugin startup
- Before volume removal

```
PLUGIN STARTUP
      │
      ▼
  cleanup()
      │
      ▼
  For each volume:
      │
      ├─► Case 1: NOT mounted but Connections > 0
      │   (container killed without Unmount)
      │   └─► Reset Connections = 0, saveState()
      │
      └─► Case 2: Mounted but Connections == 0
          (orphan mount from crash)
          └─► Force unmount, saveState()


VOLUME REMOVE
      │
      ▼
  Sync single volume:
      │
      ├─► NOT mounted && Connections > 0?
      │   └─► Reset Connections = 0
      │
      ├─► Connections != 0?
      │   └─► ERROR: volume in use
      │
      └─► Still mounted?
          └─► Force unmount, then remove
```

### Edge Cases Handling

**A. Plugin Crash/Restart Recovery**

```
Before crash:              After restart:

state.json:                cleanup() runs:
  connections: 2           ├─► isMounted()? YES
                           ├─► Connections > 0? YES
/proc/mounts:              └─► State OK, no action
  srv:/gv0 mounted
                           New mount request:
                           └─► Skip mount (already mounted)
                               Connections++ (2→3)
```

**B. Container Killed Without Unmount (Swarm)**

```
Before kill:               After cleanup:

state.json:                cleanup() runs:
  connections: 2           ├─► isMounted()? NO
                           ├─► Connections > 0? YES
/proc/mounts:              └─► Reset Connections = 0
  (not mounted)                saveState()

                           Remove() now works!
```

**C. Mount Busy (open files)**

```
Unmount with Connections=0
         │
         ▼
umount /mnt/volumes/xxx
         │
         ▼
ERROR: target is busy
         │
         ▼
umount -l /mnt/volumes/xxx (LAZY)
         │
         ▼
OK - mount detached from namespace
   - actual cleanup when all fd closed
```

**D. Orphan Mount (mounted but Connections=0)**

```
state.json:               cleanup() or Remove():
  connections: 0          │
                          ├─► isMounted()? YES
/proc/mounts:             ├─► Connections == 0? YES
  srv:/gv0 MOUNTED        └─► Force unmount
  (orphan!)                   OK, volume clean
```

## State Persistence

The plugin persists volume state in `/mnt/volumes/.state/gfs-state.json`:

```json
{
  "testvol": {
    "connections": 2,
    "Name": "testvol",
    "Subdir": "mydata",
    "SubdirMountpoint": "/mnt/volumes/abc123/mydata",
    "Servers": ["192.168.1.10", "192.168.1.11"],
    "Volname": "gv0",
    "Options": ["backup-volfile-servers=192.168.1.12"],
    "Mountpoint": "/mnt/volumes/abc123"
  }
}
```

This path is inside the plugin's `propagatedMount` which Docker manages automatically based on its `data-root` configuration.

## Building from Source

### Using the build script (recommended)

```bash
# Build and install plugin
sudo ./scripts/build.sh install

# Or step by step
sudo ./scripts/build.sh build     # Build only
sudo ./scripts/build.sh enable    # Enable plugin
sudo ./scripts/build.sh disable   # Disable plugin
sudo ./scripts/build.sh clean     # Remove build artifacts

# Custom tag
sudo ./scripts/build.sh -t v1.0 install
```

### Using Make

```bash
sudo make clean rootfs create
sudo docker plugin enable antoniospatera/glusterfs:next
```

## Project Structure

```
docker-volume-glusterfs/
├── main.go              # Plugin source code
├── config.json          # Plugin configuration
├── Dockerfile           # Build image (Debian Bookworm Slim)
├── Makefile
├── go.mod / go.sum      # Go modules
├── scripts/
│   └── build.sh         # Build and install script
├── tests/
│   ├── integration/     # Integration tests
│   └── pr10-volume-prune/  # Regression tests
└── README.md
```

## Supported tags

- `antoniospatera/glusterfs:latest` - Debian Bookworm Slim
- `antoniospatera/glusterfs:next` - Development version

> **Note:** This is a maintained fork of the archived [mikebarkmin/docker-volume-glusterfs](https://github.com/mikebarkmin/docker-volume-glusterfs) project.

## Tests

```
tests/
├── integration/              # Integration tests
│   ├── setup/                # GlusterFS cluster setup
│   ├── run-tests.sh          # Single-node tests (10 tests)
│   ├── run-tests-cluster.sh  # Cluster/failover tests (13 tests)
│   └── README.md
└── pr10-volume-prune/        # PR #10 regression test (4 tests)
    └── run-test.sh
```

### Running Tests

```bash
# Integration tests (requires GlusterFS cluster)
cd tests/integration
sudo ./setup/setup-cluster.sh      # Start 2-node cluster
sudo ./run-tests.sh                # Run single-node tests
sudo ./run-tests-cluster.sh        # Run cluster/failover tests
sudo ./setup/cleanup.sh            # Cleanup

# PR #10 regression test
cd tests/pr10-volume-prune
sudo ./run-test.sh
```

See [tests/integration/README.md](tests/integration/README.md) for detailed documentation.

## TODO

- Add retry with exponential backoff before lazy unmount (handles temporary I/O errors)
- Add optional periodic cleanup goroutine for heavy Swarm environments (configurable via `CLEANUP_INTERVAL` env)

## LICENSE

MIT
