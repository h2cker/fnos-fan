package api

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/h2cker/fnos-fan/internal/config"
	"github.com/h2cker/fnos-fan/internal/control"
)

func TestHostAllowed(t *testing.T) {
	extra := []string{"nas.example.com"}
	cases := []struct {
		host string
		want bool
	}{
		{"192.168.1.50:7831", true},    // documented LAN access by IP
		{"10.0.0.2:7831", true},        // any private IP
		{"127.0.0.1:7831", true},       // healthcheck / loopback
		{"[fe80::1]:7831", true},       // IPv6 literal
		{"localhost:7831", true},       // loopback name
		{"fnos.local:7831", true},      // mDNS
		{"nas.example.com:7831", true}, // in ALLOWED_HOSTS
		{"evil.com:7831", false},       // DNS-rebinding host
		{"attacker.tld", false},        // no port, still rejected
	}
	for _, c := range cases {
		if got := hostAllowed(c.host, extra); got != c.want {
			t.Errorf("hostAllowed(%q) = %v, want %v", c.host, got, c.want)
		}
	}
}

func TestSameOrigin(t *testing.T) {
	mk := func(origin, secFetch string) *http.Request {
		r := httptest.NewRequest(http.MethodPost, "http://192.168.1.50:7831/api/config", nil)
		r.Host = "192.168.1.50:7831"
		if origin != "" {
			r.Header.Set("Origin", origin)
		}
		if secFetch != "" {
			r.Header.Set("Sec-Fetch-Site", secFetch)
		}
		return r
	}
	cases := []struct {
		name             string
		origin, secFetch string
		want             bool
	}{
		{"same-origin UI fetch", "http://192.168.1.50:7831", "same-origin", true},
		{"cross-site attack page", "http://evil.com", "cross-site", false},
		{"origin mismatch beats matching sec-fetch", "http://evil.com", "same-origin", false},
		{"no headers (curl)", "", "", true},
		{"sec-fetch cross-site, no origin", "", "cross-site", false},
	}
	for _, c := range cases {
		if got := sameOrigin(mk(c.origin, c.secFetch)); got != c.want {
			t.Errorf("%s: sameOrigin = %v, want %v", c.name, got, c.want)
		}
	}
}

// TestGuardIntegration exercises the full handler stack the way a browser would.
func TestGuardIntegration(t *testing.T) {
	srv := New(control.New(config.Default(), nil), "", nil).Handler()

	do := func(method, host, origin, body string) int {
		r := httptest.NewRequest(method, "http://"+host+"/api/config", strings.NewReader(body))
		r.Host = host
		if origin != "" {
			r.Header.Set("Origin", origin)
		}
		if body != "" {
			r.Header.Set("Content-Type", "application/json")
		}
		w := httptest.NewRecorder()
		srv.ServeHTTP(w, r)
		return w.Code
	}

	validCfg := `{"mode":"manual","manual_pwm":120,"min_pwm":60,"interval_sec":5,"curve":[{"temp_c":35,"pwm":60},{"temp_c":75,"pwm":255}]}`

	// Legit same-origin write from the UI succeeds.
	if code := do(http.MethodPost, "192.168.1.50:7831", "http://192.168.1.50:7831", validCfg); code != http.StatusOK {
		t.Errorf("same-origin POST: got %d, want 200", code)
	}
	// Classic CSRF: cross-site page, Origin does not match Host.
	if code := do(http.MethodPost, "192.168.1.50:7831", "http://evil.com", validCfg); code != http.StatusForbidden {
		t.Errorf("cross-origin POST: got %d, want 403", code)
	}
	// DNS-rebinding: Origin matches the (untrusted) Host, but Host is a domain.
	if code := do(http.MethodPost, "evil.com", "http://evil.com", validCfg); code != http.StatusForbidden {
		t.Errorf("rebinding POST: got %d, want 403", code)
	}
	// Read of status via a rebound host is also refused.
	if code := do(http.MethodGet, "evil.com", "", ""); code != http.StatusForbidden {
		t.Errorf("rebinding GET: got %d, want 403", code)
	}
}
