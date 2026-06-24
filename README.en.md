# fnos-fan

> Detect and control fans on a fnOS NAS — web UI, manual or temperature-curve auto control.

[简体中文](README.md) · **English**

fnOS can't see the fans/temperatures on QNAP boards by default (they hang off the ITE8528 EC). fnos-fan runs a privileged Docker container that compiles and loads the [qnap8528](https://github.com/0xGiddi/qnap8528) kernel module to expose the fans, then serves a web UI to control them manually or via a temperature curve.

## One-command install

SSH into your fnOS NAS and run:

```bash
curl -fsSL https://vecr.ai/fnos-fan/install.sh | sudo bash
```

The script detects the environment, auto-installs kernel headers if missing, downloads and verifies the image, starts it, waits for the first compile/load, and prints the result. The web UI is **LAN-accessible** by default (`0.0.0.0:7831`); to lock it down or add a password, see "Access & security" below.

## Requirements

- An **x86_64** QNAP model running fnOS, with Docker installed.
- If `fancontrol` is running, disable it first to avoid fighting over PWM: `sudo systemctl disable --now fancontrol`.

## Usage

Open `http://<nas-ip>:7831` in a browser on the **same LAN** (the installer prints the exact URL when it finishes), then:

- **Auto**: pick a preset (Quiet / Balanced / Performance), or drag the temperature→fan-speed curve directly.
- **Manual**: a single percentage slider sets a fixed speed.
- Changes apply instantly and are saved automatically.

## Management

The installer adds a `fnos-fan` command:

```
fnos-fan status      show status
fnos-fan logs        follow logs
fnos-fan restart     restart
fnos-fan stop        stop (hands fans back to firmware auto; do NOT use docker kill)
fnos-fan update      update to the latest version
fnos-fan uninstall   uninstall
```

## Access & security

- **LAN-accessible by default** at `http://nas-ip:7831`; the installer opens the ufw/firewalld port automatically.
- **Add a password** (recommended on untrusted networks): pass `AUTH_TOKEN` at install:
  ```bash
  curl -fsSL https://vecr.ai/fnos-fan/install.sh | sudo AUTH_TOKEN=yourpassword bash
  ```
  The browser then shows a login prompt (any username; password = `AUTH_TOKEN`).
- **Strictest (localhost only)**: install with `BIND=127.0.0.1`, then tunnel: `ssh -L 7831:127.0.0.1:7831 <user>@<nas-ip>`.
- **Never** forward port `7831` to the public internet on your router; for remote access use an authenticated HTTPS reverse proxy.
- The web UI is hardened: it **only accepts access via IP, `localhost`, or `*.local`**, which blocks DNS-rebinding and cross-site (CSRF) requests — so a malicious page you open on the LAN can't change your fans. If you reach it through a **reverse proxy or a custom hostname (e.g. Tailscale)**, list that hostname via `ALLOWED_HOSTS` (comma-separated) or you'll get a 403:
  ```bash
  curl -fsSL https://vecr.ai/fnos-fan/install.sh | sudo ALLOWED_HOSTS=nas.example.com bash
  ```
- Change `WEB_PORT` on conflict. The container uses **host networking** (binds the NAS port directly); if fnOS runs in a **NAT (non-bridged) VM**, the NAS IP may not be on the LAN directly — set up port forwarding or a bridged adapter in your hypervisor.
- Always stop with `fnos-fan stop` / `docker stop` (hands fans back to the hardware's automatic control; 100% on drivers without an auto mode), never `docker kill` (leaves fans pinned at the last manual duty).

## Failsafe

On a control-loop panic or when **all temperature sensors become unreadable**, fans are forced to 100%; on a clean stop/uninstall fans are handed back to the hardware's automatic control (100% on drivers without an auto mode). If the process crashes the container restarts and re-takes control — fans are never left stuck at a low speed.

## After a kernel upgrade

When fnOS upgrades the kernel: (1) reboot, (2) `sudo apt install linux-headers-$(uname -r)`, (3) `fnos-fan restart`. The container recompiles the module for the new kernel automatically.

## Non-QNAP boards (generic ITE Super-I/O)

You don't need a QNAP. Many x86 mini-NAS boxes (e.g. the Beelink ME mini, IT8613E) drive their fan through an ITE Super-I/O chip. On a **non-QNAP** board that otherwise exposes no pwm, the container automatically builds and loads the bundled `it87` (frankcrawford fork — it supports newer ITE chips the in-tree it87 doesn't), exposing the fan as a standard hwmon pwm that fanctld then drives — fully automatic, same as the QNAP path.

Same prerequisites apply: kernel headers installed, module signing not enforced. Boards whose chip isn't supported by it87 can't be controlled (`fnos-fan logs` will say so).

## Known limitations

- **x86_64 only**; ARM QNAP models don't use the ITE8528 EC (generic hwmon only).
- Secure Boot / kernel module-signing enforcement / lockdown will reject the unsigned module — disable them or sign it yourself.
- EC chips without any Linux driver are not supported.

## Credits & license

- The **qnap8528** kernel module is copyright its original author **[0xGiddi](https://github.com/0xGiddi/qnap8528)** and contributors, licensed **GPL-2.0-or-later**; vendored unmodified here for offline builds — see [NOTICE](NOTICE).
- The rest of this repository (the Go daemon, scripts, web UI) is original work, licensed **GPL-3.0-or-later** — see [LICENSE](LICENSE).

## Building / self-hosting

Want to build the image and distribute from your own domain? See [RELEASING.md](RELEASING.md).
