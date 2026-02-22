package metrics

import (
	"fmt"
	"net/http"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"github.com/sirupsen/logrus"
)

type prometheusRecorder struct {
	volumesTotal      prometheus.Gauge
	volumesMounted    prometheus.Gauge
	volumeConnections *prometheus.GaugeVec
	mountOpsTotal     *prometheus.CounterVec
	mountDuration     *prometheus.HistogramVec
	mountErrorsTotal  *prometheus.CounterVec
}

func newPrometheusRecorder(port int) *prometheusRecorder {
	r := &prometheusRecorder{
		volumesTotal: prometheus.NewGauge(prometheus.GaugeOpts{
			Name: "glusterfs_volumes_total",
			Help: "Total number of volumes created.",
		}),
		volumesMounted: prometheus.NewGauge(prometheus.GaugeOpts{
			Name: "glusterfs_volumes_mounted",
			Help: "Number of currently mounted volumes.",
		}),
		volumeConnections: prometheus.NewGaugeVec(prometheus.GaugeOpts{
			Name: "glusterfs_volume_connections",
			Help: "Active connections per volume.",
		}, []string{"volume"}),
		mountOpsTotal: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "glusterfs_mount_operations_total",
			Help: "Total mount/unmount operations.",
		}, []string{"operation", "status"}),
		mountDuration: prometheus.NewHistogramVec(prometheus.HistogramOpts{
			Name:    "glusterfs_mount_duration_seconds",
			Help:    "Duration of mount/unmount operations.",
			Buckets: []float64{0.1, 0.5, 1, 2, 5, 10, 30},
		}, []string{"operation"}),
		mountErrorsTotal: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "glusterfs_mount_errors_total",
			Help: "Total mount errors by type.",
		}, []string{"error_type"}),
	}

	prometheus.MustRegister(
		r.volumesTotal,
		r.volumesMounted,
		r.volumeConnections,
		r.mountOpsTotal,
		r.mountDuration,
		r.mountErrorsTotal,
	)

	go func() {
		addr := fmt.Sprintf(":%d", port)
		mux := http.NewServeMux()
		mux.Handle("/metrics", promhttp.Handler())
		logrus.Infof("metrics: listening on %s", addr)
		if err := http.ListenAndServe(addr, mux); err != nil {
			logrus.Errorf("metrics: server error: %v", err)
		}
	}()

	return r
}

func (r *prometheusRecorder) SetVolumesTotal(count int) {
	r.volumesTotal.Set(float64(count))
}

func (r *prometheusRecorder) SetVolumesMounted(count int) {
	r.volumesMounted.Set(float64(count))
}

func (r *prometheusRecorder) SetVolumeConnections(volume string, connections int) {
	r.volumeConnections.WithLabelValues(volume).Set(float64(connections))
}

func (r *prometheusRecorder) RemoveVolumeConnections(volume string) {
	r.volumeConnections.DeleteLabelValues(volume)
}

func (r *prometheusRecorder) ObserveMountDuration(operation string, duration time.Duration) {
	r.mountDuration.WithLabelValues(operation).Observe(duration.Seconds())
}

func (r *prometheusRecorder) IncMountOps(operation string, status string) {
	r.mountOpsTotal.WithLabelValues(operation, status).Inc()
}

func (r *prometheusRecorder) IncMountError(errorType string) {
	r.mountErrorsTotal.WithLabelValues(errorType).Inc()
}
