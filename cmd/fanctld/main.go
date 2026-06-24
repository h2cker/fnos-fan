// Command fanctld is the fan-control daemon: it discovers hwmon sensors, runs
// the control loop, and serves the web UI. The kernel module that exposes the
// sensors is loaded by the container entrypoint before this binary starts.
//
// Fan control never depends on the web server: if the HTTP listener fails
// (port in use, bad bind address) the control loop keeps running.
package main

import (
	"context"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"

	"github.com/h2cker/fnos-fan/internal/api"
	"github.com/h2cker/fnos-fan/internal/config"
	"github.com/h2cker/fnos-fan/internal/control"
	"github.com/h2cker/fnos-fan/internal/hwmon"
)

func main() {
	cfgPath := envOr("FANCTL_CONFIG", "/data/config.json")
	port := envOr("WEB_PORT", "7831")
	// Bind localhost by default: a privileged box that can stop fans must not be
	// reachable unauthenticated on the LAN. Set BIND=0.0.0.0 to expose it (and
	// put auth / a reverse proxy in front — see README).
	bind := envOr("BIND", "127.0.0.1")

	cfg, err := config.Load(cfgPath)
	if err != nil {
		log.Printf("config: %v (using defaults)", err)
	}

	chips, err := hwmon.Scan()
	if err != nil {
		log.Printf("hwmon scan: %v (no sensors visible)", err)
	}
	log.Printf("discovered %d hwmon chip(s)", len(chips))
	for _, c := range chips {
		log.Printf("  %-12s %s  fans=%d temps=%d pwms=%d", c.Name, c.Path, len(c.Fans), len(c.Temps), len(c.PWMs))
	}

	ctrl := control.New(cfg, chips)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	go ctrl.Run(ctx)

	// Web UI is best-effort; a bind failure must not kill fan control.
	addr := net.JoinHostPort(bind, port)
	srv := &http.Server{Handler: api.New(ctrl).Handler()}
	if ln, lerr := net.Listen("tcp", addr); lerr != nil {
		log.Printf("web UI disabled: cannot listen on %s: %v", addr, lerr)
	} else {
		go func() {
			log.Printf("web UI listening on %s", addr)
			if e := srv.Serve(ln); e != nil && e != http.ErrServerClosed {
				log.Printf("web UI stopped: %v", e)
			}
		}()
	}

	<-ctx.Done()
	log.Println("shutting down — failsafe: fans -> 100%")
	ctrl.Failsafe()
	_ = srv.Close()
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
