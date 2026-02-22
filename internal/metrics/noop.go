package metrics

import "time"

type noopRecorder struct{}

func (n *noopRecorder) SetVolumesTotal(int)                        {}
func (n *noopRecorder) SetVolumesMounted(int)                      {}
func (n *noopRecorder) SetVolumeConnections(string, int)           {}
func (n *noopRecorder) RemoveVolumeConnections(string)             {}
func (n *noopRecorder) ObserveMountDuration(string, time.Duration) {}
func (n *noopRecorder) IncMountOps(string, string)                 {}
func (n *noopRecorder) IncMountError(string)                       {}
