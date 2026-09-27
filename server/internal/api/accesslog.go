package api

import (
	"log"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/gin-gonic/gin"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
)

// ASVS V14.2.1 / V16.2.1: request logs record the route template, status, and
// latency. They omit the raw URL, query string, body, cookies, and Authorization
// so tokens and passwords cannot land in Loki.
func accessLog() gin.HandlerFunc {
	return func(c *gin.Context) {
		start := time.Now()
		c.Next()
		route := c.FullPath()
		if route == "" {
			route = "unmatched"
		}
		log.Printf("event=http method=%s route=%s status=%d latency_ms=%d bytes=%d ip=%s request_id=%s",
			c.Request.Method, route, c.Writer.Status(), time.Since(start).Milliseconds(), c.Writer.Size(), c.ClientIP(), reqID(c))
	}
}

// ASVS V16.3.1: authentication outcomes are recorded without the password,
// session token, or the submitted username.
func logAuth(result, reason, ip string) {
	log.Printf("event=auth result=%s reason=%s ip=%s", result, reason, ip)
}

var (
	httpRequests = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "tokenlibrary_http_requests_total",
		Help: "HTTP requests handled by the library API, labeled by route template.",
	}, []string{"method", "route", "status"})
	httpDuration = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "tokenlibrary_http_request_duration_seconds",
		Help:    "HTTP request latency by route template.",
		Buckets: []float64{0.01, 0.05, 0.1, 0.25, 0.5, 1, 2, 5, 15, 60},
	}, []string{"method", "route"})
	authAttempts = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "tokenlibrary_auth_attempts_total",
		Help: "Login outcomes. The result label is success, failure, rate_limited, or busy.",
	}, []string{"result"})
	syncRequests = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "tokenlibrary_sync_requests_total",
		Help: "Sync, upload, and blob requests by device. Device names are truncated and contain no credentials.",
	}, []string{"platform", "device", "kind", "status"})
	syncLast = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Name: "tokenlibrary_sync_last_unix_seconds",
		Help: "Unix time of the latest successful sync request from a device.",
	}, []string{"platform", "device"})
)

func cleanPlatform(value string) string {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "ios", "mac", "swift":
		return strings.ToLower(strings.TrimSpace(value))
	default:
		return ""
	}
}

func cleanDeviceName(value string) string {
	value = strings.TrimSpace(value)
	if value == "" || strings.ContainsAny(value, "\r\n\t") {
		return ""
	}
	if utf8.RuneCountInString(value) > 40 {
		runes := []rune(value)
		value = string(runes[:40])
	}
	return value
}

func syncKind(route string) (string, bool) {
	switch {
	case strings.HasPrefix(route, "/api/v1/sync/changes"), strings.HasPrefix(route, "/api/v1/sync/snapshots"):
		return "pull", true
	case strings.Contains(route, "/sync/operations"), strings.HasPrefix(route, "/api/v1/uploads"), strings.HasPrefix(route, "/api/v1/blobs"):
		return "push", true
	default:
		return "", false
	}
}

func observeHTTP() gin.HandlerFunc {
	return func(c *gin.Context) {
		start := time.Now()
		c.Next()
		route := c.FullPath()
		if route == "" {
			route = "unmatched"
		}
		status := strconv.Itoa(c.Writer.Status())
		httpRequests.WithLabelValues(c.Request.Method, route, status).Inc()
		httpDuration.WithLabelValues(c.Request.Method, route).Observe(time.Since(start).Seconds())
		kind, tracked := syncKind(route)
		if !tracked {
			return
		}
		platform, device := "unknown", "unknown"
		if raw, ok := c.Get("session"); ok {
			if info, ok := raw.(sessionInfo); ok {
				if info.Platform != "" {
					platform = info.Platform
				}
				if info.Name != "" {
					device = info.Name
				}
			}
		}
		syncRequests.WithLabelValues(platform, device, kind, status).Inc()
		if c.Writer.Status() < 400 {
			syncLast.WithLabelValues(platform, device).SetToCurrentTime()
		}
		log.Printf("event=sync platform=%s device=%q kind=%s route=%s status=%s", platform, device, kind, route, status)
	}
}
