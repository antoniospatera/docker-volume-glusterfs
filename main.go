package main

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"
	"io/ioutil"
	"log"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/docker/go-plugins-helpers/volume"
	"github.com/sirupsen/logrus"
)

const socketAddress = "/run/docker/plugins/glusterfs.sock"

type glusterfsVolume struct {
	Connections      int `json:"connections"`
	Name             string
	Subdir           string
	SubdirMountpoint string
	Servers          []string
	Volname          string
	Options          []string
	Mountpoint       string
}

type glusterfsDriver struct {
	sync.RWMutex

	root            string
	statePath       string
	volumes         map[string]*glusterfsVolume
	defaultVolname  string
	defaultServers  string
	cleanupInterval time.Duration
}

func newGlusterfsDriver(root string, defaultServers string, defaultVolname string, cleanupInterval time.Duration) (*glusterfsDriver, error) {
	logrus.WithField("method", "new driver").Debug(root)

	d := &glusterfsDriver{
		root:            root,
		statePath:       filepath.Join(root, ".state", "gfs-state.json"),
		volumes:         map[string]*glusterfsVolume{},
		defaultVolname:  defaultVolname,
		defaultServers:  defaultServers,
		cleanupInterval: cleanupInterval,
	}

	data, err := ioutil.ReadFile(d.statePath)
	if err != nil {
		if os.IsNotExist(err) {
			logrus.WithField("statePath", d.statePath).Debug("no state found")
		} else {
			return nil, err
		}
	} else {
		if err := json.Unmarshal(data, &d.volumes); err != nil {
			return nil, err
		}
	}

	// Cleanup orphan connections at startup
	d.cleanup()

	return d, nil
}

// cleanup synchronizes Connections counter with actual mount state
func (d *glusterfsDriver) cleanup() {
	d.Lock()
	defer d.Unlock()

	logrus.Info("cleanup: checking for orphan mounts and connections")

	changed := false
	for name, v := range d.volumes {
		mounted := isMounted(v.Mountpoint)

		if !mounted && v.Connections > 0 {
			// Volume not mounted but connections > 0 → reset counter
			logrus.WithField("volume", name).Warnf("cleanup: resetting orphan connections %d → 0", v.Connections)
			v.Connections = 0
			changed = true
		}

		if mounted && v.Connections == 0 {
			// Volume mounted but connections = 0 → force unmount
			logrus.WithField("volume", name).Warn("cleanup: unmounting orphan mount")
			// unmountVolume doesn't access shared state, safe to call with lock held
			if err := d.unmountVolume(v.Mountpoint); err != nil {
				logrus.WithField("volume", name).Errorf("cleanup: failed to unmount orphan: %v", err)
			}
			changed = true
		}
	}

	if changed {
		d.saveStateUnlocked()
	}

	logrus.Info("cleanup: completed")
}

func (d *glusterfsDriver) startPeriodicCleanup() {
	if d.cleanupInterval == 0 {
		return // disabled
	}
	ticker := time.NewTicker(d.cleanupInterval)
	go func() {
		for range ticker.C {
			logrus.Info("periodic cleanup: running scheduled cleanup")
			d.cleanup()
		}
	}()
	logrus.Infof("periodic cleanup: enabled with interval %v", d.cleanupInterval)
}

// saveStateUnlocked saves state without acquiring lock (caller must hold lock)
func (d *glusterfsDriver) saveStateUnlocked() {
	data, err := json.Marshal(d.volumes)
	if err != nil {
		logrus.WithField("statePath", d.statePath).Error(err)
		return
	}

	if err := os.MkdirAll(filepath.Dir(d.statePath), 0755); err != nil {
		logrus.WithField("savestate", d.statePath).Error(err)
		return
	}

	if err := ioutil.WriteFile(d.statePath, data, 0644); err != nil {
		logrus.WithField("savestate", d.statePath).Error(err)
	}
}

func (d *glusterfsDriver) saveState() {
	data, err := json.Marshal(d.volumes)
	if err != nil {
		logrus.WithField("statePath", d.statePath).Error(err)
		return
	}

	// Ensure state directory exists
	if err := os.MkdirAll(filepath.Dir(d.statePath), 0755); err != nil {
		logrus.WithField("savestate", d.statePath).Error(err)
		return
	}

	if err := ioutil.WriteFile(d.statePath, data, 0644); err != nil {
		logrus.WithField("savestate", d.statePath).Error(err)
	}
}

func (d *glusterfsDriver) Create(r *volume.CreateRequest) error {
	logrus.WithField("method", "create").Debugf("%#v", r)

	d.Lock()
	defer d.Unlock()
	v := &glusterfsVolume{
		Subdir:  r.Name,
		Name:    r.Name,
		Volname: d.defaultVolname,
		Servers: strings.Split(d.defaultServers, ","),
	}

	for key, val := range r.Options {
		switch key {
		case "subdir":
			v.Subdir = val
			break
		case "volname":
			v.Volname = val
			break
		case "servers":
			v.Servers = strings.Split(val, ",")
		default:
			if val != "" {
				v.Options = append(v.Options, key+"="+val)
			} else {
				v.Options = append(v.Options, key)
			}
		}
	}

	if v.Subdir == "" {
		return logError("'subdir' option required")
	}

	if v.Volname == "" {
		return logError("'volname' option required")
	}

	if len(v.Servers) < 1 {
		return logError("'servers' option required")
	}

	v.Mountpoint = filepath.Join(d.root, fmt.Sprintf("%x/%x/%x", sha256.Sum256([]byte(v.Name)), sha256.Sum256([]byte(v.Volname)), sha256.Sum256([]byte(v.Subdir))))

	d.volumes[r.Name] = v

	d.saveState()

	return nil
}

// isMounted checks if a path is currently mounted by reading /proc/mounts
func isMounted(target string) bool {
	data, err := ioutil.ReadFile("/proc/mounts")
	if err != nil {
		logrus.WithField("method", "isMounted").Warnf("failed to read /proc/mounts: %v", err)
		return false
	}
	return strings.Contains(string(data), target)
}

// https://socketloop.com/tutorials/golang-determine-if-directory-is-empty-with-os-file-readdir-function
func IsDirEmpty(name string) (bool, error) {
	f, err := os.Open(name)
	if err != nil {
		return false, err
	}
	defer f.Close()

	// read in ONLY one file
	_, err = f.Readdir(1)

	// and if the file is EOF... well, the dir is empty.
	if err == io.EOF {
		return true, nil
	}
	return false, err
}

func (d *glusterfsDriver) Remove(r *volume.RemoveRequest) error {
	logrus.WithField("method", "remove").Debugf("%#v", r)

	d.Lock()
	defer d.Unlock()

	v, ok := d.volumes[r.Name]
	if !ok {
		return logError("volume %s not found", r.Name)
	}

	mounted := isMounted(v.Mountpoint)
	logrus.WithField("volume", r.Name).Debugf("remove: mounted=%v, connections=%d", mounted, v.Connections)

	// Sync connections with actual mount state before checking
	if !mounted && v.Connections > 0 {
		logrus.WithField("volume", r.Name).Warnf("volume not mounted but connections=%d, resetting", v.Connections)
		v.Connections = 0
		d.saveStateUnlocked()
	}

	// If mounted but connections > 0, try to unmount first
	// This handles cases where Docker didn't properly call Unmount (container kill, crash, etc.)
	if mounted && v.Connections > 0 {
		logrus.WithField("volume", r.Name).Warnf("volume mounted with connections=%d, attempting unmount for removal", v.Connections)
		if err := d.unmountVolume(v.Mountpoint); err != nil {
			logrus.WithField("volume", r.Name).Warnf("unmount failed: %v, volume may still be in use", err)
			return logError("volume %s is currently used by a container", r.Name)
		}
		// Unmount succeeded, reset connections
		v.Connections = 0
		d.saveStateUnlocked()
		mounted = false
	}

	if v.Connections != 0 {
		return logError("volume %s is currently used by a container", r.Name)
	}

	// Check if still mounted (orphan mount from crash/restart)
	if mounted {
		logrus.WithField("volume", r.Name).Warn("volume still mounted with 0 connections, forcing unmount")
		if err := d.unmountVolume(v.Mountpoint); err != nil {
			return logError("cannot remove volume %s: unmount failed: %v", r.Name, err)
		}
	}

	empty, err := IsDirEmpty(v.Mountpoint)

	if !empty || err != nil {
		return logError(
			"Directory for volume %s where the volume is mounted is not empty. "+
				"This would result in complete removal of all data. Please stop all "+
				"containers that mount the same volume and subdirectory and try again.",
			r.Name)
	}

	if err := os.RemoveAll(v.Mountpoint); err != nil {
		return logError(err.Error())
	}
	delete(d.volumes, r.Name)
	d.saveState()
	return nil
}

func (d *glusterfsDriver) Path(r *volume.PathRequest) (*volume.PathResponse, error) {
	logrus.WithField("method", "path").Debugf("%#v", r)

	d.RLock()
	defer d.RUnlock()

	v, ok := d.volumes[r.Name]
	if !ok {
		return &volume.PathResponse{}, logError("volume %s not found", r.Name)
	}

	return &volume.PathResponse{Mountpoint: v.Mountpoint}, nil
}

func (d *glusterfsDriver) Mount(r *volume.MountRequest) (*volume.MountResponse, error) {
	logrus.WithField("method", "mount").Debugf("%#v", r)

	d.Lock()
	defer d.Unlock()

	v, ok := d.volumes[r.Name]
	if !ok {
		return &volume.MountResponse{}, logError("volume %s not found", r.Name)
	}

	// Check if already mounted (handles restart/crash recovery)
	alreadyMounted := isMounted(v.Mountpoint)

	if v.Connections == 0 && !alreadyMounted {
		fi, err := os.Lstat(v.Mountpoint)
		if os.IsNotExist(err) {
			if err := os.MkdirAll(v.Mountpoint, 0755); err != nil {
				return &volume.MountResponse{}, logError(err.Error())
			}
		} else if err != nil {
			return &volume.MountResponse{}, logError(err.Error())
		}

		if fi != nil && !fi.IsDir() {
			return &volume.MountResponse{}, logError("%v already exist and it's not a directory", v.Mountpoint)
		}

		if err := d.mountVolume(v); err != nil {
			return &volume.MountResponse{}, logError(err.Error())
		}
	} else if alreadyMounted && v.Connections == 0 {
		// Volume is mounted but counter is 0 (recovery from crash/restart)
		logrus.WithField("volume", r.Name).Info("volume already mounted, recovering state")
		// Ensure SubdirMountpoint is set
		v.SubdirMountpoint = filepath.Join(v.Mountpoint, v.Subdir)
	}

	v.Connections++
	d.saveState()

	return &volume.MountResponse{Mountpoint: v.SubdirMountpoint}, nil
}

func (d *glusterfsDriver) Unmount(r *volume.UnmountRequest) error {
	logrus.WithField("method", "unmount").Debugf("%#v", r)

	d.Lock()
	defer d.Unlock()
	v, ok := d.volumes[r.Name]
	if !ok {
		return logError("volume %s not found", r.Name)
	}

	v.Connections--

	if v.Connections <= 0 {
		v.Connections = 0
		if err := d.unmountVolume(v.Mountpoint); err != nil {
			// Log error but don't fail - mount might already be gone
			logrus.WithField("volume", r.Name).Warnf("unmount error (may be already unmounted): %v", err)
		}
	}

	d.saveState()
	return nil
}

func (d *glusterfsDriver) Get(r *volume.GetRequest) (*volume.GetResponse, error) {
	logrus.WithField("method", "get").Debugf("%#v", r)

	d.Lock()
	defer d.Unlock()

	v, ok := d.volumes[r.Name]
	if !ok {
		return &volume.GetResponse{}, logError("volume %s not found", r.Name)
	}

	return &volume.GetResponse{Volume: &volume.Volume{Name: r.Name, Mountpoint: v.SubdirMountpoint}}, nil
}

func (d *glusterfsDriver) List() (*volume.ListResponse, error) {
	logrus.WithField("method", "list").Debugf("")

	d.Lock()
	defer d.Unlock()

	var vols []*volume.Volume
	for name, v := range d.volumes {
		vols = append(vols, &volume.Volume{Name: name, Mountpoint: v.Mountpoint})
	}
	return &volume.ListResponse{Volumes: vols}, nil
}

func (d *glusterfsDriver) Capabilities() *volume.CapabilitiesResponse {
	logrus.WithField("method", "capabilities").Debugf("")

	return &volume.CapabilitiesResponse{Capabilities: volume.Capability{Scope: "local"}}
}

func (d *glusterfsDriver) mountVolume(v *glusterfsVolume) error {
	cmd := exec.Command("mount", "-t", "glusterfs")

	for _, option := range v.Options {
		cmd.Args = append(cmd.Args, "-o", option)
	}

	var servers = strings.Join(v.Servers, ",")
	var path = fmt.Sprintf("/%s", v.Volname)
	cmd.Args = append(cmd.Args, fmt.Sprintf("%s:%s", servers, path), v.Mountpoint)

	logrus.Debug(cmd.Args)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return logError("glusterfs command execute failed: %v (%s)", err, output)
	}

	var subdir = filepath.Join(v.Mountpoint, v.Subdir)
	fi, err := os.Lstat(subdir)
	if os.IsNotExist(err) {
		if err := os.MkdirAll(subdir, 0755); err != nil {
			return logError(err.Error())
		}
	} else if err != nil {
		return logError(err.Error())
	}

	if fi != nil && !fi.IsDir() {
		return logError("subdir %v already exist and it's not a directory", subdir)
	}

	v.SubdirMountpoint = subdir

	return nil
}

func (d *glusterfsDriver) unmountVolume(target string) error {
	const maxRetries = 3
	initialBackoff := 100 * time.Millisecond

	// Check if actually mounted
	if !isMounted(target) {
		logrus.WithField("target", target).Debug("not mounted, skipping unmount")
		return nil
	}

	// Retry with exponential backoff
	var lastErr error
	backoff := initialBackoff
	for attempt := 1; attempt <= maxRetries; attempt++ {
		logrus.WithField("target", target).Debugf("unmount attempt %d/%d", attempt, maxRetries)
		cmd := exec.Command("umount", target)
		output, err := cmd.CombinedOutput()
		if err == nil {
			logrus.WithField("target", target).Debug("unmount successful")
			return nil
		}
		lastErr = fmt.Errorf("%v (%s)", err, output)
		logrus.WithField("target", target).Warnf("unmount attempt %d/%d failed: %v", attempt, maxRetries, lastErr)
		if attempt < maxRetries {
			time.Sleep(backoff)
			backoff *= 2
		}
	}

	// All retries exhausted, fallback to lazy unmount
	logrus.WithField("target", target).Warnf("all %d unmount attempts failed, trying lazy unmount", maxRetries)
	cmd := exec.Command("umount", "-l", target)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return logError("lazy unmount failed: %v (%s)", err, output)
	}

	logrus.WithField("target", target).Debug("lazy unmount successful")
	return nil
}

func logError(format string, args ...interface{}) error {
	logrus.Errorf(format, args...)
	return fmt.Errorf(format, args...)
}

func main() {
	debug := os.Getenv("DEBUG")
	if ok, _ := strconv.ParseBool(debug); ok {
		logrus.SetLevel(logrus.DebugLevel)
	}

	var cleanupInterval time.Duration
	if envVal := os.Getenv("CLEANUP_INTERVAL"); envVal != "" {
		secs, err := strconv.Atoi(envVal)
		if err != nil || secs < 0 {
			log.Fatalf("invalid CLEANUP_INTERVAL value %q: must be a non-negative integer (seconds)", envVal)
		}
		cleanupInterval = time.Duration(secs) * time.Second
	}

	d, err := newGlusterfsDriver("/mnt/volumes", os.Getenv("SERVERS"), os.Getenv("VOLNAME"), cleanupInterval)
	if err != nil {
		log.Fatal(err)
	}

	d.startPeriodicCleanup()

	h := volume.NewHandler(d)
	u, _ := user.Lookup("root")
	gid, _ := strconv.Atoi(u.Gid)
	logrus.Infof("listening on %s", socketAddress)
	logrus.Error(h.ServeUnix(socketAddress, gid))
}
