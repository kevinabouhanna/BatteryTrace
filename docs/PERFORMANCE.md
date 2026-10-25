# Performance

Battery Trace is judged partly by how little it shows up in its own
measurements. Everything below was measured on the Release build, on a
MacBook Air (M1, 2020) running macOS 27.0.1, on battery, with Low Power Mode on.

## Results

| | Target | Popover closed | Popover open |
|---|---|---:|---:|
| CPU (`ps`, whole app, 5 min / 90 s) | < 0.5% average | **0.070%** of one core | 0.60% |
| Energy Impact (`top` POWER, the figure Activity Monitor shows) | "Low" | **0.0** | 0.5 |
| Rank among all running processes by Energy Impact | not near the top | **51st** | 15th |
| Memory footprint | < ~50 MB | **15 MB** | 16 MB |
| Rank in its own Apps list (last 15 min, including 90 s open) | not near the top | **36th of 290 apps, 0.09%** of attributed energy | |

- With the popover **closed** (most of the time), Battery Trace used 0.21 s
  of CPU in 5 minutes. A second run gave 0.073%.
- With the popover **open**, it updates every 2 s while someone is looking.
- The CPU figures come from the process's own CPU time (`ps`) before and after,
  and from `top`'s second sample, which covers the whole span. Reproduce them
  with `make measure` (`Scripts/measure-app.sh`).

### Where the time goes

`bttrace cost` times the sampling layer stage by stage, on a cold efficiency
core (the real case) after warm-up:

| Stage | Full (attribution) tick |
|---|---:|
| IOReport, PMP energy counters (one driver after warm-up) | 1.95 ms |
| Coalition usage (about 80–170 of ~420 coalitions read; quiet ones every 4th tick) | 1.64 ms |
| Per-process counters (only in coalitions that used energy) | 0.51 ms |
| Process table (cached identities; no system call for known PIDs) | 0.39 ms |
| Grouping into apps (names cached per coalition) | 0.29 ms |
| Attribution | 0.10 ms |
| Battery, SMC, display, telemetry | ~0.5 ms |
| **Whole full tick** | **5.5 ms** |
| **Quick (menu bar) tick**: SMC total and battery | **0.35 ms** |

Popover closed, the engine runs one full tick a minute and a quick tick every
5 s: about **9 ms of CPU per minute** for sampling (0.015%). The rest of the
measured 0.070% is the app around it: the menu bar title redrawing every 5 s,
the 5-minute history write, and the run loop.

### Instruments

Traces are in `validation/instruments/`.

- **Time Profiler**, popover open, 30 s (the busiest case): 240 ms of CPU
  (0.8% with the profiler attached), 173 ms on background queues and 67 ms on
  the main thread.
  - **Self time is dominated by the kernel calls the data needs:**
    `__coalition_info` 38 ms, `mach_msg2_trap` (IOReport, IOKit) 30 ms,
    `__proc_info` 25 ms.
  - **Battery Trace's own heaviest frames:** `CoalitionReader.read` (38 ms) and
    `ProcessTableReader.rusage` (20 ms), both waiting on those calls, then
    `IOReportComponentSource.readComponents` (19 ms).
  - **What it led to:** `DisplayBacklightSource.brightness()` (14 ms) was asking
    the window server twice per tick. It now reuses the first answer within
    the tick.
- **Allocations**, popover closed, 130 s: recorded. `xctrace` doesn't export
  its tables, so the allocation check was done from outside:
  - Over 5 minutes, live malloc nodes went from 25,024 to 25,132 (+0.4%), and
    the footprint from 14 MB to 15 MB. That is the history buffer filling before
    its 5-minute write. Nothing grows with the number of ticks.
  - With Allocations attached, the footprint reads 43 MB. That is Instruments
    recording every allocation's stack, not the app.
- **Power Profiler**, 60 s: recorded, but this Xcode exposes no exportable
  table for a process. Energy Impact from `top` (above) is the same figure
  Activity Monitor shows. Energy Log is iOS-only.

### With the optional privileged helper

The helper and its `powermetrics` are separate root processes, so the figures
above don't include them. Measured as root on the same Mac:

| | `powermetrics --samplers cpu_power -i 0` |
|---|---:|
| Starting | 0.67 s of CPU, once per Battery Trace launch |
| One sample (on request) | about 10 ms of CPU; the reply arrives in 12–28 ms |
| Between samples | nothing: no timer, 0 s of CPU over 30 s idle |
| Memory | 1.9 MB |

Battery Trace asks for one sample per attribution. That is once a minute with
the popover closed, about 0.02% of one core, and every 2 s with it open, about
0.5%. The CPU sampler alone is used: adding the GPU and ANE samplers made each
sample cost about 14 ms instead.

## What keeps it light

1. **Two speeds.** The menu bar needs one sensor read every 5 s (0.35 ms).
   Splitting energy across apps runs once a minute while the popover is closed.
   Every counter is cumulative, so the minute in between loses nothing.
2. **Back off when nobody looks.** It samples every 10 s in Low Power Mode and
   every 60 s while the screens sleep, and stops while the Mac sleeps.
3. **One timer.** A `DispatchSourceTimer` with 10% leeway on a utility-QoS
   queue, so the kernel can batch its wakeups with others'. No run-loop timers,
   no busy loops.
4. **Ask the kernel only what changed.**
   - Quiet coalitions are read every fourth tick.
   - Per-process counters are read only where a coalition used energy.
   - IOReport drops, after warm-up, every driver no chosen channel needs: each
     one costs ~0.65 ms per read.
5. **Reuse.**
   - Dictionaries and arrays are cleared with `keepingCapacity` and swapped,
     never rebuilt.
   - Process paths and names are resolved once per PID.
   - App names are worked out once per coalition.
   - SQLite statements are prepared once.
6. **No UI while hidden.**
   - The popover's SwiftUI hierarchy exists only while it is open.
   - App icons are kept at 32 px and dropped on close.
   - The menu bar title is set only when its text changes.
7. **Batch disk writes.** One transaction every 5 minutes, in WAL with
   `synchronous=NORMAL` (no fsync per commit), and pruning once an hour.

## Reproduce

```sh
make measure          # the built app from outside: ps, top, footprint, its own ranking
make cost             # the sampling layer, stage by stage, projected per minute
xcrun xctrace record --template "Time Profiler" --attach "$(pgrep -nf 'Battery Trace.app/Contents/MacOS')" --time-limit 30s
```
