# Validation

**Test Mac:** MacBook Air (M1, 2020), `MacBookAir10,1`, 8 GB. macOS 27.0.1
(build 26A434). Battery at 625 cycles, 77% of design capacity. Low Power Mode
on. Xcode 27.0, Swift 6.4. Results are from the `bttrace` CLI, which runs the
app's sampling layer headless.

Raw output goes to `validation/` (not committed). Re-run everything with
`make validate`, `make totals` and `make validate-powermetrics`.

## 1. Do the components add up to the measured total?

`bttrace totals` samples the way the app does: a live reading every 2 s and
attribution once a minute. It sets each minute against the battery gauge's own
average for that minute. The run was 5 minutes, on battery, at light load (a
terminal and a browser), with brightness at about 50% and auto-brightness on.

| minute | live sensor (SMC, integrated) | battery gauge | components | unattributed |
|---:|---:|---:|---:|---:|
| 1 | 4.80 W | 4.78 W | 3.02 W | 36.7% |
| 2 | 4.77 W | 4.77 W | 3.13 W | 34.5% |
| 3 | 4.41 W | 4.40 W | 3.00 W | 31.7% |
| 4 | 4.07 W | 4.08 W | 2.96 W | 27.6% |
| 5 | 4.03 W | 4.03 W | 2.93 W | 27.3% |

- **The live sensor agrees with the gauge to 0.1%** (4.42 W vs 4.41 W
  averaged). Integrating `PSTR` every 2 s is a sound live total between the
  gauge's once-a-minute refreshes.
- **Average unattributed: 31.8%** of the measured total (27–37%), about 1.4 W.
  That is the power no counter covers: Wi-Fi, SSD, audio, panel electronics and
  power conversion. The display calibration puts that brightness-independent
  floor at about 1.3 W on this Mac.
- **Since 0.6.0 the display curve is better measured, and Unattributed is
  larger.** Two quiet calibration runs (fit quality 0.99) showed the display
  draws far less at mid brightness than the first fit said. At this run's
  ~50% brightness that is about 1.3 W instead of 2.2 W. Recomputed with it,
  this run's components come to about 2.15 W, and Unattributed to about 51%.
  The figures in the table above are as measured with 0.1's curve. See
  `ATTRIBUTION.md` › The display backlight.
- **The display model matters most.** Before calibration, the backlight was
  modelled from the backlight current in the IORegistry, which turned out to be
  frozen. Unattributed was then 66–81%. After calibration against the sensor it
  is 27–37%.

## 2. Ranking against `top` (Activity Monitor's Energy Impact)

`Scripts/validate.sh` runs four 5-second intervals with `top -stats
pid,power` alongside. It maps `top`'s PIDs to apps through their coalitions and
compares the two rankings. `top`'s POWER is the "Energy Impact" score Activity
Monitor shows. It is a unitless weighting of CPU time, wakeups and GPU time,
not energy, so the test is agreement in **ranking**.

| Load | Spearman, our top 8 | Top-5 overlap | Pearson (values) | Spearman, all apps |
|---|---:|---:|---:|---:|
| Idle (terminal, browser in background) | 0.69 | 4 of 5 | 0.74 | 0.59 (17 apps) |
| CPU loop (4 threads, `bttrace stress cpu`) | 0.92 | 3 of 5 | 1.00 | 0.30 (20 apps) |
| GPU load (Metal compute, `bttrace stress gpu`) | 0.95 | 4 of 5 | 0.97 | 0.54 (19 apps) |

An earlier run of the same three loads gave Pearson 0.98, 0.98 and 0.87.

**The app at the top agrees every time.** Under load, the loaded app leads by
an order of magnitude in both tools. Rank correlation over *all* apps is low
because most of them use 0–6 mW, and below that level both tools' ordering is
mostly noise.

Where the two disagree, and why:

- **WindowServer ranks higher in `top` at idle.** It ran at 36% of an
  efficiency core at low clock. Energy Impact weights CPU *time*, but at that
  clock the *energy* is small (50–75 mW). Battery Trace ranks by energy.
- **`kernel_task`: we show 5–60 mW, `top` shows under 1.** We count the
  kernel coalition's energy (interrupts, the scheduler). Energy Impact treats
  `kernel_task` specially.
- **Under the GPU load, WindowServer is charged two-thirds of the GPU's
  energy.** The kernel's per-coalition GPU energy gave WindowServer 2.39 W
  against 1.05 W for the process doing the compute. The driver's per-process
  GPU time agrees: 387 vs 502 ms/s in the IORegistry, and 603 vs 1266 ms/s
  in the coalitions. `top` ranks WindowServer first too (37.7 vs 32.2).
  WindowServer's compositing waits behind long compute dispatches, and macOS
  bills it for the time. Battery Trace reports what the kernel reports; this is
  listed under known error sources in `ATTRIBUTION.md`.

## 3. Against `sudo powermetrics`

`make validate-powermetrics` ran on battery on 25 October 2026. In each of four
scenarios, `powermetrics` and `bttrace sample` ran side by side for the same
15 s:

```
powermetrics --samplers tasks,cpu_power,gpu_power --show-process-energy --show-process-coalition -i 5000 -n 3
```

Apps were joined on coalition ID, which both tools report. `powermetrics`
gives per-coalition Energy Impact and CPU time, not energy, so per-app agreement
is measured by rank.

The CPU and GPU loads were started from macOS's administrator dialog, so they
ran in that helper's coalition and show as "authtrampoline". Both tools agree
on that.

### Per-app ranking

| Scenario | Leading apps, Battery Trace | Spearman, our top 8 vs Energy Impact | Top-5 overlap | Pearson (values) | Spearman vs CPU+GPU time |
|---|---|---:|---:|---:|---:|
| Idle | iTerm2 62 mW, WindowServer 54 mW, authtrampoline 14 mW | 0.88 | 5 of 5 | 0.99 | 0.81 |
| CPU loop (4 threads) | authtrampoline 0.72 W, WindowServer 68 mW, iTerm2 67 mW | 0.98 | 5 of 5 | 1.00 | 0.67 |
| Video in Safari (Apple's HLS test stream) | WindowServer 0.26 W, iTerm2 80 mW, Safari 57 mW | 0.93 | 5 of 5 | 0.97 | 0.87 |
| GPU load (Metal compute) | authtrampoline 2.67 W, Apple Intelligence's inference service 0.32 W, kernel_task 0.11 W | 0.17 | 4 of 5 | −0.08 | 0.84 |

In the GPU scenario, Energy Impact gave the process that drove the GPU at
1006 ms/s only 2.2 per second. On macOS 27, `powermetrics`' Energy Impact
barely weights GPU time. Battery Trace gave that process 2.67 W of the GPU's
measured 2.66 W, and against CPU+GPU *time* the ranking agrees (0.84).
For GPU loads, Energy Impact isn't the right yardstick.

7–10% of Energy Impact sat in `powermetrics`' `DEAD_TASKS_COALITION`, a
pseudo-coalition for exited processes. Battery Trace has no such row: the
kernel keeps an exited process's energy in its real coalition, so it stays
with its app.

### Components

| Scenario | CPU: ours / theirs (with `tasks`) | GPU: ours / theirs | ANE: ours / theirs |
|---|---|---|---|
| Idle | 0.14 / 0.43 W | 6 / 3 mW | 0 / 0 |
| CPU loop | 0.93 / 1.22 W | 1 / 1 mW | 0 / 0 |
| GPU load | 0.40 / 0.66 W | **2.66 / 2.74 W (0.97)** | **0.28 / 0.28 W (1.00)** |
| Video in Safari | 0.48 / 0.83 W | **0.11 / 0.11 W (1.00)** | 0 / 0 |

**GPU and ANE agree to within 3%.**

**In this run, CPU read about 0.3 W lower than `powermetrics` in every
scenario** (+0.29, +0.29, +0.26 and +0.35 W). That gap comes with the way
`powermetrics` ran here, not from the counters themselves.

With only its CPU sampler, `powermetrics` agrees with Battery Trace to about 1%.
The check ran `powermetrics --samplers cpu_power -i 0` as root, taking a sample
at the same moment as each of Battery Trace's own readings, so both covered
the same 10-second intervals:

| Load | Battery Trace (PMP `ECPU + PCPU`) | `powermetrics`, CPU sampler only | Difference |
|---|---:|---:|---:|
| Idle, 8 intervals | — | — | +0.03 W on average |
| 4-thread loop, 5 intervals | 1.30 W | 1.33 W | +0.6% |

That check used a prototype privileged helper (PR #25), dropped because of
this result: root adds nothing to the CPU figure. Raw files are in
`validation/20261025-helper-cpu/`.

The 0.3 W above appeared with the per-process `tasks` sampler on (part of
`powermetrics`' default set) and `--show-process-energy`. Why that mode
reports more CPU hasn't been pinned down.

A third figure, the "Energy Model" counter (`CPU Energy`), refreshes only
about every 5 minutes without root. One 6-minute log put it at 0.64 W against
PMP's 0.57 W over the same span. Battery Trace uses PMP, which is live for any
caller.

### Totals during these runs

| Scenario | measured (SMC) | components | unattributed |
|---|---:|---:|---:|
| Idle | 4.19 W | 2.39 W | 43% |
| CPU loop | 4.63 W | 3.19 W | 31% |
| GPU load | 8.19 W | 5.88 W | 28% |
| Video in Safari | 6.45 W | 3.10 W | 52% |

The video's extra Unattributed is mostly the Wi-Fi radio streaming and the
audio amplifier, neither of which has an energy counter. Video decode itself
shows under "other chip blocks", which rose from 0.03 to 0.09 W. These
15-second figures use only two sensor readings each, so they are noisier than
the 5-minute run in section 1.

Raw files: `validation/20261025-034930-powermetrics/` (the plist and text
output for each scenario, our JSON, and each comparison).

## 4. Failure handling

Every source reports whether it is available, and `bttrace sources` lists
what each one found. On this Mac:

- **IOReport:** the "Energy Model" CPU channels are frozen, so CPU comes from
  PMP. After warm-up the frozen channels and the PCIe driver are unsubscribed.
- **The ANE counter** didn't move at idle. Its row appears once it does.
- **The backlight current** in the IORegistry is frozen, so the model uses the
  DisplayServices slider.

A missing symbol, channel or key hides its metric. Nothing assumes it exists.
