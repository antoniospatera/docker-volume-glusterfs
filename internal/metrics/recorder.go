package metrics

import "time"

// Recorder abstracts metric collection. The driver calls these methods
// without knowing whether Prometheus is active or not.
type Recorder interface {
	SetVolumesTotal(count int)
	SetVolumesMounted(count int)
	SetVolumeConnections(volume string, connections int)
	RemoveVolumeConnections(volume string)
	ObserveMountDuration(operation string, duration time.Duration)
	IncMountOps(operation string, status string)
	IncMountError(errorType string)
}

// NewRecorder returns a prometheusRecorder if enabled is true,
// otherwise a noopRecorder. When enabled, it also starts the
// HTTP metrics server on the given port.
func NewRecorder(enabled bool, port int) Recorder {
	if !enabled {
		return &noopRecorder{}
	}
	return newPrometheusRecorder(port)
}
