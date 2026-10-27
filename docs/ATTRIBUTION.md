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
 ├─ Display controller (measured)               ├─ System row
 ├─ Other chip blocks (ISP, codecs, …, measured)│
 └─ Unattributed = total − all of the above     ┘
```

The app rows and the System row always add up to the measured total. The
System row is listed among the apps by size. Clicked, it shows its parts,
largest first.

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
P_backlight(s) = k × (−0.085·s + 5.12·s²)  W      s = brightness slider, 0…1
```

- **This Mac's own curve, when it has one.** Settings › Measurement › Display ›
  **Calibrate…** steps the slider for under two minutes with the Mac idle, reads
  `PSTR`, subtracts the chip's measured energy, and fits
  `rest = a + b·s + c·s²`. A fit quality (R²) below 0.6 means something else was
  busy, and the result isn't used. A calibrated Mac uses its own curve, with
  `k = 1`. `bttrace calibrate-display` runs the same measurement.
- **Otherwise, the reference curve above, scaled to this Mac's panel.** It was
  fitted on a MacBook Air (M1, 2020): the mean of two quiet runs, each with fit
  quality 0.99, at 4.8 and 5.3 W at full brightness. `k` scales it to whichever
  built-in panel Battery Trace runs on, by area × peak brightness relative to
  that one (286.9 × 179.3 mm, 420 nits). Both come from the Mac itself: the
  size from CoreGraphics, the peak from the backlight's `BrightnessMilliNits`.
  The peak is capped at 600 nits, because an XDR panel may report its
  1600-nit HDR peak, which would triple the estimate. Most panels' SDR peak
  is 400–600 nits, but 2024 and later MacBook Pros reach 1000, so on those
  the estimate may read low. It hasn't been checked on an XDR Mac yet. A 15-inch, 500-nit panel gets about 1.6 times the Air's curve.
  Settings › Measurement › Display shows the panel's size, peak and estimate.
  Scaling assumes the same kind of backlight. It's rough for a different kind
  (mini-LED), which is what calibrating replaces.
- **The curve is convex.** The slider is perceptual, so half brightness draws
  far less than half the power: about 1.2 W at half, against 5 W at full. The
  backlight current agrees: it read 7.5% of its maximum at half slider.
- **0.1–0.5 used a different curve, now replaced.** It was fitted while other
  work was running (fit quality 0.85): `4.78·s − 1.08·s²`, concave, 3.7 W at
  full and 2.1 W at half. It overstated the display at the brightness most
  people use by about 0.9 W, and so understated Unattributed.
- **When it's 0:** while the built-in display sleeps or is off (lid closed).
- **HDR content** on the built-in screen can drive the panel beyond what the
  brightness model expects. The System tab says when it's showing.
- **External displays** power themselves. Only their controller on the chip
  (`DISPX`) is counted, and the System tab says so.
- **Where the slider comes from:** `DisplayServicesGetBrightness` (private).
  Every brightness figure in the IORegistry (`AppleARMBacklight` →
  `IODisplayParameters`, backlight current included) stays frozen while the
  slider moves, so they serve only as a fallback.
- **The intercept stays in Unattributed.** The fits' intercepts (1.8–2.2 W at
  idle) are power that doesn't change with brightness. That includes the
  panel's electronics, but also Wi-Fi, the SSD and conversion losses, which
  can't be separated from them.

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
| CPU | `energy`: the kernel's per-thread CPU energy model (CLPC), nJ, **+ `energy_billed_to_me` − `energy_billed_to_others`** |
| GPU | `gpu_energy_nj`: GPU energy the driver bills to the coalition (macOS 15+), **+ `gpu_energy_nj_billed_to_me` − `gpu_energy_nj_billed_to_others`** |
| ANE | `ane_energy_nj` (macOS 15+) |

The billed terms come from the kernel's importance vouchers: when a service
(Spotlight's indexer, an XPC service, `coreaudiod`) works on a request from an
app, macOS records the energy as done *for* that app. With **Count work macOS
services do for an app** on (the default), it counts for the app; off, for the
service, as in Activity Monitor. A weight never goes below 0, and summed over
every app the billed terms cancel, so totals don't change. On the test Mac at
idle they were small: 1.7 mW of 196 mW over 10 s.

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

1. **Apple reports CPU energy in more than one place.** Battery Trace reads
   PMP's live cluster counters (`ECPU + PCPU`). `powermetrics` with only its
   CPU sampler agrees with them to about 1%, at idle and under load. Run with
   its per-process `tasks` sampler too, it reported 0.26–0.35 W more, for
   reasons not yet pinned down (`VALIDATION.md` §3).
   Whatever any counter misses stays inside the measured total, as part of
   Unattributed.
2. **The CPU weights are a model.** CLPC estimates each thread's energy from
   its cluster, frequency and time. It is good at "who ran on the P-cores, and
   how hard", but it is not a meter.
3. **Work done on an app's behalf is charged to whoever did it, unless macOS
   billed it.** Billing (above) moves what the kernel recorded back to the app,
   but only work done through voucher-carrying requests is recorded.
   - WindowServer composites every window on the GPU, and that energy is
     charged to WindowServer, not to the app being drawn.
   - Audio mixing (`coreaudiod`), video decoding (`VTDecoderXPCService` plus
     the `VDEC` block), Spotlight indexing (`mds`) and network work stay with
     the service wherever macOS doesn't bill them.
   - The GPU's billed counters read 0 on the test Mac: WindowServer's
     compositing isn't billed to the app being drawn.
   - Under heavy GPU load the effect is large. With a Metal compute load
     running, the kernel charged WindowServer 2.39 W of GPU energy against
     1.05 W for the process doing the work. WindowServer's frames wait behind
     the long dispatches and are billed for the occupancy. The driver's own
     per-process GPU time shows the same split, and so does Activity Monitor's
     Energy Impact, so a GPU-heavy app can rank below WindowServer.
4. **Media engines and memory aren't split across apps.** Video decode and
   encode, the image processor and DRAM show as system components. The brief
   asks for CPU, GPU and ANE only to be split.
5. **The display figure is a model.** Uncalibrated, it's one panel's curve
   scaled to another; calibrated, it's this panel's, measured under the
   conditions of the calibration. It doesn't model HDR/XDR boost (it says
   when HDR is showing) or ProMotion, and it doesn't see auto-brightness
   changes between readings. An external display powers
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
