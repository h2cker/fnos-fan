// Package hwmon provides a driver-agnostic view of the Linux hwmon sysfs tree.
//
// It deliberately does not care whether the underlying driver is qnap8528,
// it87, nct6775 or anything else — any chip that exposes fanN_input /
// tempN_input / pwmN is usable. This is what lets the same binary work across
// QNAP (via the qnap8528 module) and generic boards (via in-tree drivers).
package hwmon

import (
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// Root is the hwmon class directory. Overridable for tests.
var Root = "/sys/class/hwmon"

// Fan is a single fanN_input tachometer.
type Fan struct {
	Index int
	Label string
	input string
}

// Temp is a single tempN_input sensor.
type Temp struct {
	Index int
	Label string
	input string
}

// PWM is a single pwmN duty-cycle control (0-255).
type PWM struct {
	Index  int
	path   string
	enable string // pwmN_enable, "" if absent
}

// Chip groups all sensors/controls exposed by one hwmon device.
type Chip struct {
	Path  string
	Name  string
	Fans  []Fan
	Temps []Temp
	PWMs  []PWM
}

// Scan walks the hwmon tree and returns every chip that exposes at least one
// fan, temperature or pwm.
func Scan() ([]Chip, error) {
	entries, err := os.ReadDir(Root)
	if err != nil {
		return nil, err
	}
	var chips []Chip
	for _, e := range entries {
		dir := filepath.Join(Root, e.Name())
		c := Chip{
			Path:  dir,
			Name:  readStr(filepath.Join(dir, "name")),
			Fans:  scanFans(dir),
			Temps: scanTemps(dir),
			PWMs:  scanPWMs(dir),
		}
		if len(c.Fans) == 0 && len(c.Temps) == 0 && len(c.PWMs) == 0 {
			continue
		}
		chips = append(chips, c)
	}
	return chips, nil
}

func scanFans(dir string) []Fan {
	var out []Fan
	matches, _ := filepath.Glob(filepath.Join(dir, "fan*_input"))
	for _, m := range matches {
		idx := nodeIndex(filepath.Base(m), "fan", "_input")
		if idx < 0 {
			continue
		}
		out = append(out, Fan{
			Index: idx,
			Label: readStr(filepath.Join(dir, "fan"+strconv.Itoa(idx)+"_label")),
			input: m,
		})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Index < out[j].Index })
	return out
}

func scanTemps(dir string) []Temp {
	var out []Temp
	matches, _ := filepath.Glob(filepath.Join(dir, "temp*_input"))
	for _, m := range matches {
		idx := nodeIndex(filepath.Base(m), "temp", "_input")
		if idx < 0 {
			continue
		}
		out = append(out, Temp{
			Index: idx,
			Label: readStr(filepath.Join(dir, "temp"+strconv.Itoa(idx)+"_label")),
			input: m,
		})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Index < out[j].Index })
	return out
}

func scanPWMs(dir string) []PWM {
	var out []PWM
	matches, _ := filepath.Glob(filepath.Join(dir, "pwm*"))
	for _, m := range matches {
		base := filepath.Base(m)
		if strings.Contains(base, "_") { // skip pwmN_enable, pwmN_mode, ...
			continue
		}
		idx, err := strconv.Atoi(strings.TrimPrefix(base, "pwm"))
		if err != nil {
			continue
		}
		enable := filepath.Join(dir, base+"_enable")
		if !fileExists(enable) {
			enable = ""
		}
		out = append(out, PWM{Index: idx, path: m, enable: enable})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Index < out[j].Index })
	return out
}

// --- accessors -------------------------------------------------------------

// RPM returns the fan speed; ok is false if the node is unreadable.
func (f Fan) RPM() (rpm int, ok bool) { return readInt(f.input) }

// Path returns the sysfs path of the fan input.
func (f Fan) Path() string { return f.input }

// Celsius returns the temperature in whole degrees (sysfs reports millidegrees).
func (t Temp) Celsius() (c float64, ok bool) {
	m, ok := readInt(t.input)
	return float64(m) / 1000.0, ok
}

// Path returns the sysfs path of the temperature input.
func (t Temp) Path() string { return t.input }

// Read returns the current PWM duty value (0-255).
func (p PWM) Read() (val int, ok bool) { return readInt(p.path) }

// Path returns the sysfs path of the pwm control.
func (p PWM) Path() string { return p.path }

// Set writes a raw PWM duty value, clamped to 0-255.
func (p PWM) Set(v int) error {
	if v < 0 {
		v = 0
	}
	if v > 255 {
		v = 255
	}
	return os.WriteFile(p.path, []byte(strconv.Itoa(v)), 0o644)
}

// SetManual switches the channel to manual control (pwmN_enable=1) when the
// driver exposes that knob. Required before our duty writes take effect on
// drivers that otherwise run their own automatic curve.
func (p PWM) SetManual() error {
	if p.enable == "" {
		return nil
	}
	return os.WriteFile(p.enable, []byte("1"), 0o644)
}

// --- helpers ---------------------------------------------------------------

// nodeIndex extracts N from a node name like "fan3_input" given prefix "fan"
// and suffix "_input". Returns -1 if the name does not match.
func nodeIndex(name, prefix, suffix string) int {
	if !strings.HasPrefix(name, prefix) || !strings.HasSuffix(name, suffix) {
		return -1
	}
	mid := name[len(prefix) : len(name)-len(suffix)]
	n, err := strconv.Atoi(mid)
	if err != nil {
		return -1
	}
	return n
}

func readStr(path string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

func readInt(path string) (int, bool) {
	s := readStr(path)
	if s == "" {
		return 0, false
	}
	n, err := strconv.Atoi(s)
	if err != nil {
		return 0, false
	}
	return n, true
}

func fileExists(p string) bool {
	_, err := os.Stat(p)
	return err == nil
}
