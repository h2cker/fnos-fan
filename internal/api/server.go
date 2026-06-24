// Package api serves the JSON control API and the embedded web UI.
package api

import (
	"crypto/subtle"
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"net"
	"net/http"
	"net/url"
	"sort"
	"strings"

	"github.com/h2cker/fnos-fan/internal/config"
	"github.com/h2cker/fnos-fan/internal/control"
)

//go:embed web
var webFS embed.FS

// Server wires HTTP handlers to the controller.
type Server struct {
	ctrl         *control.Controller
	token        string   // optional HTTP Basic password; "" disables auth
	allowedHosts []string // extra Host names accepted besides IPs/localhost/*.local
}

func New(ctrl *control.Controller, token string, allowedHosts []string) *Server {
	return &Server{ctrl: ctrl, token: token, allowedHosts: allowedHosts}
}

// Handler returns the configured HTTP mux, wrapped in Basic auth (if a token is
// set) and the always-on browser guard (anti DNS-rebinding + anti-CSRF).
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/api/status", s.handleStatus)
	mux.HandleFunc("/api/config", s.handleConfig)

	sub, _ := fs.Sub(webFS, "web")
	mux.Handle("/", http.FileServer(http.FS(sub)))

	var h http.Handler = mux
	if s.token != "" {
		h = s.requireAuth(h)
	}
	// Outermost: reject untrusted Host (DNS-rebinding) and cross-site writes
	// (CSRF) before auth or routing. Direct LAN access by IP is unaffected.
	return s.guard(h)
}

// requireAuth enforces HTTP Basic auth (any username, password == token) when
// AUTH_TOKEN is set. Browsers show a native login prompt and then carry the
// cached credentials on the UI's fetch() calls automatically.
func (s *Server) requireAuth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, pass, ok := r.BasicAuth()
		if !ok || subtle.ConstantTimeCompare([]byte(pass), []byte(s.token)) != 1 {
			w.Header().Set("WWW-Authenticate", `Basic realm="fnos-fan", charset="UTF-8"`)
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// guard blocks the two ways a browser on a different site could reach this
// privileged control API from outside the LAN: an untrusted Host header
// (DNS-rebinding) or a cross-site state-changing request (CSRF). Direct LAN
// access by IP, localhost health checks, *.local (mDNS) and names in
// ALLOWED_HOSTS pass through; non-browser clients (curl/scripts) are unaffected.
func (s *Server) guard(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !hostAllowed(r.Host, s.allowedHosts) {
			http.Error(w, "forbidden: untrusted Host header", http.StatusForbidden)
			return
		}
		if r.Method != http.MethodGet && r.Method != http.MethodHead && !sameOrigin(r) {
			http.Error(w, "forbidden: cross-origin request", http.StatusForbidden)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// hostAllowed permits IP literals (the documented NAS access path), localhost,
// mDNS *.local names, and an admin-configured allowlist. It rejects registered
// domain names — which is exactly what a DNS-rebinding attack must use.
func hostAllowed(host string, extra []string) bool {
	h := host
	if hh, _, err := net.SplitHostPort(host); err == nil {
		h = hh
	}
	h = strings.ToLower(strings.TrimSuffix(h, "."))
	if h == "" || h == "localhost" || strings.HasSuffix(h, ".local") {
		return true
	}
	if net.ParseIP(h) != nil {
		return true
	}
	for _, a := range extra {
		if strings.EqualFold(h, a) {
			return true
		}
	}
	return false
}

// sameOrigin reports whether a state-changing request came from the UI itself.
// Browsers attach Origin (or Sec-Fetch-Site) to POSTs and cannot forge a
// matching Origin from a cross-site page; requests with neither header are
// non-browser clients (curl), which CSRF cannot reach.
func sameOrigin(r *http.Request) bool {
	if o := r.Header.Get("Origin"); o != "" {
		u, err := url.Parse(o)
		return err == nil && strings.EqualFold(u.Host, r.Host)
	}
	switch r.Header.Get("Sec-Fetch-Site") {
	case "cross-site", "same-site":
		return false
	default: // "same-origin", "none", or absent (non-browser)
		return true
	}
}

func (s *Server) handleStatus(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, s.ctrl.Snapshot())
}

func (s *Server) handleConfig(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		writeJSON(w, s.ctrl.Config())
	case http.MethodPost:
		r.Body = http.MaxBytesReader(w, r.Body, 64<<10) // a config is well under 64 KiB
		var c config.Config
		if err := json.NewDecoder(r.Body).Decode(&c); err != nil {
			httpError(w, http.StatusBadRequest, err)
			return
		}
		if err := validateConfig(c); err != nil {
			httpError(w, http.StatusBadRequest, err)
			return
		}
		if err := s.ctrl.SetConfig(c); err != nil {
			httpError(w, http.StatusInternalServerError, err)
			return
		}
		writeJSON(w, s.ctrl.Config())
	default:
		httpError(w, http.StatusMethodNotAllowed, errors.New("method not allowed"))
	}
}

// validateConfig rejects values that could damage hardware. The web UI also
// constrains inputs, but the API must defend against curl/Postman/scripts.
func validateConfig(c config.Config) error {
	if c.Mode != "auto" && c.Mode != "manual" {
		return errors.New("mode must be \"auto\" or \"manual\"")
	}
	if c.ManualPWM < 0 || c.ManualPWM > 255 {
		return errors.New("manual_pwm must be 0-255")
	}
	if c.MinPWM < 0 || c.MinPWM > 255 {
		return errors.New("min_pwm must be 0-255")
	}
	if c.IntervalSec < 1 || c.IntervalSec > 3600 {
		return errors.New("interval_sec must be 1-3600")
	}
	if len(c.Curve) < 2 {
		return errors.New("curve needs at least 2 points")
	}
	pts := make([]config.Point, len(c.Curve))
	copy(pts, c.Curve)
	sort.Slice(pts, func(i, j int) bool { return pts[i].TempC < pts[j].TempC })
	for i, p := range pts {
		if p.TempC < 0 || p.TempC > 120 {
			return fmt.Errorf("curve temp_c %d out of range 0-120", p.TempC)
		}
		if p.PWM < 0 || p.PWM > 255 {
			return fmt.Errorf("curve pwm %d out of range 0-255", p.PWM)
		}
		if i > 0 && pts[i].TempC == pts[i-1].TempC {
			return fmt.Errorf("curve has duplicate temp_c %d", p.TempC)
		}
	}
	return nil
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}

func httpError(w http.ResponseWriter, code int, err error) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
}
