// Package config holds the user-tunable fan-control settings and persists them
// to a JSON file on the mounted data volume.
package config

import (
	"encoding/json"
	"os"
)

// Point is one (temperature, pwm) vertex of the auto-mode curve.
type Point struct {
	TempC int `json:"temp_c"`
	PWM   int `json:"pwm"`
}

// Config is the full tunable state. Unexported fields are runtime-only and are
// never (de)serialized.
type Config struct {
	Mode        string   `json:"mode"`        // "auto" | "manual"
	ManualPWM   int      `json:"manual_pwm"`  // 0-255, used in manual mode
	MinPWM      int      `json:"min_pwm"`     // floor in auto mode (never below)
	Curve       []Point  `json:"curve"`       // auto-mode temp->pwm points
	TempSensor  string   `json:"temp_sensor"` // label or path; "" = hottest sensor
	PWMTargets  []string `json:"pwm_targets"` // pwm sysfs paths; empty = drive all
	IntervalSec int      `json:"interval_sec"`
	HysteresisC int      `json:"hysteresis_c"`

	path string
}

// Default returns conservative, safe-by-default settings.
func Default() *Config {
	return &Config{
		Mode:      "auto",
		ManualPWM: 128,
		MinPWM:    60,
		Curve: []Point{
			{TempC: 35, PWM: 60},
			{TempC: 45, PWM: 100},
			{TempC: 55, PWM: 160},
			{TempC: 65, PWM: 220},
			{TempC: 75, PWM: 255},
		},
		IntervalSec: 5,
		HysteresisC: 3,
	}
}

// Load reads config from path, writing defaults if the file does not exist yet.
func Load(path string) (*Config, error) {
	c := Default()
	c.path = path
	b, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return c, c.Save()
		}
		return c, err
	}
	if err := json.Unmarshal(b, c); err != nil {
		return c, err
	}
	c.path = path
	return c, nil
}

// Save atomically writes the current config to disk.
func (c *Config) Save() error {
	if c.path == "" {
		return nil
	}
	b, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return err
	}
	tmp := c.path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, c.path)
}

// Apply overwrites the tunable fields from n while preserving internal state
// (the on-disk path). Used when the API receives a new config.
func (c *Config) Apply(n Config) {
	c.Mode = n.Mode
	c.ManualPWM = n.ManualPWM
	c.MinPWM = n.MinPWM
	c.Curve = n.Curve
	c.TempSensor = n.TempSensor
	c.PWMTargets = n.PWMTargets
	c.IntervalSec = n.IntervalSec
	c.HysteresisC = n.HysteresisC
}
