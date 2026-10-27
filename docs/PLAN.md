# Battery Trace for Mac — plan and risks

Written before any app code, after probing the data sources on the development
Mac: a **MacBook Air (M1, 2020), `MacBookAir10,1`, macOS 27.0.1 (26A434)**,
Xcode 27.0, Swift 6.4.

## Targets

- **macOS 14 or later**, Apple silicon first. Intel builds and runs, but
  shows fewer metrics (see the fallback column below).
- A menu bar app (`NSStatusItem` + `NSPopover` hosting SwiftUI), with
  `LSUIElement = true` so there is no Dock icon. I chose `NSStatusItem` over
  `MenuBarExtra` because the popover's open and close events drive the
  sampling rate, and `MenuBarExtra` doesn't expose them reliably.
- Bundle identifier `app.batterytrace.BatteryTrace`.
- No third-party dependencies. SQLite comes from the system's `libsqlite3`.

## What probing this Mac showed

The brief's list of sources was a good starting point. Four findings changed
the design:

1. **`proc_pid_rusage` only works on your own processes.** XNU checks
   `CHECK_SAME_USER`, and 202 of the 549 processes here returned `EPERM`:
   WindowServer, `kernel_task` and every root daemon. Per-process rusage alone
   would leave a large unexplained remainder.
2. **Coalitions work for every process.** Coalitions are the kernel's
   app-level groups; `powermetrics --show-process-coalition` and Activity
   Monitor use them.
   - `proc_pidinfo(PROC_PIDCOALITIONINFO)` is `NO_CHECK_SAME_USER`.
   - `coalition_info_resource_usage()` has no privilege check (the XNU
     source reads `/* TODO: priv check? */`).
   - Each coalition carries cumulative **CPU energy (nJ), GPU energy (nJ), ANE
     energy (nJ)**, CPU time, wakeups and disk I/O. Exited helpers stay counted.
   - In the probe, the coalitions' summed GPU energy (0.022 W) matched IOReport's
     GPU channel (~0.02 W).
3. **On this macOS, the IOReport "Energy Model" CPU channels are frozen.**
   Their delta is 0 even under load; only `GPU Energy` moves. The live CPU,
   DRAM, ANE, display-controller and media counters are in group **`PMP`,
   subgroup `Energy Counters`** (mJ). The provider therefore picks, for each
   component, the first candidate channel that is actually moving.
4. **There are two measured totals, at two speeds.**
   - `AppleSmartBattery` only refreshes **every 60 s**. Its
     `PowerTelemetryData` accumulators (`AccumulatedSystemLoad` /
     `SystemLoadAccumulatorCount`) give a true 60 s average of system power,
     **on AC as well as on battery**. This is the ground truth.
   - The SMC key **`PSTR`** gives live total system power without root, in
     about 0.1 ms. It feeds the live readout.

## Data sources, private APIs and fallbacks

Private APIs are reached only through `dlopen`/`dlsym` or undocumented IOKit
properties. All of them live in one module, `PowerSources`, behind protocols. A
missing symbol, channel or key marks that source *unavailable*: the UI hides the
metric, and the app doesn't crash.

| Metric | Primary source | Private? | Fallback when missing |
|---|---|---|---|
| Measured total (ground truth) | `AppleSmartBattery` `PowerTelemetryData` accumulators, 60 s windows | Undocumented IOKit keys | Battery `Voltage × Amperage` (on battery only), then the SMC total |
| Live total | SMC `PSTR` via the `AppleSMC` user client | Private user client | The last 60 s ground truth plus live components, labelled as an estimate |
| CPU / GPU / ANE / DRAM / media power | IOReport `PMP/Energy Counters` + `Energy Model` (`GPU Energy`), first moving channel per component | Private `libIOReport` | That component is hidden. Its energy appears in Unattributed. |
| Per-app CPU, GPU and ANE energy | Coalition resource usage (nJ counters) | Private syscall wrapper | `proc_pid_rusage` V6 `ri_energy_nj` (own user only), then V4 `ri_billed_energy`, then CPU time, then IORegistry GPU-client time for GPU |
| Child processes within an app | `proc_pid_rusage` V6 per PID | Public | The app's total is shown, with the note "details need privileges" |
| Process → app grouping | Coalition ID, then the outermost `.app` bundle in the process path, then `NSRunningApplication` for name and icon | Coalition ID is private | Group by `.app` path, then parent-process ancestry |
| Battery %, charging, time remaining | `IOPowerSources` (public) | No | — |
| Cycle count, health, temperature, voltage | `AppleSmartBattery` registry | Undocumented keys | Hidden |
| Display brightness | `DisplayServicesGetBrightness` | Private framework | `AppleARMBacklight` `IODisplayParameters.brightness` |
| Display power (estimate) | Brightness slider × a curve calibrated against the power sensor (`bttrace calibrate-display`), plus IOReport display-controller energy | Private framework (slider) | The IORegistry brightness, which is frozen on Apple silicon; always labelled **estimate** |
| CPU load per core, memory, thermal state | `host_processor_info`, `host_statistics64`, `vm.swapusage`, `ProcessInfo.thermalState` | Public | — |
| Optional privileged source | `PowerMetricsProvider` protocol, reserved for a future `SMAppService` daemon running `powermetrics` | — | Not built in the MVP |

**Main risks**

- Apple changes channel names, struct layouts or keys in an OS update. The
  layouts are taken from xnu-12377 (macOS 26/27) and are size-checked at
  runtime. Channels are discovered by name.
- Coalition energy is a kernel *model* (CLPC per-thread energy), not a meter. It
  sets each app's *share*. The measured component total sets the watts.
- The display figure is a model, and Apple can change backlight behaviour.

## Attribution model (detail in `docs/ATTRIBUTION.md`)

```
Total (measured)   = battery/system telemetry over the window
Components         = CPU + GPU + ANE + DRAM + display (est.) + other SoC     (IOReport, model)
Unattributed       = Total − Components     (Wi-Fi, SSD, audio, power conversion losses…)
App_i CPU          = CPU × ΔE_cpu(i) / Σ ΔE_cpu      (coalition nJ deltas)
App_i GPU, App_i ANE: the same, with GPU and ANE deltas
System row = DRAM + display + other SoC + Unattributed + any CPU/GPU/ANE not covered by an app
```

The rows always add up to the measured total. Per-app figures are labelled
"estimated". When plugged in, the app says "power draw", not "drain".

## Architecture

```
BatteryTraceKit (Swift package; Xcode app target links it)
  BatteryTraceCore   value types + provider protocols (no IOKit)
  PowerSources       every IOKit/libproc/private-API reader; one type per source
  Attribution        pure functions: grouping + energy split (unit-tested with fixtures)
  Sampling           engine: timer policy, cumulative→delta tracking, pipeline
  Storage            SQLite history with downsampling + pruning
  bttrace            CLI: the sampling layer, headless, for validation
App/                 AppKit status item + SwiftUI popover/settings
```

To add a metric, write one type that conforms to `ComponentSource` (or
`ProcessEnergySource`) and register it. Attribution and the System section pick
it up through its `ComponentID`.

## Lightness budget

Back-to-back probes suggested about 4 ms of CPU per sample. Real ticks cost
more, 5–9 ms, because each one wakes a cold efficiency core at low clock. So
sampling runs at two speeds:

- **Live**, every 5 s while the popover is closed: the SMC total and battery
  state for the menu bar. About 0.35 ms.
- **Attribution**, the full pipeline: once a minute while the popover is
  closed, every 2 s while it is open. Every counter it reads is cumulative,
  so the minute in between loses nothing.

Measured cost: 9 ms of CPU per minute with the popover closed (0.015% of a
core), and 0.27% with it open. Run `bttrace cost` to repeat it.

- **Timer:** one `DispatchSourceTimer` with 10% leeway on a utility-QoS serial
  queue.
- **Cadence:** 2 s while the popover is open, 5 s while it's closed, 10 s in Low
  Power Mode, and 60 s while the screens sleep. Because every counter is
  cumulative, a slower rate loses time resolution, not energy.
- **Cheap reads:** quiet coalitions are read every fourth tick, and per-process
  counters only for coalitions that used energy. After warm-up, IOReport keeps
  only the drivers it needs.
- **Sleep:** no sampling while the Mac sleeps, and the interval that spans sleep
  is discarded.
- **Memory:** buffers are reused, and process paths are looked up once per
  `(pid, start time)`.
- **UI:** updates are published only while the popover is visible. The menu bar
  title is redrawn only when its text changes.
- **Storage:** writes are batched once a minute.

## Process

1. ✅ Build the sampling layer and `bttrace` CLI, with 44 unit tests.
2. ✅ Check it against the battery gauge (sensor/gauge 1.001, 31.8%
   unattributed) and `top`'s Energy Impact (Spearman 0.69–0.95 over the top
   apps). See `docs/VALIDATION.md`.
3. ✅ Check it against **`sudo powermetrics`** in four scenarios: the same top 5
   apps in each; GPU and ANE watts within 3%; CPU about 0.3 W lower, because
   it reads a different Apple counter. See `docs/VALIDATION.md`.
4. ✅ Build the UI, then measure the app itself: 0.070% CPU and 15 MB with the
   popover closed. See `docs/PERFORMANCE.md`.
