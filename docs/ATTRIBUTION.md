# How Battery Trace attributes power

macOS has no public per-app battery API. Every per-app figure Battery Trace
shows is an **estimate**, built from one measured whole and kernel counters
that decide each app's share. This page explains each number, where it comes
from, and how it can be wrong.

## The chain, in one picture

```
 measured total (battery gauge / SMC)            ← ground truth
 ├─ CPU          (IOReport PMP, measured) ──┐
 ├─ GPU          (IOReport PMP, measured) ──┼─ split across apps by the kernel's
 ├─ Neural Engine(IOReport PMP, measured) ──┘   per-coalition energy counters
 ├─ Memory       (DRAM + controller, measured)  ┐
 ├─ Display      (backlight model, ESTIMATE)    │
 ├─ Display controller (measured)               ├─ System / Unattributed row
 ├─ Other chip blocks (ISP, codecs, …, measured)│
 └─ Unattributed = total − all of the above     ┘
```

The app rows and the System / Unattributed row always add up to the
measured total.

## 1. The measured total

| Source | What it is | Used for |
|---|---|---|
| Battery gauge `PowerTelemetryData` (`AccumulatedSystemLoad` ÷ `SystemLoadAccumulatorCount`) | The gauge samples system load about once a second and keeps a running sum. Two readings a refresh apart (the registry refreshes every 60 s) give the **true average** over that minute. Available on AC and on battery. | **Ground truth** for every window of 5 minutes or more |
| SMC key `PSTR` | The system's total power rail, instantaneous. No root needed. | The live figure in the menu bar and popover; the total for short intervals. Integrated with trapezoids over every reading (each 2–5 s). |
| Battery `Voltage × InstantAmperage` | Battery discharge, also refreshed about once a minute | Fallback on battery when neither of the above exists |

For a window *W* (Last 5 min, 1 hour, 24 hours):

```
Total(W) = E_gauge(W) × duration(W) / covered_by_gauge(W)    if the gauge covers ≥ 80% of W
         = E_sensor(W) × duration(W) / covered_by_sensor(W)  else if the sensor covers ≥ 80%
         = Σ components                                       else (Unattributed is then unknown, shown as —)
```

**On AC** the same total is shown as *power draw*, with a note that it isn't
draining the battery.

## 2. Components

From IOReport (private `libIOReport`), group `PMP`, subgroup
`Energy Counters`, in millijoules. The difference between two readings is the
energy in between.

| Component | Channels (M1, macOS 27) | Notes |
|---|---|---|
| CPU | `ECPU + PCPU` (cluster totals) | `ECORE*`, `PCORE*`, `ECPM`, `PCPM` are parts of those totals (ECPU = Σ ECORE + ECPM, within 0.2%), so they're never added |
| GPU | `GPU + GPU SRAM` | |
| Neural Engine | `ANE` | |
| Memory | `DRAM + DCS` | DCS is the DRAM controller |
| Display controller | `DISP + DISPX` | The SoC's display pipes. Not the panel. |
| Other chip blocks | everything else PMP counts: `SOC_AON, SOC_REST, ISP, AVE, VDEC, MSR, BAT` | Video decode (`VDEC`) and encode (`AVE`) land here, not on the app |

Each component has an ordered list of candidate channels:

1. PMP's counters.
2. The "Energy Model" group's totals (`CPU Energy`, `GPU Energy`).
3. Older chips' names.

The first candidate that moves during a 30 s warm-up is used. A candidate that
then stays still for six readings while another one moves is replaced. This
matters because Apple changes these counters between OS releases. On this Mac,
"Energy Model"'s CPU channels report a delta of 0 even under load, while PMP's
move. Channels that no chosen driver needs are then unsubscribed, because each
driver costs about 0.65 ms per read.

### The display backlight: a model, always labelled "estimate"

```
P_backlight(s) = k × (4.78·s − 1.08·s²)  W      s = brightness slider, 0…1
```

- The curve was fitted on a MacBook Air (M1, 2020) with `bttrace
  calibrate-display`. That steps the slider with the Mac idle, reads `PSTR`,
  and subtracts the SoC's measured energy. Two runs gave 3.5 and 3.7 W from the
  lowest to the highest setting; the fit's R² was 0.85.
- `k` scales the curve to other built-in panels by peak brightness × area
  relative to that one (420 nits, 286.9 × 179.3 mm). That's a rough
  extrapolation.
- The display power is 0 while the built-in display sleeps or is off (lid closed).
- The slider comes from `DisplayServicesGetBrightness` (private). Every
  brightness figure in the IORegistry (`AppleARMBacklight` →
  `IODisplayParameters`, backlight current included) stayed frozen while the
  slider moved from 0.05 to 1.0, so they serve only as a fallback.
- The fit's intercept (1.28 W at idle) is power that doesn't change with
  brightness. It includes the panel's electronics, but also Wi-Fi, the SSD and
  conversion losses, and can't be separated from them. It stays in Unattributed.

## 3. Unattributed

```
Unattributed = max(0, Total − Σ components)
```

Unattributed is the measured power that no counter accounts for:

- Wi-Fi and Bluetooth
- The SSD
- Audio amplifiers and speakers
- The keyboard backlight
- The panel's electronics
- USB-C and Thunderbolt controllers
- Sensors
- Power-conversion losses
- Display-model error

Battery Trace shows it as a row and never spreads it across apps.

If the components add up to *more* than the measured total, Unattributed is
0. For a window, every row is then scaled down to fit and the scale factor is
shown. This happens over short intervals, when the instantaneous sensor and
the cumulative counters aren't in step; over minutes it averages out.

## 4. Apps

Apps are the kernel's **resource coalitions**, merged by `.app` bundle.

- **What a coalition is:** a coalition holds an app with its helpers, XPC
  services and renderers. It's what Activity Monitor and `powermetrics
  --show-process-coalition` group by.
- **Why coalitions:** reading them needs no privileges
  (`coalition_info_resource_usage`, private), so root daemons and WindowServer
  are covered. `proc_pid_rusage` refuses them without root. A coalition's
  counters also keep counting helpers that have exited.
- **Merging:** an app's launchd-started helpers get coalitions of their own.
  Merging by outermost `.app` bundle folds them back into the app.

For each of CPU, GPU and ANE (*k*), over an interval:

```
E_k(app i) = E_k(measured) × w_k(i) / Σ_j w_k(j)
```

| k | weight w_k(i): the delta, over the interval, of the coalition's… |
|---|---|
| CPU | `energy`: the kernel's per-thread CPU energy model (CLPC), nJ |
| GPU | `gpu_energy_nj`: GPU energy the driver bills to the coalition (macOS 15+) |
| ANE | `ane_energy_nj` (macOS 15+) |

The kernel's counters are a model, so they decide only each app's *share*. The
SoC's measured counters decide the *watts*. If no app's weight is non-zero, the
energy stays in the System row as "unclaimed".

**Fallbacks:**

- **No IOReport component:** if a weight is in energy units, the kernel's own
  figure (`Σ w × 1 nJ`) stands in, marked as an estimate.
- **macOS 14:** coalitions have no GPU energy, so GPU weights come from each
  process's `accumulatedGPUTime` in the IORegistry. GPU time is never shown as
  energy.

### Child processes

An app's CPU share is split by its processes' own `proc_pid_rusage`
`ri_energy_nj` (V6; V4's `ri_billed_energy` before that):

```
E_cpu(process p) = E_cpu(app) × ri_energy_nj(p) / max(coalition energy, Σ readable processes)
```

Whatever the readable processes don't account for becomes one **"Other or
exited processes"** row, so the rows always add up to the app. That remainder
is other users' processes, which `proc_pid_rusage` refuses without root, and
helpers that exited mid-interval. Over longer windows, processes are merged
by name, since PIDs come and go.

## Known error sources

1. **Apple has two CPU energy counters, and they disagree by about 0.3 W.**
   Battery Trace reads PMP's live cluster counters. `powermetrics` reports the
   "Energy Model" counter, which without root refreshes only every ~5 minutes.
   On the test Mac the gap was a near-constant 0.26–0.35 W, from idle to a
   4-thread loop. That means our CPU row reads low by that much, which is a
   third of `powermetrics`' figure at idle. The rest isn't lost: it is part of
   Unattributed, within the measured total.
2. **The CPU weights are a model.** CLPC estimates each thread's energy from
   its cluster, frequency and time. It is good at "who ran on the P-cores, and
   how hard", but it is not a meter.
3. **Work done on an app's behalf is charged to whoever did it.**
   - WindowServer composites every window on the GPU, and that energy is
     charged to WindowServer, not to the app being drawn.
   - Audio mixing (`coreaudiod`), video decoding (`VTDecoderXPCService` plus
     the `VDEC` block), Spotlight indexing (`mds`) and network work work the
     same way.
   - Battery Trace uses the energy each coalition *did*, as Activity Monitor
     does. The kernel's "billed to me / billed to others" counters could move
     some of it back, which is one of the next features. On the test Mac they
     read 0 for GPU work.
   - Under heavy GPU load the effect is large. With a Metal compute load
     running, the kernel charged WindowServer 2.39 W of GPU energy against
     1.05 W for the process doing the work. WindowServer's frames wait behind
     the long dispatches and are billed for the occupancy. The driver's own
     per-process GPU time shows the same split, and so does Activity Monitor's
     Energy Impact, so a GPU-heavy app can rank below WindowServer.
4. **Media engines and memory aren't split across apps.** Video decode and
   encode, the image processor and DRAM show as system components. The brief
   asks for CPU, GPU and ANE only to be split.
5. **The display figure is a model of one panel.** On other Macs it's an
   extrapolation. It doesn't model HDR/XDR boost or ProMotion, and it doesn't
   see auto-brightness changes between readings. An external display powers
   itself; only its SoC-side controller (`DISPX`) is counted.
6. **Timing.** The live sensor is instantaneous and integrated every 2–5 s
   (every 60 s while the screens sleep). The gauge's windows end up to a minute
   before the reading that reports them. Over a single short interval,
   components and the total can disagree by tens of percent; over 5 minutes
   they agree.
7. **Quiet coalitions are read every fourth tick** to keep sampling cheap. Their
   small energy lands in a later interval: window totals are unchanged, but
   per-interval figures shift slightly.
8. **Exited coalitions.** If a coalition is reaped between two reads, its last
   interval is lost to Unattributed. A whole app quitting mid-interval is the
   case where this matters.
9. **Process names** come from the executable's file name. The kernel's short
   name (16 characters) is used only when the path is unreadable.
10. **Private APIs move.** Channel names, struct layouts and keys are discovered
   at run time and checked. A missing one hides its metric instead of guessing.
   The coalition struct is append-only from xnu-10002 (macOS 14) to xnu-12377
   (macOS 26/27), and the kernel copies `min(ours, its)` bytes, so a newer
   kernel can't shift these fields.
11. **Intel Macs** have no IOReport energy counters and often no `PSTR`.
    Attribution then falls back to the kernel's CPU energy, and most components
    are hidden.

See `docs/VALIDATION.md` for how close these estimates came to `powermetrics`,
`top` and the battery gauge on the test Mac.
