// Package api serves the JSON control API and the embedded web UI.
package api

import (
	"crypto/subtle"
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"net/http"
	"sort"

	"github.com/h2cker/fnos-fan/internal/config"
	"github.com/h2cker/fnos-fan/internal/control"
)

//go:embed web
var webFS embed.FS

// Server wires HTTP handlers to the controller.
type Server struct {
	ctrl  *control.Controller
	token string // optional HTTP Basic password; "" disables auth
}

func New(ctrl *control.Controller, token string) *Server {
	return &Server{ctrl: ctrl, token: token}
}

// Handler returns the configured HTTP mux, wrapped in Basic auth if a token is set.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/api/status", s.handleStatus)
	mux.HandleFunc("/api/config", s.handleConfig)

	sub, _ := fs.Sub(webFS, "web")
	mux.Handle("/", http.FileServer(http.FS(sub)))

	if s.token == "" {
		return mux
	}
	return s.requireAuth(mux)
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

func (s *Server) handleStatus(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, s.ctrl.Snapshot())
}

func (s *Server) handleConfig(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		writeJSON(w, s.ctrl.Config())
	case http.MethodPost:
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
