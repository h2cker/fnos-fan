// Package control runs the fan-control loop: it samples temperatures, computes
// a target PWM (manual fixed value or auto curve), and writes it to the PWM
// channels. It owns all shared mutable state (cfg, snapshot) and guards it with
// a mutex; the discovered chips slice is immutable after New.
//
// Safety invariants:
//   - Failsafe drives every fan to 100% and is lock-free, so it can run from a
//     panic handler or a shutdown path without risking a deadlock.
//   - If temperature sensors were discovered but ALL of them become unreadable,
//     the loop forces 100% rather than trusting a 0°C reading.
//   - A panic inside the loop triggers Failsafe and then crashes the process so
//     the container restart policy re-establishes control.
package control

import (
	"context"
	"log"
	"sort"
	"sync"
	"time"

	"github.com/h2cker/fnos-fan/internal/config"
	"github.com/h2cker/fnos-fan/internal/hwmon"
)

// Snapshot is the latest sampled state, served to the web UI.
type Snapshot struct {
	Mode       string      `json:"mode"`
	DriveTempC float64     `json:"drive_temp_c"`
	TargetPWM  int         `json:"target_pwm"`
	Emergency  bool        `json:"emergency"`
	UpdatedAt  time.Time   `json:"updated_at"`
	Chips      []ChipState `json:"chips"`
}

type ChipState struct {
	Name  string      `json:"name"`
	Path  string      `json:"path"`
	Fans  []FanState  `json:"fans"`
	Temps []TempState `json:"temps"`
	PWMs  []PWMState  `json:"pwms"`
}

type FanState struct {
	Index int    `json:"index"`
	Label string `json:"label"`
	RPM   int    `json:"rpm"`
	OK    bool   `json:"ok"`
}

type TempState struct {
	Index int     `json:"index"`
	Label string  `json:"label"`
	Path  string  `json:"path"`
	C     float64 `json:"c"`
	OK    bool    `json:"ok"`
}

type PWMState struct {
	Index int    `json:"index"`
	Path  string `json:"path"`
	Value int    `json:"value"`
	OK    bool   `json:"ok"`
}

// Controller drives the fans for a fixed set of discovered chips.
type Controller struct {
	mu         sync.RWMutex
	cfg        *config.Config
	chips      []hwmon.Chip // immutable after New
	totalTemps int          // number of temp sensors discovered at startup
	snap       Snapshot
	lastPWM    int
}

// New returns a controller for the given config and discovered chips.
func New(cfg *config.Config, chips []hwmon.Chip) *Controller {
	n := 0
	for _, ch := range chips {
		n += len(ch.Temps)
	}
	return &Controller{cfg: cfg, chips: chips, totalTemps: n, lastPWM: -1}
}

// Config returns a copy of the current config.
func (c *Controller) Config() config.Config {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return *c.cfg
}

// SetConfig applies and persists a new config.
func (c *Controller) SetConfig(n config.Config) error {
	c.mu.Lock()
	c.cfg.Apply(n)
	c.lastPWM = -1 // force re-apply on next tick
	c.mu.Unlock()
	return c.cfg.Save()
}

// Snapshot returns the latest sampled state.
func (c *Controller) Snapshot() Snapshot {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.snap
}

// Run samples and applies control on each interval until ctx is cancelled.
func (c *Controller) Run(ctx context.Context) {
	c.enableManual()
	for {
		c.tick()
		select {
		case <-ctx.Done():
			return
		case <-time.After(c.interval()):
		}
	}
}

// Failsafe drives all fans to full speed. Lock-free (chips is immutable), so it
// is safe to call from a panic handler or shutdown path.
func (c *Controller) Failsafe() {
	for _, ch := range c.chips {
		for _, p := range ch.PWMs {
			_ = p.SetManual()
			_ = p.Set(255)
		}
	}
}

func (c *Controller) tick() {
	// A bug in the loop must not silently leave fans at a low duty: drive them
	// full, then crash so the container restart re-establishes control.
	defer func() {
		if r := recover(); r != nil {
			c.Failsafe()
			log.Printf("control loop panic: %v — forced fans to 100%%, crashing for restart", r)
			panic(r)
		}
	}()

	c.mu.Lock()
	defer c.mu.Unlock()

	snap := Snapshot{UpdatedAt: time.Now(), Mode: c.cfg.Mode}
	var maxTemp, driveTemp float64
	haveDrive := false
	readableTemps := 0

	for _, ch := range c.chips {
		cs := ChipState{Name: ch.Name, Path: ch.Path}
		for _, f := range ch.Fans {
			rpm, ok := f.RPM()
			cs.Fans = append(cs.Fans, FanState{Index: f.Index, Label: f.Label, RPM: rpm, OK: ok})
		}
		for _, tp := range ch.Temps {
			val, ok := tp.Celsius()
			cs.Temps = append(cs.Temps, TempState{Index: tp.Index, Label: tp.Label, Path: tp.Path(), C: val, OK: ok})
			if !ok {
				continue
			}
			readableTemps++
			if val > maxTemp {
				maxTemp = val
			}
			if c.cfg.TempSensor != "" && (tp.Label == c.cfg.TempSensor || tp.Path() == c.cfg.TempSensor) {
				driveTemp, haveDrive = val, true
			}
		}
		for _, p := range ch.PWMs {
			v, ok := p.Read()
			cs.PWMs = append(cs.PWMs, PWMState{Index: p.Index, Path: p.Path(), Value: v, OK: ok})
		}
		snap.Chips = append(snap.Chips, cs)
	}
	if !haveDrive {
		driveTemp = maxTemp // default: drive off the hottest sensor
	}
	snap.DriveTempC = driveTemp

	var target int
	if c.totalTemps > 0 && readableTemps == 0 {
		// Sensors existed at startup but all are unreadable now (module unload,
		// /sys error, disconnect). Never trust a 0°C reading — force full.
		snap.Emergency = true
		target = 255
		log.Printf("CRITICAL: all %d temperature sensor(s) unreadable — forcing fans to 100%%", c.totalTemps)
	} else if c.cfg.Mode == "manual" {
		target = clamp(c.cfg.ManualPWM, 0, 255)
	} else {
		target = clamp(curvePWM(c.cfg.Curve, driveTemp), c.cfg.MinPWM, 255)
	}

	// Hysteresis: in auto mode, ignore tiny duty changes to avoid oscillation.
	if snap.Emergency || c.cfg.Mode == "manual" || c.lastPWM < 0 || abs(target-c.lastPWM) >= 3 {
		c.applyPWM(target)
		c.lastPWM = target
	}
	snap.TargetPWM = target
	c.snap = snap
}

func (c *Controller) applyPWM(v int) {
	for _, p := range c.targets() {
		_ = p.SetManual()
		_ = p.Set(v)
	}
}

func (c *Controller) enableManual() {
	c.mu.RLock()
	defer c.mu.RUnlock()
	for _, p := range c.targets() {
		_ = p.SetManual()
	}
}

// targets returns the PWM channels this controller should drive: those listed
// in cfg.PWMTargets, or every discovered channel when the list is empty.
func (c *Controller) targets() []hwmon.PWM {
	var out []hwmon.PWM
	for _, ch := range c.chips {
		for _, p := range ch.PWMs {
			if len(c.cfg.PWMTargets) == 0 {
				out = append(out, p)
				continue
			}
			for _, t := range c.cfg.PWMTargets {
				if p.Path() == t {
					out = append(out, p)
				}
			}
		}
	}
	return out
}

func (c *Controller) interval() time.Duration {
	c.mu.RLock()
	defer c.mu.RUnlock()
	if c.cfg.IntervalSec <= 0 {
		return 5 * time.Second
	}
	return time.Duration(c.cfg.IntervalSec) * time.Second
}

// curvePWM linearly interpolates a target duty for temp along the curve.
func curvePWM(curve []config.Point, temp float64) int {
	if len(curve) == 0 {
		return 255
	}
	pts := make([]config.Point, len(curve))
	copy(pts, curve)
	sort.Slice(pts, func(i, j int) bool { return pts[i].TempC < pts[j].TempC })
	if temp <= float64(pts[0].TempC) {
		return pts[0].PWM
	}
	last := pts[len(pts)-1]
	if temp >= float64(last.TempC) {
		return last.PWM
	}
	for i := 1; i < len(pts); i++ {
		a, b := pts[i-1], pts[i]
		if temp < float64(b.TempC) {
			if b.TempC == a.TempC { // guard against duplicate temps (div-by-zero)
				return b.PWM
			}
			ratio := (temp - float64(a.TempC)) / float64(b.TempC-a.TempC)
			return a.PWM + int(ratio*float64(b.PWM-a.PWM))
		}
	}
	return last.PWM
}

func clamp(v, lo, hi int) int {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

func abs(x int) int {
	if x < 0 {
		return -x
	}
	return x
}
