# fnos-fan

> Detect and control fans on a fnOS NAS — web UI, manual or temperature-curve auto control.

[简体中文](README.md) · **English**

fnOS can't see the fans/temperatures on QNAP boards by default (they hang off the ITE8528 EC). fnos-fan runs a privileged Docker container that compiles and loads the [qnap8528](https://github.com/0xGiddi/qnap8528) kernel module to expose the fans, then serves a web UI to control them manually or via a temperature curve.

## One-command install

SSH into your fnOS NAS and run:

```bash
curl -fsSL https://vecr.ai/fnos-fan/install.sh | sudo bash
```

The script detects the environment, auto-installs kernel headers if missing, downloads and verifies the image, starts it, waits for the first compile/load, and prints the result. The web UI binds to `127.0.0.1:7831` by default.

## Requirements

- An **x86_64** QNAP model running fnOS, with Docker installed.
- If `fancontrol` is running, disable it first to avoid fighting over PWM: `sudo systemctl disable --now fancontrol`.

## Usage

Open the web UI:

- **Auto**: pick a preset (Quiet / Balanced / Performance), or drag the temperature→fan-speed curve directly.
- **Manual**: a single percentage slider sets a fixed speed.
- Changes apply instantly and are saved automatically.

Remote access (localhost-only by default, the safe option):

```bash
ssh -L 7831:127.0.0.1:7831 <user>@<nas-ip>
# then open http://127.0.0.1:7831 locally
```

## Management

The installer adds a `fnos-fan` command:

```
fnos-fan status      show status
fnos-fan logs        follow logs
fnos-fan restart     restart
fnos-fan stop        stop (safely ramps fans to 100%; do NOT use docker kill)
fnos-fan update      update to the latest version
fnos-fan uninstall   uninstall
```

## Security

Binds `127.0.0.1` by default; reach it over the SSH tunnel above. Setting `BIND=0.0.0.0` exposes it on the LAN with **no authentication** (any device could change your fans) — put it behind an authenticated reverse proxy if you do. Always stop with `fnos-fan stop` / `docker stop` (triggers the fans-to-100% failsafe), never `docker kill`.

## Failsafe

On shutdown, control-loop panic, or when **all temperature sensors become unreadable**, fans are forced to 100%; if the process crashes the container restarts and re-takes control — fans are never left stuck at a low speed.

## After a kernel upgrade

When fnOS upgrades the kernel: (1) reboot, (2) `sudo apt install linux-headers-$(uname -r)`, (3) `fnos-fan restart`. The container recompiles the module for the new kernel automatically.

## Known limitations

- **x86_64 only**; ARM QNAP models don't use the ITE8528 EC (generic hwmon only).
- Secure Boot / kernel module-signing enforcement / lockdown will reject the unsigned module — disable them or sign it yourself.
- EC chips without any Linux driver are not supported.

## Credits & license

- The **qnap8528** kernel module is copyright its original author **[0xGiddi](https://github.com/0xGiddi/qnap8528)** and contributors, licensed **GPL-2.0-or-later**; vendored unmodified here for offline builds — see [NOTICE](NOTICE).
- The rest of this repository (the Go daemon, scripts, web UI) is original work.

## Building / self-hosting

Want to build the image and distribute from your own domain? See [RELEASING.md](RELEASING.md).
