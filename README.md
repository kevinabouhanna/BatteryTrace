<p align="center">
  <img src="docs/images/icon.png" alt="" width="128">
</p>

# Battery Trace for Mac

<p align="center">
  <a href="https://github.com/kevinabouhanna/BatteryTrace/releases/latest"><img src="https://img.shields.io/github/v/release/kevinabouhanna/BatteryTrace?color=51FF70&label=release" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-1d1d1f" alt="macOS 14 or later">
  <a href="https://github.com/kevinabouhanna/BatteryTrace/actions/workflows/ci.yml"><img src="https://github.com/kevinabouhanna/BatteryTrace/actions/workflows/ci.yml/badge.svg" alt="CI status"></a>
  <img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT licence">
</p>

<p align="center">
  <a href="https://github.com/kevinabouhanna/BatteryTrace/releases/latest/download/BatteryTrace.dmg"><b>Download</b></a> ·
  <a href="docs/ATTRIBUTION.md">How it works</a> ·
  <a href="docs/VALIDATION.md">Validation</a>
</p>

A menu bar app that shows where your Mac's power goes. It splits power by app,
and shows what isn't an app at all: the display, the CPU, GPU, Neural Engine,
memory and the rest of the chip.

- **Light.** Sampling costs about 0.015% of one core while the window is
  closed. See [docs/PERFORMANCE.md](docs/PERFORMANCE.md).
- **Honest.** The total is measured. Per-app figures are estimates, and the UI
  labels them as estimates. Whatever no counter accounts for stays in its own
  Unattributed row, so the rows always add up to what was measured. See
  [docs/ATTRIBUTION.md](docs/ATTRIBUTION.md).
- **No root, no permissions, no dependencies.**

<p align="center"><img src="docs/images/popover-system.png" width="360" alt="The popover's System tab on a MacBook Air: 60% battery, 5.63 W from the battery, health 80%. The breakdown shows CPU 342 mW, GPU 33 mW, memory 185 mW, display backlight about 3.52 W (an estimate, at 84% brightness), display controller 39 mW, other chip blocks 105 mW and 1.46 W unattributed, out of 5.68 W measured."></p>

## Install

For macOS 14 or later, on Apple silicon or Intel.

1. [**Download BatteryTrace.dmg**](https://github.com/kevinabouhanna/BatteryTrace/releases/latest/download/BatteryTrace.dmg),
   open it, and drag Battery Trace into **Applications**.
2. Open Battery Trace. macOS says it can't check it for malicious software.
   Close that message.
3. Open **System Settings › Privacy & Security**, scroll down to **Security**,
   click **Open Anyway** next to Battery Trace, and confirm with your password.

> [!NOTE]
> **Why the extra step?** Battery Trace isn't signed with a paid Apple
> Developer ID yet, so macOS can't confirm who made it. The code is all here to
> read, or to build yourself (below).

Look for the ⚡︎ reading in your menu bar. Click it for the popover; right-click
it, or click it with two fingers, for Settings and Quit. To have it start at
login, turn on **Settings › General › Open at login**. To be told when an app
keeps using a lot of power on battery, turn on **Tell me when an app uses a lot
of power** there too; macOS asks for permission to show notifications.

### Update

**Check for Updates…** in the right-click menu asks GitHub whether there's a
newer version, and shows what's new. To have it look once a day, turn on
**Settings › General › Check automatically once a day**; it's off until you do.
Nothing installs by itself: **Download** opens the new disk image.

Drag Battery Trace into Applications again, choosing **Replace**. Your settings
and history are kept. macOS checks each new version afresh, so approve it with
**Open Anyway** once more.

### Uninstall

Quit Battery Trace from its right-click menu, turn off **Open at login** first
if you turned it on, and drag it from Applications to the Trash. To remove its
history and settings too:

```sh
rm -rf ~/Library/"Application Support/Battery Trace"
defaults delete app.batterytrace.BatteryTrace
```

## Requirements

- macOS 14 or later.
- Apple silicon. Intel Macs run it with fewer metrics; see the limitations below.
- To build: Xcode 16 or later. Tested with Xcode 27.0 and Swift 6.4 on a
  MacBook Air (M1, 2020) running macOS 27.0.1.

## Build and run

- **In Xcode:** open `BatteryTrace.xcodeproj` and run the **BatteryTrace**
  scheme. The app appears in the menu bar, with no Dock icon. Click it for the
  popover; right-click (or two-finger click) it for Settings, About and Quit.
- **From the command line:**
  ```sh
  make app      # build/DerivedData/Build/Products/Release/Battery Trace.app
  make run      # build and open it
  make test     # 44 unit tests: attribution, grouping, storage, sampling policy
  make install  # into /Applications, and open it
  ```
- **Tests in Xcode:** open `BatteryTraceKit/Package.swift` and test the
  **BatteryTraceKit-Package** scheme. From the command line that's
  `cd BatteryTraceKit && xcodebuild test -scheme BatteryTraceKit-Package -destination 'platform=macOS'`.

The build is signed to run locally. To give it to someone else, set your team
in Signing & Capabilities and notarize it. It runs outside the Mac App Store
because it uses private interfaces (see below).

### `bttrace`: the sampling layer without the UI

```sh
make cli                       # BatteryTraceKit/.build/release/bttrace
bttrace sources                # what each data source found on this Mac
bttrace sample --processes     # three 5 s intervals, attributed like the app does
bttrace totals                 # minute by minute, against the battery gauge
bttrace cost                   # what sampling costs, per tick and per minute
bttrace export --to ~/Desktop  # the app's history as two CSV files
make validate                  # rank apps against top's Energy Impact (no password)
make validate-powermetrics     # against sudo powermetrics, four scenarios (asks for your password)
make measure                   # the built app's own CPU, Energy Impact and memory
```

## What the numbers mean

| Shown as | What it is | Measured or estimated |
|---|---|---|
| **Watts** in the menu bar and summary | Total system power from the SMC's power sensor, averaged over the last three readings | Measured |
| **"from the battery"** / **"power draw, not from battery"** | On battery, that power drains the battery. On the adapter it doesn't, and the label says so. | — |
| **Time remaining**, health, cycles, temperature | From macOS's battery gauge. Health is macOS's own "Maximum Capacity", as System Settings shows it (read from `system_profiler` every 6 hours); the gauge's capacity in mAh is shown beside it. Temperature comes from the SMC. | Measured (time remaining is macOS's own estimate) |
| **Apps**, with share and energy (mWh) | The CPU, GPU and Neural Engine energy the chip measured, split by the kernel's per-app energy counters. Helpers and XPC services count for their app. | **Estimated** (marked "Estimated") |
| **Child processes** | That app's CPU share, split by each process's own energy counter. The rest is "Other or exited processes". | Estimated |
| **System / Unattributed** | Everything that isn't an app: display, memory, other chip blocks, and the measured power no counter accounts for. Listed among the apps by size; click it to see its parts. | Measured, except the display |
| **CPU, GPU, Neural Engine, Memory** | The chip's energy counters (IOReport, PMP group) | Measured by the chip's power manager |
| **Display backlight** | Brightness mapped to watts by a curve fitted against the power sensor: this Mac's own after **Settings › Measurement › Calibrate…**, otherwise a measured MacBook Air curve scaled to this Mac's panel size and brightness | **Estimate** (labelled) |
| **Display controller, other chip blocks** | The chip's display pipes; video codecs, image processor, always-on blocks | Measured |
| **Unattributed** | Measured total minus every component: Wi-Fi, SSD, audio, panel electronics, power conversion | Measured remainder |
| **Totals for 5 min, 1 hour, 24 hours** | The battery gauge's own running averages when they cover the window, otherwise the power sensor | Measured |

## How it works

| Layer | Module | Does |
|---|---|---|
| Sources | `PowerSources` | Reads IOKit, libproc and private interfaces: one type per source, all behind protocols. The only module that touches private APIs. |
| Sampling | `Sampling` | Runs a `DispatchSourceTimer` with leeway on a utility queue. A cheap live reading for the menu bar every 5 s, and attribution every 60 s (every 2 s with the window open). Slower in Low Power Mode and while the screens sleep, stopped while the Mac sleeps. |
| Attribution | `Attribution` | Pure, unit-tested functions: groups processes into apps, splits the energy, builds window totals |
| Storage | `Storage` | One SQLite file, `~/Library/Application Support/Battery Trace/history.sqlite`. Live readings for an hour, minutes (with charge and charging) for 7 days, app minutes for 24 h, then hours, and one battery-health reading a day, kept. Written every 5 minutes, pruned hourly, capped at 64 MB. |
| UI | `App/` | `NSStatusItem` and `NSPopover` with SwiftUI. Views exist only while the popover is open. |

A new metric is one type conforming to `ComponentSource` (energy) or
`SnapshotSource` (anything else). A privileged source would conform to
`PowerMetricsProvider` and replace the unprivileged one without other changes.
A `powermetrics` helper was built that way and measured, then dropped: its CPU
figure matched Battery Trace's to about 1%.

### Private interfaces, and what happens if Apple changes them

All are looked up at run time. A missing one hides its metric; the app doesn't crash.

| Interface | For | If it's gone |
|---|---|---|
| `libIOReport` (PMP and Energy Model energy counters) | CPU, GPU, ANE, memory and other chip blocks | Components hidden. App shares fall back to the kernel's own energy figures, marked as estimates. |
| `coalition_info_resource_usage`, `PROC_PIDCOALITIONINFO` | Per-app energy for every process, including root's | Per-process energy for your own processes only, grouped by app bundle and parent process |
| SMC user client, key `PSTR` | Live total power | The battery gauge's once-a-minute figure |
| `DisplayServicesGetBrightness` | Brightness for the display estimate | IORegistry brightness, which may be stale |
| `AppleSmartBattery` registry keys | Battery state, gauge telemetry | Each missing key hides one figure |

## Known limitations

- **Per-app figures are estimates.** They come from the kernel's energy model
  (CLPC) and the GPU driver's accounting.
- **Work done on an app's behalf is counted for whoever did it.** WindowServer
  draws windows, `coreaudiod` mixes audio, and the video decoder decodes video.
  Under heavy GPU load, macOS charges WindowServer for much of the GPU's time.
- **`sudo powermetrics` with its per-process sampler showed about 0.3 W more
  CPU.** With only its CPU sampler (`--samplers cpu_power`), it agrees with
  Battery Trace to about 1%. Why the per-process sampler adds to it isn't
  pinned down yet. See [docs/VALIDATION.md](docs/VALIDATION.md) §3.
- **The display estimate is a model.** Out of the box it's a curve measured on
  an M1 MacBook Air, scaled to your Mac's own panel by its size and peak
  brightness; **Settings › Measurement › Display › Calibrate…** measures your
  panel itself in under two minutes. It doesn't model HDR/XDR boost (it says when
  HDR is showing) or ProMotion.
- **Unattributed is typically 40–50% at light load,** and more while
  streaming (Wi-Fi, audio). It isn't spread across apps.
- **Intel Macs** have no IOReport energy counters and often no `PSTR`: fewer
  components, and app shares from the kernel's CPU model alone.

Validation results: [docs/VALIDATION.md](docs/VALIDATION.md).

## Privacy

No telemetry, no account. No permissions either, unless you turn on
notifications. Battery Trace goes online only to ask GitHub which version is
newest: when you choose **Check for Updates…**, or once a day if you turn that
on. That one request carries nothing about your Mac. History stays in the SQLite file
above; delete it to start over. **Export History…** (in the right-click menu and
Settings › History) writes it as two CSV files: energy by app, and the Mac's
totals and parts, minute by minute.

## Recommended next features

1. **A Developer ID.** The Release workflow already signs and notarizes when
   the signing secrets are set ([docs/RELEASING.md](docs/RELEASING.md)); then
   the "Open Anyway" step goes away.

## Project layout

```
BatteryTrace.xcodeproj   app target (App/) linking the local package
App/                     AppKit + SwiftUI shell: status item, popover, settings
BatteryTraceKit/         Swift package: Core, PowerSources, Attribution, Sampling, Storage, bttrace, tests
Scripts/                 validation and measurement scripts
docs/                    PLAN, ATTRIBUTION, VALIDATION, PERFORMANCE
```

The icon is drawn by `Scripts/make-icon.swift`; run `swift Scripts/make-icon.swift`
after changing it.
