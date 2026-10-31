# Fan Control

Manual fan control for Apple Silicon Macs. A small menu bar app that holds your fans at a fixed speed, or ramps them along a temperature curve you draw yourself, instead of leaving everything to macOS.

It is three pieces: a SwiftUI panel you interact with, a root helper daemon that does the privileged work, and a `fanctl` command line tool that is both the helper binary and a usable CLI in its own right.

---

## Contents

- [Why a helper is needed](#why-a-helper-is-needed)
- [Requirements](#requirements)
- [Install](#install)
- [Using the app](#using-the-app)
- [The `fanctl` CLI](#the-fanctl-cli)
- [Architecture](#architecture)
- [How fan control actually works](#how-fan-control-actually-works)
- [The control loop](#the-control-loop)
- [Safety behaviour](#safety-behaviour)
- [Files on disk](#files-on-disk)
- [Configuration format](#configuration-format)
- [Security model](#security-model)
- [Building from source](#building-from-source)
- [Troubleshooting](#troubleshooting)
- [Uninstalling](#uninstalling)
- [Project layout](#project-layout)
- [Licence](#licence)

---

## Why a helper is needed

Fan speeds live in the **SMC** (System Management Controller), reached through the `AppleSMC` IOKit driver. Reading SMC keys works as any user; **writing them requires root**.

A GUI app runs as you, unprivileged, so it cannot set a fan speed directly. Rather than running the whole app as root — a large, long-lived, UI-bearing process with full system privileges — the privileged surface is kept to one small binary:

```
Fan Control.app  (you)                 fanctl daemon  (root)
  │                                       │
  │  writes rules.json ─────────────────▶ │  reads it when the mtime changes
  │                                       │  writes SMC keys once a second
  └─ reads SMC keys for display           └─ hands fans back on exit
```

The app never writes to the SMC. It writes a JSON file; the daemon is the only thing that touches hardware. That is why Settings has a **Helper** section with status, reinstall and uninstall — the daemon lives outside the app bundle, in `/Library`, and keeps running whether or not the app is open.

---

## Requirements

| | |
|---|---|
| macOS | 15.0 or later (`LSMinimumSystemVersion` 15.0) |
| Hardware | Apple Silicon Mac **with fans** — MacBook Air and fanless models have nothing to control |
| Build toolchain | Swift 6.0 or later (Xcode 16+) |
| Privileges | An administrator account, for the one-time helper install |

The sensor key families (`Tp0`, `Te0`, `Tg0`, `Tm0`, …) are the Apple Silicon ones and are shared across M-series chips. Intel Macs use different keys and are not supported.

---

## Install

No prebuilt release is published, so build it:

```bash
git clone https://github.com/Leul-Michael/mac-fan-control.git
```

```bash
cd mac-fan-control && ./scripts/build-app.sh
```

That produces `build/Fan Control.app`. Move it to `/Applications` and open it.

On first launch the app runs with no helper: readings are live but the fans stay under macOS control. Press the power button, or **Install Helper** in Settings, and authenticate once. The helper is then installed as a LaunchDaemon and starts immediately, and at every boot thereafter.

Because the app is **ad-hoc signed and not notarised**, Gatekeeper will object on first open. Right-click the app → **Open**, or clear the quarantine flag:

```bash
xattr -dr com.apple.quarantine "/Applications/Fan Control.app"
```

---

## Using the app

**Menu bar.** The app lives in the menu bar as a turbine glyph (a template image, so it tints correctly in light and dark bars). Its menu shows CPU temperature and current RPM, a power toggle, the preset list, and Settings.

**The panel.** A borderless, rounded window you can drag by its background. It follows you across Spaces (`.moveToActiveSpace`), and closing it leaves the app running in the menu bar. Minimising it puts a **live Dock tile** in the Dock — a square tile refreshed every 2 seconds with current temperature and fan speeds, instead of a squeezed snapshot of the tall panel.

**The power button.** Off hands every fan back to macOS. On restores whatever rules you last had; with no history, both fans go to 60 % of their range, rounded to 50 RPM.

**Per-fan rules.** Each fan takes one of three modes:

| Mode | Behaviour |
|---|---|
| `auto` | macOS decides. The fan is released entirely. |
| `constant(rpm:)` | Held at a fixed speed, clamped to the fan's own min/max. |
| `sensor(id:startCelsius:fullCelsius:)` | Follows a sensor. Minimum speed at `start`, rising in a straight line to maximum at `full`. Below `start`, the fan goes back to macOS — which can stop it completely when the Mac is cool. |

**Presets.** Three are built in — **Automatic** (no rules), **Cool & Quiet** (both fans tracking the hottest CPU core, 55 °C → 85 °C), and **Full Blast** (both fans pinned at maximum; the stored value of 100000 RPM is simply clamped to each fan's real maximum). Save your own from the current rules; they persist in `UserDefaults` along with the active rules and the last-used set.

**Available sensors** are detected at launch, not hardcoded. The reader lists every SMC key beginning with `T`, matches them against the known groups, and discards any that read ≤ 1 °C on this model. Only groups that actually resolved appear in the UI.

| Group id | Name | Keys | Combined by |
|---|---|---|---|
| `cpu-hot` | CPU Hottest Core | `Tp0*`, `Te0*` | maximum |
| `cpu-p` | CPU Performance Cores | `Tp0*` | average |
| `cpu-e` | CPU Efficiency Cores | `Te0*` | average |
| `gpu` | GPU | `Tg0*` | average |
| `memory` | Memory | `Tm0*` | average |
| `ssd` | SSD | `TH0*` | maximum |
| `battery` | Battery | `TB0T`, `TB1T`, `TB2T` | maximum |
| `wifi` | Wi-Fi | `TW0P` | maximum |
| `palm-left` / `palm-right` | Palm Rest | `Ts0P` / `Ts1P` | maximum |

**Settings** holds: launch at login (via `SMAppService`), *Use Auto on battery*, *Keep fan settings when the app quits*, and the Helper section. By default, quitting the app hands the fans back to macOS — turn on *Keep fan settings when the app quits* if you want your rules to survive without the app running.

---

## The `fanctl` CLI

The same binary that runs as the daemon is a complete command line tool. It ships inside the app at `Fan Control.app/Contents/Resources/fanctl`, and is built standalone at `.build/release/fanctl`.

```
fanctl status                         fans and temperatures
fanctl set <left|right|all|N> <rpm>   hold a fan at a speed (root)
fanctl auto [left|right|all|N]        give fans back to macOS (root)
fanctl daemon                         apply the app's rules every second (root, run by launchd)
fanctl install --user <name>          install the helper service (root)
fanctl uninstall                      remove the helper service and restore automatic fans (root)
```

`status` needs no privileges:

```bash
"/Applications/Fan Control.app/Contents/Resources/fanctl" status
```

```
Left Fan    2104 rpm  target  2100  range 1200–5400  manual
Right Fan   2098 rpm  target  2100  range 1200–5400  manual
CPU Hottest Core          62.4 °C
GPU                       48.1 °C
SSD                       41.0 °C
```

`set` and `auto` write directly to the SMC and need `sudo`. Note that they fight the daemon if it is running with rules of its own — the daemon will overwrite your manual setting within a second. Stop it first (`sudo launchctl bootout system/com.xocode.fancontrol.helper`) or set the fans to `auto` in the app.

---

## Architecture

Four SwiftPM targets:

```
CSMC        C shim over the AppleSMC IOKit user client. Links IOKit.
  └─ FanKit     Swift layer: SMC keys, fan/sensor models, rules, curve maths, paths.
       ├─ fanctl       CLI + the root daemon's control loop.
       └─ FanControl   SwiftUI app (menu bar item, panel, Dock tile, Settings).
```

`FanKit` is deliberately the shared core — the app and the daemon agree on the rule format, the SMC key names, the file paths and the curve function because they link the same code. `Paths` and `HelperInfo` in `Sources/FanKit/Rules.swift` are the single source of truth for both sides.

**`CSMC`** ([`smc.c`](Sources/CSMC/smc.c), 87 lines) reproduces the 80-byte `smc_param` struct the `AppleSMC` user client expects and calls `IOConnectCallStructMethod` with selector 2 (`SMC_HANDLE_EVENT`), using commands read/write/index/info (5/6/8/9). This is the long-established layout used by open-source SMC tools.

**`SMC`** ([`SMC.swift`](Sources/FanKit/SMC.swift)) wraps one connection with an `NSLock`, decodes the SMC's type codes (`flt `, `ui8 `, `ui16`, `ui32`, `fpe2`, `sp78`, `si8 `, `si16`) into `Double`, and re-encodes on write in whatever type the key reports. A failed write with `kIOReturnNotPrivileged`, or any failure while not root, is surfaced as `SMCError.notPermitted` rather than an opaque IOKit code.

---

## How fan control actually works

Fans are exposed as four-character SMC keys, indexed from 0:

| Key | Meaning |
|---|---|
| `FNum` | number of fans |
| `F0Ac` | fan 0 actual RPM |
| `F0Tg` | fan 0 target RPM — **the one you write** |
| `F0Mn` / `F0Mx` | fan 0 minimum / maximum RPM |
| `F0Md` | fan 0 mode: 0 = automatic, 1 = manual |
| `Ftst` | manual-control unlock on some Apple Silicon models |

Setting a speed is therefore a three-step sequence ([`Fans.swift`](Sources/FanKit/Fans.swift)):

1. If the fan is not already in manual mode, write `Ftst = 1` — but only if that key exists on this Mac, since several models don't have it and it is harmless to skip.
2. Write `F<n>Md = 1` to take the fan out of automatic control.
3. Write `F<n>Tg`, clamped to `[F<n>Mn, F<n>Mx]`.

Releasing a fan writes `F<n>Md = 0`, and clears `Ftst` once *every* fan is back on automatic.

On a two-fan MacBook Pro, fan 0 is the left fan and fan 1 the right — the UI names them accordingly.

---

## The control loop

`fanctl daemon` ([`main.swift:52`](Sources/fanctl/main.swift#L52)) ticks once per second. Each tick:

**1. Reload if changed.** The config's modification date is compared with the last seen one; the JSON is re-read only when it differs. No file watchers, no IPC, no XPC service — the app writes the file atomically and the daemon notices within a second.

**2. Smooth the temperatures.** Raw sensor readings are noisy, and following them directly makes fans hunt audibly. Each sensor is passed through a one-pole filter with an **asymmetric time constant**:

```
τ = 3 s  when the temperature is rising
τ = 10 s when it is falling
smoothed += (raw − smoothed) · (1 − e^(−dt/τ))
```

Heat gets a fast response; cooling is deliberately lazy, so a brief idle moment doesn't drop the fans only for them to spin straight back up.

**3. Pick a target per fan.** For a sensor rule, `curveRPM` maps the smoothed temperature linearly from `fan.minimum` at `start` to `fan.maximum` at `full`.

**4. Apply hysteresis.** A fan that a sensor rule has spun up is tracked in an `engaged` set, and is only released at **`start − 3 °C`**, not at `start`. Without this, a temperature sitting exactly on the threshold would hand the fan back and forth between the daemon and macOS once a second.

**5. Ramp.** Sensor-driven changes are rate-limited to **400 RPM/s rising, 250 RPM/s falling**, starting from where the fan actually is (its current RPM when taking over from macOS, or its existing target if already manual). Constant rules are not ramped — they snap.

**6. Write, but only when it matters.** The SMC is written only if the fan is not already in manual mode, or the new target differs from the current one by **≥ 20 RPM**. A steady-state fan generates no SMC writes at all.

The daemon logs rule changes, overheat transitions and power-source changes to `/Library/Logs/FanControl.log` with ISO-8601 timestamps. Steady operation is silent.

---

## Safety behaviour

Taking fans off automatic control is the kind of thing that can cook a laptop, so there are four independent backstops.

**Thermal cutout.** If the hottest CPU core reaches **100 °C**, the daemon logs it, abandons your rules and hands every fan back to macOS — which will drive them harder than any curve you drew. Rules resume once it drops below **90 °C**. This check deliberately uses the **raw** reading, not the smoothed one, so the 10-second cooling filter cannot delay it.

**Battery release.** With *Use Auto on battery* on (the default), running on battery hands every fan to macOS. Holding fans at speed is a meaningful drain and macOS manages the trade-off better.

**Clean shutdown.** `SIGTERM` and `SIGINT` are trapped: the handler calls `setAllAuto()` before exiting, so stopping the daemon never leaves fans pinned. `uninstall` does the same after removing the daemon.

**Quit releases by default.** Quitting the app writes an empty rule set, returning the fans to macOS, unless you explicitly chose *Keep fan settings when the app quits*.

What is **not** guarded: nothing stops you setting a constant RPM far below what the thermal load needs. The 100 °C cutout is the net, and it is a last resort rather than a control strategy. Sensor rules are the safer mode and are what the built-in **Cool & Quiet** preset uses.

---

## Files on disk

Installed by `fanctl install`, all outside the app bundle:

| Path | Owner | Mode | Purpose |
|---|---|---|---|
| `/Library/PrivilegedHelperTools/com.xocode.fancontrol.helper` | `root:wheel` | `755` | the helper binary (a copy of `fanctl`) |
| `/Library/LaunchDaemons/com.xocode.fancontrol.helper.plist` | `root:wheel` | `644` | LaunchDaemon, `RunAtLoad` + `KeepAlive` |
| `/Library/Application Support/FanControl/` | *installing user* | `755` | config directory |
| `/Library/Application Support/FanControl/rules.json` | *installing user* | `644` | the rules the daemon applies |
| `/Library/Application Support/FanControl/helper-version` | `root` | `644` | running helper's `HelperInfo.version` |
| `/Library/Logs/FanControl.log` | `root` | — | daemon stderr |

The config directory is `chown`ed to the user who installed the helper. That is what lets the unprivileged app rewrite `rules.json` without prompting for a password on every slider drag, and it is also how the app detects installation — `isWritableFile(atPath:)` on that directory.

`helper-version` is written by the daemon at startup. The app compares it against its own `HelperInfo.version` (currently `2`) and shows **Update helper** when the installed daemon is older than the app — relevant because the app bundle updates but the root binary in `/Library` does not.

---

## Configuration format

`rules.json` is `HelperConfig` encoded with sorted keys and pretty printing:

```json
{
  "autoOnBattery" : true,
  "rules" : {
    "0" : { "sensor" : { "id" : "cpu-hot", "startCelsius" : 55, "fullCelsius" : 85 } },
    "1" : { "constant" : { "rpm" : 3600 } }
  }
}
```

Keys are fan indexes. A fan absent from `rules` runs on automatic — an empty `rules` object means "macOS controls everything". Decoding is tolerant: both fields use `decodeIfPresent` with defaults, so an older or partial file loads rather than failing, and an unreadable file falls back to an empty config (all fans automatic). Editing this file by hand works; the daemon picks it up within a second.

---

## Security model

Worth being explicit about, since this installs a permanently-running root daemon.

**What is privileged.** Only `fanctl daemon`. It is ~250 lines, has no network access, opens no ports, and its entire input is one JSON file. The app itself never runs as root.

**How privilege is acquired.** `install` and `uninstall` are run through `NSAppleScript` with `do shell script … with administrator privileges`, which produces the standard macOS authentication prompt. The tool path is single-quote escaped before interpolation.

**Known limitations**, stated plainly:

- `rules.json` is **writable by the installing user**, by design. Any process running as that user can change your fan rules. It cannot do anything else through the daemon — the file is parsed as `HelperConfig` and nothing in it is a path, a command, or a key name — but it is not a privilege boundary.
- The helper is **not installed via `SMJobBless`**, and the daemon does **not** verify the code signature of whoever wrote the config. A classic `SMJobBless`/XPC design with signing-requirement checks on both ends would be stronger.
- The app is **ad-hoc signed** (`codesign --sign -`) and not notarised, so there is no meaningful signature to validate in the first place.

For personal use on your own machine this is a reasonable trade-off. It is not what you would ship to a general audience without hardening the helper install path first.

---

## Building from source

```bash
./scripts/build-app.sh
```

The script builds both products in release configuration, assembles `build/Fan Control.app` by hand (no Xcode project involved), generates `AppIcon.icns` on first run via `scripts/make-icon.swift` + `iconutil`, copies the Saira Semi Condensed fonts into `Contents/Resources/Fonts`, writes the `Info.plist` inline, and ad-hoc signs `fanctl` and then the bundle.

For development without bundling:

```bash
swift run FanControl
```

The font registration path handles this case — with no app bundle present it falls back to the fonts in `Resources/Fonts` in the source tree.

Debug builds also accept two snapshot flags used for generating images: `--snapshot <file.png>` renders the panel and exits, and `--icon <file.png>` renders the menu bar glyph at 8×.

---

## Troubleshooting

**Status says "Installed, not running".** The daemon is registered but its process is absent — it crashed, or was booted out manually. Check the log, then Reinstall Helper.

```bash
sudo tail -50 /Library/Logs/FanControl.log
```

**Fans don't respond.** Confirm the daemon is alive and your rules reached it:

```bash
sudo launchctl print system/com.xocode.fancontrol.helper | head -20
```

```bash
cat "/Library/Application Support/FanControl/rules.json"
```

If `rules.json` is empty or `{}`, the app isn't pushing — most often because the config directory isn't writable by you (helper installed under a different user account). Reinstall the helper from the account you actually use.

**"Install the helper to control the fans"** appears whenever rules exist but the config directory isn't writable. Same cause, same fix.

**Fans fluctuate or hunt.** Widen the gap between `start` and `full`. A narrow band turns a few degrees of normal variation into a large RPM swing, and the ramp limiter can only soften that, not remove it.

**"This Mac's fan controller could not be opened."** `SMC()` failed at `IOServiceGetMatchingService`. Either the Mac has no `AppleSMC` service exposed in the usual way, or it has no fans at all — MacBook Airs are fanless, and there is nothing for this app to do on them.

**An update changed nothing.** The app bundle updated; the root binary in `/Library` did not. Use **Reinstall Helper**, which is exactly what the "Update helper" prompt does.

---

## Uninstalling

Use **Uninstall Helper** in Settings, then move the app to the Trash. Or from the command line:

```bash
sudo "/Applications/Fan Control.app/Contents/Resources/fanctl" uninstall
```

Either path boots out the LaunchDaemon, removes the plist, the helper binary and the whole config directory, and calls `setAllAuto()` so the fans go back to macOS.

> **Note:** deleting the app on its own is **not** enough. The LaunchDaemon is independent of the bundle and will keep running at every boot, applying whatever was last in `rules.json`, with no UI left to stop it. Always uninstall the helper first.

The app's own preferences (presets, last rules, window position) live in `UserDefaults` under `com.xocode.fancontrol` and can be cleared with `defaults delete com.xocode.fancontrol`.

---

## Project layout

```
Package.swift                     four targets, macOS 15, Swift 6 tools
Sources/
  CSMC/
    include/smc.h                 open/close, key count, index, info, read, write
    smc.c                         the AppleSMC user-client struct call
  FanKit/
    SMC.swift                     connection, type decoding, typed writes, key enumeration
    Fans.swift                    FanReading, fan naming, setFan / setAuto / setAllAuto
    Sensors.swift                 sensor groups, per-model key resolution, readings
    Rules.swift                   FanRule, Preset, HelperConfig, Paths, curve maths
    Power.swift                   on-battery check via IOKit.ps
  fanctl/
    main.swift                    CLI, the Daemon control loop, install / uninstall
  FanControl/
    FanControlApp.swift           entry point, menu bar item, panel window, Dock tile
    FanModel.swift                observable state, rules, presets, helper install
    Views.swift                   theme, controls, the compact panel, Settings
scripts/
  build-app.sh                    assembles and signs build/Fan Control.app
  make-icon.swift                 generates the iconset
Resources/Fonts/                  Saira Semi Condensed (OFL)
```

---

## Licence

No project licence has been chosen yet — add one before accepting contributions or redistributing.

The bundled **Saira Semi Condensed** fonts are licensed separately under the SIL Open Font License; see [`Resources/Fonts/OFL.txt`](Resources/Fonts/OFL.txt).

---

## A word of caution

This takes thermal management away from macOS. The thermal cutout at 100 °C is a backstop, not a safety system — a badly chosen constant speed can run your Mac hotter than Apple intends for as long as it stays under that limit. Prefer sensor curves over fixed speeds, leave *Use Auto on battery* on, and treat **Full Blast** as something you turn on deliberately and turn off afterwards.
