# Dynamic Island — Backend / Data-Layer Audit

**Date:** 2026-07-24 · **Scope:** the data layer behind all 11 tabs + infra. No product source was
modified. Nothing was committed. This file is the entire deliverable.

---

## 1 · Header — what was audited, and under what conditions

### Build audited

| | |
|---|---|
| **Commit** | `564b6f5` "Servers: run the launcher in-process, drop the daemon" |
| **Tree at audit start (18:49)** | clean — working tree == HEAD |
| **Binary at audit start** | `Dynamic Island.app/Contents/MacOS/Notchbook`, 8,498,848 B, built Jul 24 16:46 |
| **Running process at audit start** | PID 965, started 17:21:34, elapsed 1:28 at first check |
| **Machine** | MacBook Pro `Mac17,2`, Apple M5, 10 cores (4P+6E), 32 GiB, macOS 26 (Darwin 25.5.0) |

**Running-binary check — PASSED.** `ps aux | grep "Dynamic Island"` confirmed PID 965 was executing
the repo's own bundle, and its binary mtime (16:46) post-dated the last source edit (16:44), so the
live process genuinely corresponded to the source being read. This was verified *before* any
observation was trusted.

### ⚠ Audit-integrity events (read this before acting on any line number)

Two things happened mid-audit that you must know about:

**(a) A parallel session rebuilt and relaunched the app at 19:11.** PID 965 disappeared and PID 40568
took its place; the binary grew to 8,756,944 B with mtime 19:11. This was **not** caused by this
audit — every agent transcript was grepped for `kill`/`pkill`/`open -a`/`swift build`/`xcodebuild`
and no agent issued any of them; the only hit was one agent *noticing* the new PID. There is no
Notchbook crash report, and the LaunchAgent (`com.sensubeans.notchbook.plist`) is `RunAtLoad` only
with no `KeepAlive`, so launchd did not respawn it. Attribution: a concurrent Claude terminal on this
shared tree. **Confirm this was you** — if it wasn't, that is itself a finding.

**(b) Five source files changed underneath the audit**, between 19:07 and 19:10:

```
 Sources/Notchbook/AppDelegate.swift    |  50 +++++-
 Sources/Notchbook/NotchPanel.swift     |  13 ++
 Sources/Notchbook/NotchState.swift     |   4 +
 Sources/Notchbook/NotesSyncModel.swift | 306 ++++++++++++++++++++++++++++----
 Sources/Notchbook/TabViews.swift       | 315 +++++++++++++++++++++++++++++----
```

Consequences you must apply when reading this report:

- **All line numbers are against commit `564b6f5`.** Retrieve with `git show HEAD:<path>` if the
  working tree has drifted further.
- **Every Notes finding is provisional.** `NotesSyncModel.swift` nearly doubled (folders, lazy body
  loading, dirty-set tracking, page trimming). Re-verify against the new file before acting — one
  verifier already read the *new* file and found the auditor's line numbers shifted by ~200 lines.
- **Visual-advice line numbers in `TabViews.swift` are the least reliable** (+315 lines landed there).

### Method

Nine parallel area audits (Stats · Media · Agents · Servers · Calendar+Notes+Timer · Tray+Terminal ·
Mirror+Toggles · Infra-lifecycle · Runtime-cost), each required to prefer empirical probes over
code reading, followed by an adversarial verification pass whose explicit instruction was to
*refute* each finding and to downgrade `CONFIRMED` to `SUSPECTED` when no command output backed it.

Probes were standalone `swiftc`/python binaries writing to stdout in the scratchpad — the unified log
was deliberately avoided (macOS 26 stores `NSLog`/`os_log` payloads as `<private>`, and zsh's `log`
builtin shadows `/usr/bin/log`). 127 findings were produced; 47 went through adversarial review and
11 were killed or materially narrowed.

**Verification coverage is uneven — this is a real limitation.** The verify stage ran out of session
tokens partway through:

| Area | Findings verified? |
|---|---|
| Stats, Servers, Calendar/Notes/Timer, Mirror/Toggles, Infra | ✅ verified |
| Media | ◐ partial (4 of 5) |
| **Agents, Tray/Terminal, Runtime-cost** | ❌ **not verified** — treat their `CONFIRMED` tags as author-asserted |

The cross-cutting synthesis agent also died on the token limit; §5's pattern classes are mine, drawn
from the finding set directly.

### Effect on the app

The app was never killed, restarted or rebuilt by this audit. Read-only observation only
(`ps`, `sample`, `lsof`, `otool`, `strings`, `ioreg`, `curl` on GET endpoints). Agent probes did
spawn short-lived scratch processes (three left `.ips` diagnostic files at 18:55–19:04 — `probe`,
`parsecost`, `tid`; those are agent probes crashing, not the app).

---

## 2 · Finding #1 — the SMC fan bug (verbatim, plus what verification added)

**The Stats fan tile has NEVER worked. Root cause proven empirically.** · `CRITICAL` · `CONFIRMED`

- Symptom (user report): fan is audibly active; Stats page shows no sign of it (tile renders "—").
- `Sources/Notchbook/StatsModel.swift` — the embedded `SMC` client's `KeyData` struct is **76 bytes
  in Swift**, but AppleSMC's `SMCKeyData_t` ABI is **80 bytes**: C pads `KeyInfo` {u32,u32,u8} to 12
  bytes; Swift lays it out as 9, shifting `result/status/data8/data32/bytes` and shrinking the
  struct. `IOConnectCallStructMethod(…, 76, …)` fails with `kIOReturnBadArgument` (0xe00002c2) on
  **every** call, `fanRPM()` returns nil, `fanRPM` stays -1, tile shows "—" forever.
- Proof (standalone probe, this machine, today): with a 3-byte pad added to `KeyInfo` the identical
  call path succeeds — `#KEY`=2778 keys, `FNum=1` fan, **`F0Ac` = 5361.0 RPM (type `flt `)**,
  `F0Tg`=5356, `F0Mn`=2317, `F0Mx`=6550.
- Fix spec: add `var pad: (UInt8, UInt8, UInt8) = (0,0,0)` (or explicit 12-byte layout) to `KeyInfo`
  in `StatsModel.swift` so `MemoryLayout<KeyData>.size == 80`; optionally assert that at init.
  Secondary: the gauge fraction divides by a hardcoded 6000 (`TabViews.swift:1478`) but this
  machine's `F0Mx` is 6550 — read `F0Mx` once and use it as the denominator.

### What this audit added

**1 · Exact layout divergence measured — the offsets shift too, so bumping the size constant alone is
not enough.**

```
--- app structs (StatsModel.swift:154-175) ---   --- C-ABI correct (KeyInfo padded to 12) ---
KeyInfo   size=9   stride=12  align=4            KeyInfoC   size=12  stride=12  align=4
KeyData   size=76  stride=76  align=4            KeyDataC   size=80  stride=80  align=4
  offset keyInfo = 28                              offset keyInfo = 28
  offset result  = 37                              offset result  = 40
  offset data32  = 40                              offset data32  = 44
  offset bytes   = 44                              offset bytes   = 48

--- live: 76-byte (app) call ---   inSize=76  kr=0xe00002c2  (kIOReturnBadArgument)
--- live: 80-byte (C ABI) call --- inSize=80  kr=0x0  result=0  dataSize=4  dataType=666c7420
    F0Ac = 2499.0 RPM   F0Mn = 2317.0   F0Mx = 6550.0   F0Tg = 2500.0
```

**2 · The bug is in the binary you are actually looking at**, not merely in the source tree.
Disassembly of the shipped `Notchbook` (PID 965's image):

```
_$s9Notchbook3SMCC4call...
  1000f077c  mov  w8, #0x4c      ; outputStructCnt = 76
  1000f07ac  mov  w3, #0x4c      ; inputStructCnt  = 76
  1000f07b0  bl   _IOConnectCallStructMethod
  1000f07b4  cbz  w0, ...        ; kr != 0 -> returns nil
```

**3 · Blast radius: this is the ONLY hand-rolled C struct in the package.** All 38 files under
`Sources/Notchbook/` were swept for `IOConnectCallStructMethod`, `IOConnectCallMethod`,
`IORegistryEntry*`, `sysctl`, `host_statistics*`, `mach_*`, `statfs`, `getifaddrs`, `proc_pidinfo`,
`task_info`, `withMemoryRebound`, `unsafeBitCast`, `bindMemory`, `.load(as:)`:

| Verdict | Site | Note |
|---|---|---|
| **HAZARD** | `StatsModel.swift:154-158, 160-175, 226-229` | the SMC pair — the only one |
| SAFE | `StatsModel.swift:65-72` | `host_cpu_load_info_data_t` — Clang-imported, size 16, returns `KERN_SUCCESS` |
| SAFE | `StatsModel.swift:88-95` | `vm_statistics64_data_t` — Clang-imported, size 248, returns `KERN_SUCCESS` |
| SAFE | `StatsModel.swift:110-131, 178-183, 133-145` | CF dictionaries / scalars only, no struct-by-value |
| SAFE | `TerminalIdentity.swift:94-95` | `kinfo_proc` Clang-imported; live `sysctl KERN_PROC_PID 965` → r=0, sizeOut=648 |
| SAFE | `AudioOutputModel.swift:112, 245, 259, 289, 300` | `AudioObjectPropertyAddress` Clang-imported (size 12) |
| SAFE | `LocalStarter.swift:167, 174, 183` | `sockaddr_in` (16), `pollfd` (8), `socklen_t` — all imported |
| SAFE | `AudioSpectrum.swift:146, 150` | pointer arithmetic on imported `AudioBufferList` |
| SAFE | `TouchSensor.swift:22-39`, `TogglesModel.swift:11-24, 63-69` | `@convention(c)` with opaque pointers + scalars |

**The rule that holds across the package:** every C struct crossing the boundary is a Clang-imported
type whose layout comes from the header — except the SMC pair. One fix closes the entire class.

**4 · The rest of StatsModel, checked against shell ground truth:**

| Tile | Verdict | Evidence |
|---|---|---|
| **GPU** | ✅ **correct and alive — the "dead on M5" hypothesis is REFUTED** | `ioreg -r -c IOAccelerator -d 1` → `"Device Utilization %"=24`; exactly 1 node; replicated `pollGPU()` read 15, then 36 two seconds later |
| CPU | ✅ correct, per-core normalized in steady state | probe 30.3% vs `top -l 2 -n 0` 18.62 user + 15.38 sys = 34.0% busy, same moment |
| Battery | ✅ correct | tile 15% vs `pmset -g batt` 16% |
| memTotal | ✅ exact | matches `hw.memsize` 34359738368 |
| **Disk** | ❌ **wrong units** | tile "689 GB free"; `diskutil` says 728.8 GB; the model's own raw value is 739.9 GB. GiB math, decimal label |
| Memory | ◐ 1.00 GiB over Activity Monitor | `active+wire+compressor` counts file-backed cache and omits inactive anonymous |
| **Fan** | ❌ dead, as above | fan is spinning at 2499 RPM; the app knows nothing |

---

## 3 · Findings ranked by severity

Each finding is tagged `CONFIRMED` (reproduced/measured, output quoted) or `SUSPECTED` (code
reasoning). Where adversarial verification changed a claim, that is stated inline.

### CRITICAL

---

**C1 · Notes sync deadlocks permanently once the folder holds >64 KiB of text** · Notes ·
`NotesSyncModel.swift:291` (HEAD) · `CONFIRMED`

`run()` calls `p.waitUntilExit()` and only *then* reads the pipes. `pull()` makes osascript emit the
full plaintext of every note, so stdout scales with total note size. Probe copying `run()` verbatim:

```
./pipe 30000  -> returned 0.07s, ok=true, outLen=30001
./pipe 65000  -> returned 0.07s, ok=true, outLen=65001
./pipe 70000  ->   HUNG
./pipe 150000 ->   STILL HUNG after 90s (permanent)
pipe buffer capacity = 65536 bytes      # threshold matches exactly
```

**Impact:** `scriptQueue` is serial. Once one `pull()` wedges, `syncing` stays true forever (status
frozen at "syncing…") and every subsequent pull *and* every debounced push queues behind it and never
runs. From that moment every edit is silently never written to Apple Notes — no error, cloud icon
still lit. ~65 KB (about 20 pages of prose) is enough. Orphaned `osascript` also leaks.

**Fix:** drain both pipes on background work items joined by a `DispatchGroup`, and only then
`waitUntilExit()`. Add a 15 s timeout calling `p.terminate()` + a toast. Cap per-note plaintext in the
AppleScript (`text 1 thru 2000 of (plaintext of n)`).

⚠ **Re-verify first** — `NotesSyncModel.swift` was rewritten at 19:07.

---

**C2 · Lyrics silently die on every track change — the duration re-fetch cancels the in-flight search,
which self-reports as a network failure and wipes the key** · Media · `LyricsModel.swift:44-53` ·
`CONFIRMED`

The unmodified product file was compiled and driven through the exact MediaTab sequence
(`onChange(np.title)` → `fetch(duration:0)`; `onChange(media.duration)` → `fetch(duration:real)`):

```
CONTROL (one fetch, duration known)       -> status=loaded  lines=51
  [t=0.30s] second fetch issued (cancels search #1); status=loading
  [t=1.0s]  status=unavailable   <-- UI renders "No lyrics for this song"
  [t=9.0s]  status=unavailable
REPRO   (title-fetch then duration-fetch) -> status=unavailable lines=0
```

Mechanism: `fetch()` sets `fetchedKey=K` then `task?.cancel()`. The cancelled task delivers
`error != nil`, so the handler reports `.network`. That arm guards on `fetchedKey == key` — still K,
same track — so it sets `fetchedKey=""` and `status=.unavailable`. The second search then completes
and `deliver()` fails *its* guard and is discarded forever.

**Impact:** with the lyrics pane open, every track change lands on "No lyrics for this song" even for
songs with 51 synced lines on lrclib. Appears to work the first time only.

**Fix:** (1) treat `NSURLErrorCancelled` as a non-event — never call completion for it. (2) Gate both
the `.network` arm and `deliver()` on a monotonic generation counter rather than on `fetchedKey`.
(3) Split `.unavailable` into `.noLyrics` and `.failed(String)`.

---

**C3 · Lock Screen button is a permanent silent no-op — `CGSession` no longer exists on macOS 26** ·
Controls · `TogglesModel.swift:190` · `CONFIRMED`

```
$ ls "/System/Library/CoreServices/Menu Extras/User.menu/.../CGSession"
ls: No such file or directory          # there is no User.menu at all on macOS 26
$ find /System/Library/CoreServices -maxdepth 6 -name CGSession   -> (nothing)

probe replicating TogglesModel.shell():
  run THREW: NSCocoaErrorDomain Code=4 "The file "CGSession" doesn't exist."
  <-- swallowed by `try?` at TogglesModel.swift:211

$ strings -a ".../Notchbook" | grep CGSession    # dead path is in the running binary
/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession
```

**Impact:** clicking "Lock Screen" does nothing, forever, with no error. The card looks identical to
the working cards beside it. This is the fan-tile archetype with a swallowed error behind it.

**Fix:** `dlopen`/`dlsym` `SACLockScreenImmediate()` from `login.framework` (the same runtime-resolution
pattern this file already uses for DisplayServices/CoreBrightness); fall back to a Cmd-Ctrl-Q
`CGEvent`. Make `shell()` `@discardableResult -> Bool` and publish a `lastActionFailed` the tab renders.

---

**C4 · The closed notch burns ~17% of a CPU core continuously — and macOS has been reporting it as a
CPU runaway for a week** · process-wide · `CONFIRMED` (measurement) / `SUSPECTED` (mechanism)

Measured three independent ways, notch closed:

```
delta-CPU, 12 x 5s windows (19:08:20-19:09:20):  mean 17.5%  median 17.3  min 16.3  max 19.7
second run (19:04:57-19:06:26, ps TIME 5:46.79 -> 6:02.24 = +15.45s / 89.0s wall) = 17.4%
sample 965 10 (8354 samples), main thread:
  6951 (83.2%) idle in mach_msg2_trap
  1103 (13.2%) __CFRunLoopDoSource1 -> CA::Transaction::commit -> NSDisplayCycleFlush (995)
               -> -[NSWindow layoutIfNeeded] (942) -> NSHostingView.layout() (891)
               -> ViewGraphRootValueUpdater.render(...) (877)
```

And the OS has been saying so independently since Jul 17 — **seven** root-owned resource reports:

```
$ grep -E '^CPU: ' /Library/Logs/DiagnosticReports/Notchbook_*.cpu_resource.diag
2026-07-17 20:05  90 seconds cpu time over 160 seconds (56% cpu average), exceeding limit of 50%/180s
2026-07-17 22:09  90s over 168s (53%)     2026-07-18 14:41  90s over 180s (50%)
2026-07-18 19:17  90s over 179s (50%)     2026-07-23 12:56  90s over 176s (51%)
2026-07-24 08:36  90s over 175s (51%)     2026-07-24 11:38  90s over ...
```

The work is a **full-tree relayout**, not the price of one dot — 10+ levels of `DisplayList`
recursion with `LayoutEngineBox.explicitAlignment` and `AG::LayoutDescriptor::Compare` at the leaves.

**Mechanism — attribution is NOT established.** The auditor blamed the collapsed agent pill's
`.repeatForever` opacity pulse (`NotchView.swift:1059`, the only infinite animation mounted on a
collapsed adornment). The adversarial verifier accepted the measurement and the code reading but
**refused the causal claim** as unproven: no experiment isolated the animator. Treat the 17% as fact
and the pill as the leading hypothesis, not the diagnosis.

**Corroborating evidence from this session's own timeline** (cumulative-CPU deltas, notch closed,
while an 8-agent fleet ran and then wound down):

```
18:55-19:01  23-35%   (8-10 Claude sessions writing transcripts)
19:01-19:10  13-18%   (fleet winding down)
19:10-19:11   3.6-5.0% (quiet)      RSS flat 159-161 MB throughout
```

A ~7× swing tracking Claude session write volume points at the **Agents** subsystem (transcript
tailing + the per-session pill) rather than at a constant animator alone — both may contribute.

**Fix:** first *isolate* — run with no Claude session in a working state (see U1) and re-measure.
Then, in order: (a) render the pulse in a `Canvas`/`.drawingGroup()` leaf, or drive it from a coarse
0.75 s timer the notch owns, so it cannot invalidate ancestors; (b) don't build the nav width probe
(`NotchView.swift:1386`) or the measuring tab bar (`:1562-1563`) when collapsed; (c) make
`NotchState.visibleTabs` (`NotchState.swift:201`) a stored value instead of a computed property —
it is re-evaluated several times per frame; (d) add a self-watchdog that samples the app's own
`proc_pid_rusage` and surfaces "idle CPU 51%" rather than leaving it to a root-owned `.diag` file.

---

### HIGH

---

**H1 · An orphaned launcher child survives the app's death, keeps its port, and the new instance is
blind to it** · Servers · `LocalStarter.swift` · `CONFIRMED` **(observed live during this audit)**

The 19:11 restart was an unplanned natural experiment and it answered the "does the tab detect a
server that died out-of-band / re-attach on relaunch?" question outright:

```
$ ps -o pid,ppid,lstart -p 1099
 1099     1  Fri Jul 24 17:21:59 2026      # PPID reparented to launchd
$ curl -s -o /dev/null -w "HTTP %{http_code}\n" http://localhost:8123/foglamp.html
HTTP 200                                   # still serving, 2h later
$ pgrep -P 40568 | wc -l
       0                                   # new instance has NO children
$ lsof -iTCP:7780 -sTCP:LISTEN             # launcher port
(nothing)
```

**Impact:** quit or crash the app and every server it launched keeps running forever, reparented to
launchd, holding its port, invisible to any UI. The relaunched app cannot see or control it, and the
next ▶ on that project hits a port that is already bound — which, per H3, fails silently.

**Fix:** record the child pid (`start()` already writes `pidsDir/NAME.pid` — currently write-only
garbage, see M14) and on launch reconcile: for each registered project whose port is live, check
whether the listener pid matches the recorded pid and re-adopt the row as running-and-ours. On quit,
either `killpg` the launcher's children or persist an explicit "left running" list the next launch
surfaces.

---

**H2 · `portLive()` is IPv4-only — any dev server bound to `::1` reads as permanently down** ·
Servers · `LocalStarter.swift:170` · `CONFIRMED`

```
$ node -e "http.createServer(...).listen(8998,'localhost')"
node listening {"address":"::1","family":"IPv6","port":8998}
$ ./probe port 8998            # verbatim copy of LocalStarter.portLive
portLive(8998) = false
$ nc -z ::1 8998 -> succeeded  ;  nc -z 127.0.0.1 8998 -> refused
control: portLive(8123) = true (the app's own IPv4 child)
```

Node's `listen(port,'localhost')` — the most common dev-server bind on macOS — resolves `::1` first
and binds IPv6-only. **Impact:** a server that is genuinely running and reachable in the browser
shows a gray dot and offers ▶; pressing it launches a second instance that cannot bind and dies
silently. Bites vite and most node servers.

**Fix:** dual-stack probe — retry the identical non-blocking connect against `AF_INET6` /
`in6addr_loopback`, or drive it from `getaddrinfo("localhost", port, AI_ADDRCONFIG)`. Keep 300 ms as
a *total* budget across families.

---

**H3 · A failed launch is completely invisible — `shell()` returns 0 for a nonexistent command,
`start()` discards it, and `readLog` has no caller** · Servers · `LocalStarter.swift:255` ·
`CONFIRMED`

```
$ /bin/zsh -lc "cd '.../proj' && PORT=9999 nohup totally-bogus-dev-server >> log 2>&1 & echo $! > pid"
$? = 0                                  # backgrounded with &, so zsh always exits 0
log: nohup: totally-bogus-dev-server: No such file or directory   # never surfaced

# stale path: the `cd` failure doesn't even reach the log
$ ... cd '.../gone' && ...
zsh:cd:1: no such file or directory     # goes to stderr -> FileHandle.nullDevice (:329-330)
shell() rc = 0    log: []    pid file: 0

$ grep -rn "readLog\|logsDir" Sources/ | grep -v LocalStarter.swift
(no output)                             # the one diagnostic that exists is dead code
```

**Impact:** tap ▶, nothing happens, forever — no spinner, no error, no log view. Covers every real
failure mode (npm/python not on the login PATH, missing `node_modules`, syntax error in `server.py`,
renamed folder). Only recourse is reading `~/.local-starter/logs/NAME.log` by hand.

**Fix:** poll `portLive(port)` for ~8×500 ms after launch; on failure set a `ServersModel.lastError`
from the last non-empty line of the already-written `readLog`, and render it inline. Redirect the
outer shell's stderr into the log instead of `nullDevice`.

---

**H4 · An unrelated process holding the port makes a stopped project render as running — and ■
SIGTERMs that stranger** · Servers · `LocalStarter.swift:141` · `CONFIRMED`

`running:` is a bare `portLive(port)` — no pid check, no ownership check. Squatting on
Marginal-Economics' port 8080 with a socket that serves nothing:

```
NAME                  KIND      PORT   run     (with squatter)      without squatter
foglamp               static    :8123  UP                           UP
Marginal-Economics    static    :8080  UP   <-- green, tap-to-open   down
runningCount = 2                                                    runningCount = 1
```

`LocalStarter.swift:267` then does `lsof -ti tcp:8080 -sTCP:LISTEN | xargs kill` — ■ SIGTERMs the
stranger. The code calls this "the wart" at `:263-264`; the UI never does.

**Impact:** green means "something answers on this number", not "your project is up". Pressing ■ can
silently kill another agent's server, a database, or a tunnel.

**Fix:** compare `lsof -ti tcp:PORT` against the recorded pid; render a third amber state for
live-but-not-ours; refuse to kill a listener whose argv doesn't match the project.

---

**H5 · Toggles never re-reads system state — volume and desktop-icon state are read once at launch and
are wrong for the rest of the session** · Controls · `TogglesModel.swift:90` · `CONFIRMED`

`init` is the *only* writer. Exhaustive call-site search finds no timer, no `onAppear`, no
tab-change hook. The asymmetry proves it's an oversight: the two brightness sliders *do* get live
`read:` closures (`TabViews.swift:1615, 1627`); volume and desktop-icons bind to the stale
`@Published` seeded at launch, and there is no Toggles entry in the gating block at all.

**Impact:** the slider is interactive — dragging it from a wrong displayed position jumps system
volume to an unintended level. The desktop-icons switch can be inverted relative to reality, so
tapping it appears to do nothing.

**Fix:** add `toggles.refreshAll()` to both lifecycle blocks (`NotchView.swift:766`, `:793`); for
live tracking add a gated `setPolling(_:)` mirroring `StatsModel.swift:42-53`, or a CoreAudio
property listener for volume.

*(Verification narrowed the desktop-icons half to LOW severity on its own; the volume half carries
the rating.)*

---

**H6 · Brightness sliders show a value captured once at first tab mount — collapse→expand never
re-reads** · Controls · `TabViews.swift:1677` · `CONFIRMED`

The expanded panel is **always mounted** (`NotchView.swift:1332` has no `if state.isExpanded` guard;
collapse is expressed purely as opacity/frame), so `onAppear` cannot re-fire on expand. Probe
reproducing the exact structure offscreen:

```
initial (collapsed):                appears=1
after EXPAND #1 (live=0.10):        appears=1
after collapse+EXPAND #3 (live=0.50): appears=1
after TAB SWITCH away+back (live=0.70): appears=2
reads: ["onAppear#1 -> 0.0", "onAppear#2 -> 0.7"]
```

**Impact:** change brightness with F1/F2 while closed, reopen on Controls — the bar shows the old
position, and the next drag yanks brightness to wherever the stale bar says you touched.

**Fix:** `.onChange(of: state.isExpanded)` re-read, or move the levels into `TogglesModel` behind a
`setPolling(_:)` gate with an immediate refresh on the true edge.

---

**H7 · Disk tile prints GiB but labels it GB — reports ~40-51 GB less free space than Finder** ·
Stats · `TabViews.swift:1492-1494` (used at `:1469`) · `CONFIRMED`

```
tile:                     "689 GB free"
model's own raw value:     739900834102 = 739.9 GB / 689.09 GiB
$ df -H /                  Avail 729G
$ diskutil info /          Container Free Space: 728.8 GB
```

macOS reports storage in decimal GB everywhere (Finder, About This Mac, `df -H`, `diskutil`); the
tile silently uses binary GiB with a decimal label. The percentage is fine (25.6% → "26%"), and there
is **no** APFS double-count — both keys are container-scoped and mutually consistent.

**Fix:** split the formatter — keep `/2^30` for Memory (RAM is conventionally binary), give Disk a
decimal divisor or `ByteCountFormatter` with `.countStyle = .file`. Target: the tile reads
"740 GB free".

---

**H8 · CPU tile's first value after re-expand is the average over the whole time the notch was closed,
presented as instantaneous** · Stats · `StatsModel.swift:32, 42-53, 78-84` · `CONFIRMED`

`setPolling(false)` invalidates the timer but leaves `prevTicks` populated; `setPolling(true)` calls
`poll()` immediately, so `pollCPU()` diffs current ticks against a snapshot from whenever the notch
was last closed.

```
T0  first-ever expand (prevTicks==nil):  tile shows 0%
T2  steady:                              24%
--- closed 14s (8s of full load, then 6s idle; machine idle NOW) ---
--- re-expand:                           tile shows 52%   <-- a 14s average as "now"
2s later, truth:                         14%
```

**Impact:** after an overnight close, the first number is an 8-hour average. It self-corrects in
1-5 s, which is worse — the user sees a number, sees it jump, and learns not to trust the tile.

**Fix:** `prevTicks = nil` in the stop branch; take a real 200 ms baseline off-main for the first
post-expand value, or mark the tile "warming" for one interval.

---

**H9 · Album-art dominant-colour extraction runs synchronously on the main thread on every track
change** · Media · `MediaWatcher.swift:38-42 → :580-610` · `CONFIRMED`

Every assignment to `artwork` happens on main, so `dominantColor()` always runs there — a full
`tiffRepresentation` plus 576 `colorAt` + `usingColorSpace` calls:

```
art  300x300    1.6 ms      art 1000x1000    6.0 ms
art  600x600    3.1 ms      art 1400x1400   10.6 ms   <- Apple Music's actual size
                            art 3000x3000   60.9 ms   <- Digital Masters
```

Frame budget on this ProMotion panel is 8.3 ms. **Impact:** 1-8 dropped frames at exactly the moment
the ear/pill liquid choreography animates — the very hitch the Spotify comment at `:460-467` was
written to avoid, reintroduced one layer up.

**Fix:** compute on a utility queue and hop back with a generation token; and cut ~10× by drawing
once into a 32×32 `CGContext` and reading the raw buffer instead of 576 `colorAt` calls.

---

**H10 · `expand()` blocks the main thread on synchronous `NSAppleScript` round trips before the panel
orders front** · Media · `AppDelegate.swift:954 → MediaWatcher.swift:414-434` · `CONFIRMED`

```
NSAppleScript run 0: 99.2 ms   (cold — first expand after launch)
runs 1-4:            13.6 / 10.7 / 9.5 / 8.8 ms
```

Per player, and Spotify is installed here, so with both running the cost doubles. The file's own
comments forbid exactly this (`:88-92`). **Impact:** every hover-expand pays a 10-100 ms main-thread
stall at frame zero of the open animation. Worse, `NSAppleScript` has no timeout override — a busy
Music (library sync, sign-in prompt) can freeze the notch for up to two minutes.

**Fix:** route through the existing `runScriptAsync`; don't let `orderFront` wait on it.

---

**H11 · YouTube detection spawns an `osascript` against Chrome every ~3 s forever — closed or not** ·
Media · `MediaWatcher.swift:141-147` · `CONFIRMED`

Started unconditionally in `init()`; the only off-switch is the user setting. No expanded/currentTab
gating — the gating block covers only media-progress, stats and servers.

```
$ ps polling at 4Hz for 30s:  8 distinct osascript children of PID 965
   ~1 spawn / 3.75s  =  ~960 process spawns/hour, notch CLOSED
$ /usr/bin/time -p osascript ytpoll.applescript   -> real 0.09-0.12s each
sample: 528/8354 (6.3%) on DispatchQueue com.sensubeans.notchbook.applescript
```

The script enumerates **every tab of every window**, so cost scales with tab count (this machine has
4 tabs; a 60-tab user pays ~15×). **Impact:** ~29k spawns/day and an Apple Event into Chrome every
3 s that wakes Chrome's main thread — battery cost the user will attribute to Chrome.

**Fix:** gate on visibility like Stats/Servers; short-circuit on
`NSRunningApplication...(withBundleIdentifier:"com.google.Chrome").isEmpty` before spawning; drop to
30 s when cold; replace fork/exec-per-tick with one compiled `NSAppleScript`.

---

**H12 · `AudioSpectrum` failure is indistinguishable from success — a denied tap falls back to a
synthetic sine that looks exactly like a live waveform** · Media · `AudioSpectrum.swift:52-93` ·
`SUSPECTED`

`start()` has four silent early-returns (`#available`, `AudioHardwareCreateProcessTap`,
`AudioHardwareCreateAggregateDevice`, IOProc create/start). None records anything; `levels` stays
`[]`. Both render sites then substitute a fake — `EqualizerBars.targetHeight` falls through to
`sin(t*speed + phase)` when `levels` is nil, and the collapsed ear is created with `animating: true`.

**Impact:** the fan-tile archetype in its most deceptive form — instead of "—", the feature shows a
*beautiful lie*. Bars bounce convincingly forever, so the bug is never reported. Note the app is
ad-hoc signed (M20), so the TCC grant is lost on every rebuild.

**Fix:** add `@Published private(set) var failure: String?` set from each early-return with its
specific cause; render an affordance under the waveform; in the collapsed ear render a *static* glyph
when `failure != nil` so the ear never lies.

---

**H13 · Mirror is permanently dead after one denial — no retry path exists** · Mirror ·
`MirrorController.swift:120` · `SUSPECTED`

`denied`/`unavailable` are set at `:120`/`:143` and cleared *only* inside the `granted` branch of
`start()`. `start()` is reachable from three call sites, of which the "Show Mirror" button
(`TabViews.swift:1415`) is the only user-facing one — and `TabViews.swift:1387` renders the error
VStack *instead of* the branch holding that button. `stop()` doesn't clear the flags, and the
controller is a single app-lifetime instance.

**Net: once `denied == true`, the only thing that can call `start()` is no longer rendered.**

**Impact:** deny the camera prompt once and the tab shows a static error with no button for the rest
of the app's life. Granting in System Settings changes nothing — only a relaunch, with no hint that a
relaunch is what's needed.

**Fix:** add "Try Again" + "Open Privacy Settings" buttons to the error branch, and recompute both
flags from live `AVCaptureDevice.authorizationStatus` / `DiscoverySession` on appear rather than
latching them. Distinguish `.restricted` (MDM) from `.denied`.

---

**H14 · Camera session keeps running through screen lock and display sleep, and indefinitely while
pinned** · Mirror · `AppDelegate.swift:1129` · `SUSPECTED`

No sleep/lock observer exists anywhere in the target (grep for `willSleep`, `didWake`,
`screensDidSleep`, `com.apple.screenIsLocked` → nothing; the only observers are
`activeSpaceDidChange` and `didActivateApplication`). The camera is stopped only by `collapse()`,
which is driven exclusively by mouse-moved monitors — and a **pinned** panel never collapses at all,
while a locked/asleep display delivers no mouse-moved events to a background app.

**Impact:** lock the screen with the mirror running and the green camera indicator stays lit behind
the lock screen — battery drain plus a "this Mac is watching" signal while you're away. The ordinary
closed-notch case *is* handled, so this is a gap at the edges, not the default.

**Fix:** observe `willSleepNotification` / `screensDidSleepNotification` / `com.apple.screenIsLocked`
→ `mirror.stop()`; mirror them on wake/unlock guarded by a latched intent. Add an idle cap for the
pinned case.

---

**H15 · Calendar denied/restricted looks identical to never-asked, and "Allow Access" is a permanent
no-op** · Calendar · `TabViews.swift:1052` · `CONFIRMED`

The tab branches on one boolean: `if !calendarModel.hasAccess { connectPrompt }`, and `hasAccess` is
`status == .fullAccess`. So `notDetermined`, `denied`, `restricted` and `writeOnly` all collapse to
the same screen. `connect()` discards the error (`{ granted, _ in }`); once TCC has recorded a
denial, `requestFullAccessToEvents` returns `granted=false` immediately with no system UI.

```
$ ./ek
enum cases present on this SDK: fullAccess=3 writeOnly=4 denied=2 restricted=1 notDetermined=0
```

(`Info.plist` is correct — both usage-description keys are present, so there is no crash risk; the
failure is purely a UI one.)

**Impact:** a user who once clicked "Don't Allow" sees a button that does nothing, forever, with no
explanation and no "open System Settings" path anywhere in the tab or its settings page.

**Fix:** switch on `status`, not a boolean; give `.denied`/`.restricted` an
`x-apple.systempreferences:...?Privacy_Calendars` button; handle `.writeOnly` explicitly.

---

**H16 · Calendar never refreshes on expand — only on tab switch** · Calendar · `NotchView.swift:766` ·
`CONFIRMED`

Tab bodies are always mounted, so `CalendarTab.onAppear` fires only when the tab *becomes current*.
The expand path deliberately refreshes media and notes and skips calendar; the only load-on-navigation
is inside `onChange(of: state.currentTab)`. `load()` also snapshots `let start = Date()` at call
time, freezing the 7-day window at the last tab switch.

**Impact:** leave the notch parked on Calendar (natural, since tab order is persisted) and hours later
you see the list as of the last tab switch — including meetings that already ended, missing anything
added on your iPhone that didn't fire a local `EKEventStoreChanged`.

**Fix:** add the calendar to the expand hook; add a coalesced 60 s timer while the tab is expanded.

---

**H17 · An edit typed within 2 s of quit never reaches Apple Notes** · Notes ·
`NotesSyncModel.swift:154` (HEAD) · `CONFIRMED` — **materially narrowed by verification**

`edit()` schedules the push 2 s out on the main queue; `applicationWillTerminate` never touches
`notesSync`, so the pending `DispatchWorkItem` dies with the run loop.

⚠ **The auditor's stronger claim — that the next launch's `pull()` then overwrites the cache and
*destroys* the edit — was refuted.** The verifier read the (rewritten) file and found both the line
numbers and that causal chain wrong. What survives: **the edit never reaches Apple Notes, and the app
never retries or says so.** Not silent destruction in the common case.

**Fix:** add `flushPendingPushes()` (cancel each work item, run it synchronously with a bounded wait)
and call it from `applicationWillTerminate` alongside `state.saveNow()`.

---

**H18 · Pushing to Apple Notes destroys all indentation and repeated whitespace on round-trip** ·
Notes · `NotesSyncModel.swift:265` · `CONFIRMED`

`htmlBody()` wraps each line in a bare `<div>` with no `white-space:pre` and no `&nbsp;`, so HTML
whitespace collapsing applies, and `plaintext of n` is read back from that rendered HTML:

```
original:    "    let x = 1      // four-space indent + run of spaces"
round-trip:  "let x = 1 // four-space indent + run of spaces"
ORIGINAL == ROUND-TRIP ?  false      (94 bytes -> 85 bytes)
```

The app ships a `notes.monospaced` setting — it *invites* pasting code into this editor.

**Impact:** paste indented code, YAML, or an ASCII table; two seconds later it's pushed as collapsing
HTML, and the next pull (every notch expand) replaces the editor text with the flattened version.
No warning, no undo.

**Fix:** emit `<div style="white-space:pre-wrap">` and/or convert leading runs to `&nbsp;`. Verify
with the same round-trip probe before shipping.

---

**H19 · Tray keeps deleted/moved/unmounted files as normal-looking tiles forever — `isAvailable` is
dead code** · Tray · `FilesTray.swift:33` · `CONFIRMED` *(unverified area)*

The doc comment at `:22-26` claims "The UI marks unreachable items instead (see `isAvailable`)". It
does not — the function's only reference in the whole tree is its own declaration.

```
2. MISSING-FILE RENDERING (TrayTile fallback = NSWorkspace.icon(forFile:))
   icon while present : size=(32,32) reps=32
   icon after delete  : size=(32,32) reps=32
   -> a deleted file still yields a normal-looking icon: true
```

Nothing revalidates on expand either — the lifecycle hooks have branches for media/stats/servers/
calendar/mirror and none for `.tray`.

**Impact:** a moved, renamed, deleted, or ejected file keeps a full-colour icon and its old filename
indefinitely. Double-click, Reveal in Finder, drag-out and AirDrop all silently do nothing. Over
weeks the shelf fills with confident-looking ghosts.

**Fix:** re-check availability on appear and on the expand/tab edges; desaturate + badge + strike the
filename, and disable everything but Remove in the context menu.

---

**H20 · QuickLook hands back the exact reason it failed and `TrayThumbnails` throws it away** · Tray ·
`TrayThumbnails.swift:49` · `CONFIRMED` *(unverified area)*

```
generateBestRepresentation(for: request) { [weak self] rep, _ in     // <- the error, discarded
3. QUICKLOOK ON DELETED FILE
   rep=nil err=NSCocoaErrorDomain Code=4 "The file "gone.png" doesn't exist."
```

The caller turns `nil` into the generic-icon branch, which is pixel-identical to (a) still loading,
(b) no preview generator for this type, (c) file gone, (d) volume ejected.

**Fix:** widen the completion to carry the error (or a `ThumbState` enum), classify it
(Cocoa 4/260 → missing, 257 → denied, else → noPreview), and render three distinct states.

---

**H21 · `shutdown()` SIGKILLs the shell before it can HUP its jobs — every background process leaks on
quit** · Terminal · `TerminalSessionsModel.swift:98-105` · `CONFIRMED` *(unverified area)*

SIGKILL cannot be caught, so zsh never reaches its exit path. Reproduced against a real `pty.fork` +
`/bin/zsh -l` with `sleep 400 &` as the job, sending exactly the app's signal sequence:

```
A. shutdown():   SIGHUP; SIGKILL back-to-back   -> child alive=True (state=SN, ppid=1)  *** ORPHANED
B. closeSession(): SIGHUP; terminate()->SIGTERM -> child GONE
C. control:      SIGHUP alone                   -> child GONE
```

`closeSession` does it correctly; only the quit path has the extra SIGKILL.

**Impact:** quitting leaves every background job from every built-in session running forever,
reparented to launchd, invisible. An `npm run dev` or a training run keeps holding its port after the
app is gone, with no process the user can attribute it to.

**Fix:** send only SIGHUP (matching `closeSession`). If a hard backstop is wanted, SIGHUP all, sleep
150 ms, then SIGKILL only pids still alive per `kill(pid,0)`. Better: `killpg(getpgid(pid), SIGHUP)`.

---

**H22 · Hardcoded model catalog has gone stale — every Opus 5 session shows a raw id and LOSES its
context meter** · Agents · `AgentSessionsModel.swift:1922` · `CONFIRMED` *(unverified area)*

```
$ ./modelcat   (verbatim copy, run over the ids actually on disk)
  OK    claude-fable-5        -> badge="Fable"      contextWindow=1000000
  OK    claude-opus-4-8       -> badge="Opus 4.8"   contextWindow=200000
  OK    claude-opus-4-8[1m]   -> badge="Opus 4.8"   contextWindow=1000000
  FAIL  claude-opus-5[1m]     -> badge="claude-opus-5[1m]"  contextWindow=nil
```

Live right now, not hypothetical — 2 of 4 running sessions use it. Downstream, `contextWindow == nil`
makes `contextFraction` nil, which makes `contextMeter` render **nothing** (the `if let f` has no
`else`).

**Impact:** the raw string `claude-opus-5[1m]` renders in an 8.5 pt capsule, squeezing the
project/branch line, and the thin context bar — the tab's signature at-a-glance signal — is silently
absent. Every future model rename re-breaks it identically.

**Fix:** plumb the spool's `display` string and `context_window_size` (the statusline already writes
them) through `makeSession`; treat a `[1m]` suffix as 1,000,000 regardless of catalog membership;
derive a human name from an unknown id instead of returning it raw.

---

**H23 · Subagent transcripts never advance the parent's activity clock — a session doing pure subagent
work eventually renders "Idle" while genuinely busy** · Agents · `AgentSessionsModel.swift:1566` ·
`CONFIRMED` *(unverified area)*

Claude Code 2.1.219+ writes subagent turns to *separate* files under
`…/<parentSessionId>/subagents/workflows/wf_*/agent-*.jsonl`, each entry carrying the parent's
sessionId with `isSidechain=true`:

```
scan of agent-a2b94cd5….jsonl:  55 lines, sessionId all = 6074f5bc…, isSidechain: {True: 55}
scan of the PARENT transcript:  isSidechain entries INSIDE parent = 0
```

So the "sidechain INCLUDED (a subagent burst means the parent is still working)" keep-alive at
`:1557-1562` is **dead** for this version. Those entries land in their own `FileParser`, where
`guard !isSidechain else { return }` returns *before* `p.messageCount += 1` — so that parser's
`messageCount` stays 0 forever, and both consumers filter on `messageCount > 0`.

**Impact:** during any subagent workflow the row freezes — `lastActivity`, `contextTokens`,
`outputTokens`, `messageCount` all stop while "Working 2m, 3m, 4m…" counts against a stopped clock.
Past 30 minutes of subagent-only work — *routine for this user's multi-agent workflows* — the row
flips to `.idle`, dims, and sorts to the bottom while the process is at 16% CPU. **This audit's own
workflow is exactly that workload.**

**Fix:** give `FileParser` a `sidechainEntryCount`/`newestSidechainTs` the guard does *not* skip;
index sidechain-only parsers by sessionId into a second map; take
`lastActivity = max(parent, sidechain)`.

---

**H24 · Missing/unreadable `~/.claude/sessions` renders a confident "No Claude Code sessions
running"** · Agents · `AgentSessionsModel.swift:1386` · `CONFIRMED` *(unverified area)*

```swift
guard let names = try? FileManager.default.contentsOfDirectory(atPath: sessionsURL.path)
else { return [:] }        // absent, unreadable, and "nothing running" are now the same thing
```

The row set is 100% gated on these files. The view then states, unqualified: "No Claude Code sessions
running" + a "Launch Terminal" button. The same `try?`-to-empty shape repeats throughout — 31 `try?`
and one empty `catch {}` in this file alone.

**Impact:** on any machine where the directory is missing or momentarily unreadable, the tab asserts
as fact that nothing is running while three Claude terminals are open. The offered remedy makes it
worse — the newly launched session won't appear either.

**Fix:** a `DiscoveryState` enum (`.ok`, `.sessionsDirMissing`, `.sessionsDirUnreadable(String)`) set
via `do/catch` rather than `try?`, branched in the empty state.

---

**H25 · Automation permission denial is reported as "Terminal tab not found"** · Agents ·
`AgentTerminalControl.swift:53` · `CONFIRMED` *(unverified area)*

`run` collapses every osascript failure into `.ok` or `.notFound`, and `runProcess` sets
`task.standardError = FileHandle.nullDevice`. A denied Automation grant exits non-zero with
`Not authorized to send Apple events to Terminal. (-1743)` on stderr and nothing on stdout — so the
function returns `.notFound`, which surfaces as a gray toast reading **"Terminal tab not found"**.
There is no permission check anywhere in the file.

**Impact:** a user who denied the Automation prompt gets "Terminal tab not found" every time they
click Approve or Open, on a tab that is plainly on screen — pointing them at entirely the wrong
problem. Auto-resume degrades the same way with no diagnosis.

**Fix:** capture stderr; add `.notAuthorized` (-1743) and `.appNotRunning` (-600) outcomes; probe
proactively with `AEDeterminePermissionToAutomateTarget`; pass the `Outcome` through instead of a
`Bool`.

---

**H26 · No wake-from-sleep handling anywhere in the app** · all tabs · `AppDelegate.swift:374` ·
`CONFIRMED` — **materially narrowed by verification**

Grep confirms zero sleep/wake observers; the only system-state observer of this class is
`didChangeScreenParameters`. The verifier accepted that kernel but **rejected most of the
consequences and the app-wide scope**, noting Stats/Servers self-heal via `setPolling`'s eager first
call and that the strongest real consequence duplicates H16.

**Surviving form (MEDIUM, effectively part of H16):** no `NSWorkspace.didWakeNotification` observer
exists, so tabs without an expand-refresh — Calendar chief among them — show pre-sleep data after the
lid opens, with no timestamp or spinner to indicate age.

**Fix:** register a `didWakeNotification` observer appended to `observerTokens`, calling
`calendarModel.load()`, `toggles.refreshAll()`, `refreshFullscreenState`, `rebuildMetrics()`. Do
*not* add one for Stats/Servers — they already self-heal.

---

### MEDIUM (28) and LOW (24) — grouped by tab

<details>
<summary><b>Stats</b> — 6 findings</summary>

- **M1** First-ever expand shows CPU "0%", indistinguishable from a genuinely idle machine ·
  `StatsModel.swift:9` · `CONFIRMED`. Fix: give `cpu` the same `-1` sentinel as `gpu`/`fanRPM` and
  render "—", matching the GPU tile.
- **M2** `pollDisk()` does a 4.8 ms synchronous filesystem query on the main thread **every tick** —
  1200× more expensive than the equivalent key · `StatsModel.swift:102-108` · `CONFIRMED`. Worst at
  the 1 s refresh setting the Settings panel offers. Fix: poll disk on a 30-60 s cadence, or off-main.
- **M3** Every poll silently returns on failure and never restores its sentinel — a source that dies
  mid-session freezes on its last value forever · `StatsModel.swift:73, 96, 103-105, 112-130, 134-136`
  · `CONFIRMED`. This is the *general* form of the fan bug and applies to the (currently working) GPU
  tile too.
- **M4** An unavailable Battery renders a **RED** ring — a dead tile is visually identical to a
  critical-battery alarm · `TabViews.swift:1484-1485` · `CONFIRMED`. Red is the app's most urgent
  signal, spent on "I don't know".
- **M5** Fan gauge divides by a hardcoded 6000 while this machine's `F0Mx` is 6550, and ignores
  `F0Mn`=2317 so the ring can never read below 39% · `TabViews.swift:1478` · `CONFIRMED`. After the
  SMC fix this makes the ring decorative rather than a measurement.
- **M6** `stats.refreshRate` is read from UserDefaults with no clamp — a corrupt or wrong-typed value
  yields 0 and turns the poll into a spin loop · `SettingsStore.swift:201` · `SUSPECTED`.
- **L:** memory formula over-reports by 1.00 GiB vs Activity Monitor (`:97-99`); `pollBattery`
  iterates every power source without breaking, so a UPS would win (`:137-144`); Stats keeps polling
  behind the Settings overlay (`NotchView.swift:777-792`); timer has no `tolerance` and is
  `.default`-mode only (`:46-48`); all eight `@Published` written every tick regardless of change.

</details>

<details>
<summary><b>Servers</b> — 9 findings</summary>

- **M7** `portLive` burns its full 300 ms on a *wedged* listener and reports it as down · `:156` ·
  `CONFIRMED` (narrowed by verification: the serial-compounding impact story was wrong; the
  300 ms-and-false behaviour reproduces at 301.2-301.4 ms).
- **M8** Polling is not stopped when the Settings overlay replaces the Servers tab ·
  `NotchView.swift:777` · `CONFIRMED`. Each tick does a full `contentsOfDirectory(~/Core)` + up to 3
  `fileExists` per folder + a `package.json` read, behind an overlay showing none of it.
- **M9** Server logs grow without bound — never rotated, never truncated · `:250` · `CONFIRMED`.
- **M10** `remove()` leaks the port reservation and the favorite flag — `reg.ports` only ever grows ·
  `:290` · `CONFIRMED`.
- **M11** `stop()` is fire-and-forget SIGTERM: no verification, no escalation, no feedback · `:265` ·
  `CONFIRMED`. A node process that traps SIGTERM stays up and the row stays green forever.
- **M12** `add()` silently no-ops on a name collision · `:311` · `CONFIRMED`.
- **L:** pid files are write-only garbage, recorded and never read (`:251`) — *this is the missing
  ingredient for H1 and H4*; `ServersModel.mutate`'s `inout` registry is discarded (`:125`); stale doc
  comments still describe the deleted daemon/JSON-API/web-UI (`ServersTab.swift:6`); start/stop each
  run a full `~/Core` discovery just to look up one row (`ServersModel.swift:88`); `pickAndAdd` can
  leave `menuHoldsOpen` stuck (`ServersTab.swift:86`, `SUSPECTED`).

> **REFUTED:** "Start on an occupied port silently no-ops and the UI claims success." The play button
> and row tap are gated on `running`, which is the *same* `portLive` probe that triggers the early
> return — so the claimed scenario cannot occur as stated.

</details>

<details>
<summary><b>Media</b> — 8 findings</summary>

- **M13** The sound-output menu blanket-hides every virtual-transport device, so BlackHole, Loopback,
  SoundSource, Krisp and Zoom silently vanish with no "1 device hidden" hint ·
  `AudioOutputModel.swift:267-268` · `CONFIRMED`.
- **M14** Lyrics UI collapses three states — never fetched, none exist, network failure — into one
  string · `TabViews.swift:604-605` · `CONFIRMED`. No retry affordance.
- **M15** Every track change flashes the accent colour to orange for the duration of the artwork
  fetch (up to ~1.6 s on Apple Music) · `MediaWatcher.swift:450` · `SUSPECTED`.
- **M16** `MediaTab.onAppear` only fires on tab entry, never on expand — player volume and AirPlay
  targets seeded once then stale · `TabViews.swift:204-209` · `SUSPECTED`.
- **M17** `readPlayerVolume()` is **dead code**, so `youtubeJSBlocked` can never become true: the
  Chrome JS-permission hint never renders and the no-JS takeover fallback is unreachable ·
  `MediaWatcher.swift:922-950` · `CONFIRMED`. Chrome ships with "Allow JavaScript from Apple Events"
  **off by default**, so for most users three things fail silently at once.
- **M18** The app is **ad-hoc signed**, so every rebuild invalidates its TCC identity and silently
  drops Automation / Audio-capture / Accessibility grants · `CONFIRMED`. After a rebuild the notch
  quietly stops seeing Music, transport buttons do nothing, and the waveform switches to the
  synthetic fake (H12) — with no message anywhere.
- **L:** two full lrclib searches (~326 KB, ~1.6 s each) per track change with no cache at all
  (`LyricsModel.swift:28-41`); `LyricsModel.task` written from two threads without synchronisation
  (`SUSPECTED` — feeds C2); `MediaWatcher.deinit` doesn't invalidate its timers and `runOsascript`
  never drains the stderr pipe it creates.

> **REFUTED:** "CoreAudio property listeners are registered in init and never removed." Every factual
> claim holds, but `AudioOutputModel` is app-lifetime, so it is a hygiene note, not a defect.

</details>

<details>
<summary><b>Agents</b> — 6 findings <i>(area unverified)</i></summary>

- **M19** The Agents tab body and its 1 Hz clock keep running with the notch closed — the tab is never
  unmounted, only faded to opacity 0 · `NotchView.swift:499` · `CONFIRMED`. Per-row date math and
  token formatting run once a second for an invisible list. **Likely a contributor to C4.**
- **M20** Subagent transcripts are adopted, fully parsed on every append, then filtered out of every
  consumer — pure wasted work · `:1493` · `CONFIRMED`. Grows with exactly the workload this user runs
  most.
- **M21** Cold adoption of a resumed transcript allocates ~4× the file size and blocks the serial
  `ioQueue` for the whole read · `:1513` · `CONFIRMED`. ~200 MB spike for the largest transcript here,
  on an app that otherwise sits at 162 MB RSS.
- **M22** `parsers` is only evicted when the transcript file is deleted — and Claude Code never deletes
  transcripts · `:616` · `CONFIRMED`. Monotonic growth over multi-day uptimes.
- **M23** A single transient read failure on `~/.claude/sessions` permanently drops every auto-resume
  opt-in, unlogged · `:759` · `SUSPECTED`.
- **M24** A 5-hour limit banner landing inside a *subagent* transcript can never arm auto-resume ·
  `:1585` · `SUSPECTED` — i.e. it fails on the longest, most expensive runs, the ones most worth
  resuming. Same root cause as H23.
- **M25** No timeout on the osascript subprocess — one hung Apple Event wedges the control queue for
  the rest of the process lifetime · `AgentTerminalControl.swift:147` · `CONFIRMED`.

> **REFUTED:** "AgentSessionsModel's FSEventStream and 1.5 s rebuild timer can never be stopped — no
> `stop()` exists." False, and an artifact of grepping for `func stop()`: `func shutdown()` exists at
> `AgentSessionsModel.swift:445-457`, stops the stream and cancels both timers on `ioQueue`, and is
> called from `applicationWillTerminate`. The *ungated-while-closed* half of the finding stands
> (see M19).

</details>

<details>
<summary><b>Tray & Terminal</b> — 11 findings <i>(area unverified)</i></summary>

- **M26** Thumbnail cache is keyed by URL alone — no mtime, no requested size ·
  `TrayThumbnails.swift:9` · `CONFIRMED`. Overwrite a screenshot and the tile shows the old image
  until relaunch.
- **M27** "drag out to move" is actually a copy, and "Remove after drag out" only applies to the
  Drag-all chip · `TabViews.swift:911, 1024` · `CONFIRMED`. With the setting on, the shelf entry
  disappears while the original is still there.
- **M28** Tray persistence fails silently in both directions · `FilesTray.swift:20-21, 57-61` ·
  `SUSPECTED`. A shelf curated over weeks comes back empty after an interrupted write, presented as a
  normal empty tray — then permanently destroyed by the first subsequent interaction.
- **M29** Terminal PTY data is parsed on the **main queue** with no polling gate — a chatty session
  taxes the whole notch while closed · `TerminalSessionsModel.swift:38` · `CONFIRMED`.
- **M30** `signal()` kills a raw pid that SwiftTerm never clears after the child is reaped ·
  `:107-110` · `SUSPECTED`. Low probability, high blast radius: can terminate an unrelated process.
- **M31** The built-in shell gets a 6-variable environment — no `SSH_AUTH_SOCK`, hardcoded `LANG` ·
  `:51` · `CONFIRMED`. `git push` over SSH and `ssh host` behave differently than in Terminal.app in
  ways that are hard to attribute.
- **L:** one disk write + an O(n) scan per dropped file (O(n²) on a multi-file drop); a directory
  dropped twice becomes two rows when its path was missing at launch; AirDrop fires without checking
  `canPerform`, so a dead file's AirDrop item does nothing at all; `failed` set is permanent within a
  run, so an iCloud file that finishes downloading never gets its thumbnail; `TerminalIdentity`
  silently reports `.none` when the ancestry walk hits its 24-hop cap; terminal control is serialized
  behind an untimed osascript; dead session chips linger with a hint that only works for the selected
  chip.

</details>

<details>
<summary><b>Calendar, Notes, Timer</b> — 10 findings</summary>

- **M32** Month view drops all-day and multi-day events onto their start day only, and ignores the
  "All-day events" setting entirely · `CalendarModel.swift:117` · `CONFIRMED`. Two views of the same
  calendar disagree; a week-long trip shows as a single dot on day 1.
- **M33** Upcoming list is silently capped at 10 and the empty state hardcodes "7 days" regardless of
  the look-ahead setting · `TabViews.swift:1133` · `CONFIRMED`. Set look-ahead to "Today" and an empty
  afternoon reads "No events in the next 7 days".
- **M34** Every non-permission AppleScript failure in Notes is swallowed; the tab keeps claiming it is
  synced · `NotesSyncModel.swift:97` · `CONFIRMED`.
- **M35** Apple Notes mode silently shows only 9 notes and drops the rest · `:101` · `CONFIRMED`.
  Because the cut is by modification time, the visible set reshuffles unpredictably.
- **M36** Notes conflict detection rests on `Double(parts[1]) ?? 0`; any parse failure turns every
  subsequent save into a fake conflict that discards the user's text · `:113` · `SUSPECTED`.
- **M37** Timer tab hardcodes "+ 5m break" while break length is a 1-30 minute setting ·
  `TabViews.swift:862` · `CONFIRMED`.
- **M38** Tapping a focus-length chip mid-run drives the progress ring **negative** ·
  `PomodoroModel.swift:54` · `CONFIRMED`. Ring and digits disagree, and the ring sweeps backwards for
  a full second.
- **M39** Focus length chosen in the Timer tab never reaches Settings and is lost on relaunch ·
  `TabViews.swift:847` · `CONFIRMED`. A running pomodoro is silently gone on quit with no record.
- **M40** End-of-phase toast is suppressed whenever the notch is expanded *or* a fullscreen Space is
  active — only the sound survives · `NotchView.swift:941` · `CONFIRMED`. Working fullscreen is the
  archetypal pomodoro case; with the sound set to "none" the phase boundary is completely silent and
  invisible.
- **L:** `CalendarSettings` runs a synchronous EventKit query inside a SwiftUI `body`
  (`SettingsViews.swift:510`); the Notes cache is fully rewritten on every keystroke with every write
  error discarded; debounced pushes are keyed per note and never pruned; Pomodoro publishes at 1 Hz
  while collapsed, re-evaluating the whole notch hierarchy even when the countdown ear is off.

> **NARROWED:** "Calendar authorization status is cached at init" — accurate but low-severity in
> isolation; its user-visible force comes from H15, where it is already captured.

</details>

<details>
<summary><b>Controls / Toggles / Mirror</b> — 9 findings</summary>

- **M41** Dark Mode card **hardcodes `active: false`** — it never shows whether dark mode is on ·
  `TabViews.swift:1565` · `CONFIRMED`.
- **M42** Mute card **hardcodes `active: false`** — never reflects the muted state ·
  `TabViews.swift:1592` · `CONFIRMED`. With M41, half the six action tiles are permanently stateless
  while the other half are stateful, so the row can't be read as a status row.
- **M43** Every Controls action swallows its launch error — six buttons that can fail invisibly ·
  `TogglesModel.swift:211` · `CONFIRMED`. Keep Awake is the worst case: if `caffeinate` fails to
  spawn, the toggle still lights up.
- **M44** `TogglesModel.init` runs a 100 ms synchronous AppleScript on the main thread at launch for a
  value **no view renders** · `:91` · `CONFIRMED`.
- **M45** The brightness read path swallows the API status code — a failed read renders as a real 0% ·
  `:31` · `CONFIRMED` (narrowed: the `?? 0` fallbacks at `:167/:175` are unreachable because
  `TabViews.swift:1860/1872` gate the slider on availability and fall back to a StepperCard).
- **M46** Sliders only echo their own writes — external brightness changes are never observed ·
  `TabViews.swift:1644` · `CONFIRMED`. Press F1/F2 with Controls open and the bar does not move.
- **M47** `TouchSensor` mutates static state from the MultitouchSupport callback thread with no
  synchronization, and can never be stopped · `TouchSensor.swift:32` · `SUSPECTED`. Rare
  background-thread crashes; the sensor stays armed 24/7 including through display sleep.
- **M48** Mirror's `isRunning` is set true whether or not the session actually started, and a
  permanently failing session retries forever at 1.7 Hz · `MirrorController.swift:137` · `SUSPECTED`.
- **L:** `MirrorController`'s notification observers are never removed and `preferredCameraID` is
  raced across queues (`SUSPECTED`); the always-on hover poll runs at 8.3 Hz whenever collapsed,
  doing coordinate conversions on main (`AppDelegate.swift:537`) — 25,183 idle wakeups are consistent
  with it.

</details>

<details>
<summary><b>Infra / cross-tab</b></summary>

- **M49** `NotchState.visibleTabs` recomputes a filtered array on **every access**, called once per
  tab chip per layout pass · `NotchState.swift:201` · `CONFIRMED`. Combined with C4's per-frame
  relayout this is ~1,200 array allocations/second on the main thread. *(A parallel session touched
  `NotchState.swift` at 19:09 — re-check.)*
- The gating ledger: **only** `media.setProgressPolling`, `stats.setPolling` and `servers.setPolling`
  are gated on `expanded && currentTab` (`NotchView.swift:768-770, 795-797`). The other eight models
  are ungated. None of the three is re-gated when the **Settings overlay** covers the tab
  (`NotchView.swift:777`) — see M8 and the Stats LOW.

</details>

---

## 4 · Idle-cost table

All measurements by **cumulative-CPU-time delta** (`ps -o time=` sampled across a wall-clock window),
not `ps %cpu` — the latter is a decaying average on macOS and read 1.8% then 14% within 5 s of the
same steady state.

| Condition | Notch | CPU (1 core = 100%) | RSS | Notes |
|---|---|---|---|---|
| ~8-10 Claude sessions writing transcripts | closed | **23-35%** (peak 35.5) | 159-161 MB | during this audit's own fan-out |
| Fleet winding down (~2-3 sessions) | closed | **13-18%** | 161 MB | |
| Quiet (no active session) | closed | **3.6-5.0%** | 161 MB | the honest floor |
| Independent run, agent working | closed | **17.5%** mean (16.3-19.7, n=12×5 s) | — | `sample`: 13.2% of main thread in `NSDisplayCycleFlush` |
| Second independent run | closed | **17.4%** (+15.45 s CPU / 89.0 s wall) | — | |
| Lifetime average, PID 965 | mixed | **~3.2%** (180.5 s CPU / 5,700 s elapsed) | — | proves the load is bursty, not constant |

**Threads:** 12-13. **File descriptors:** 52 total — no leak signature. **Children:** one expected
(`_serve.py` on :8123); zero zombies. **RSS drift:** none over 90 s or over the 30-minute timeline.

**Per-tab expanded cost: NOT MEASURED.** Every measurement above is the *closed* state — opening the
notch to a specific tab requires a physical gesture (see U-list). This is the single biggest gap in
the cost picture.

**Reading:** the app's idle floor is ~4%, which is defensible for a menu-bar utility. The 17% and
30%+ figures are *load-correlated*, tracking Claude session activity ~7×. Combined with H23/M19/M20
(the Agents tab is never unmounted, parses subagent files it then discards, and its 1 Hz clock runs
while closed) and C4's full-tree relayout, the Agents subsystem is the prime suspect for the
overshoot — but **the mechanism is not isolated**, and the seven OS CPU-runaway reports predate this
audit by a week.

---

## 5 · Pattern classes — the systemic view

The 127 findings collapse into six recurring shapes. Fixing the *shape* is worth more than fixing the
instances.

| # | Pattern | Instances | Tabs | Systemic fix |
|---|---|---|---|---|
| **P1** | **Silent unavailability rendered as a normal value.** A source fails, the error is swallowed by `try?`/`?? -1`/an empty catch, and the UI shows "—", a zero, a green dot, or (worst) a *plausible fake*. | ~24 | Stats, Media, Servers, Tray, Agents, Controls | Every model gets an explicit `unavailable: [String: String]` (or per-feature `failure: String?`) that records **why**, and every view that can render "—" renders the reason on hover. Ban bare `try?` at I/O boundaries in review. |
| **P2** | **Permission denial indistinguishable from empty state.** TCC-gated sources render "nothing here" instead of "we can't see it". | 7 | Calendar (H15), Mirror (H13), Media/audio-tap (H12), Agents/Automation (H25), Media/ad-hoc-signing (M18) | One reusable `PermissionGate` view: switch on the *full* authorization enum (never a Bool), name the missing grant, and offer the matching `x-apple.systempreferences:` deep link. Never latch a denial — recompute from live status on appear. |
| **P3** | **Ungated always-on work.** Only 3 of 11 models are gated on `expanded && currentTab`; tabs are faded to opacity 0, never unmounted. | 8+ | Media (H11), Agents (M19), Terminal (M29), Timer, Toggles, all views | Extend the `setPolling(_:)` contract to every model, drive it from one place, include `showingSettings` in the predicate, and **unmount** heavy tabs rather than fading them. |
| **P4** | **Read-once state presented as live.** A value is sampled at `init` or first `onAppear` and never re-read, while the control remains interactive. | 6 | Controls (H5, H6, M46), Calendar (H16), Media (M16), Tray | Because the panel is always mounted, `onAppear` is not a visibility signal — establish `onChange(of: isExpanded)` + `onChange(of: currentTab)` as the *only* refresh idiom, with an immediate refresh on the true edge. |
| **P5** | **Fire-and-forget subprocess/child lifecycle.** Children outlive the app; exit statuses are discarded; no timeouts. | 6 | Servers (H1, H3, M11), Terminal (H21), Agents (M25), Notes (C1) | One helper for every `Process`/osascript call: drain pipes *before* `waitUntilExit`, impose a timeout, return `(stdout, stderr, status)`, and never discard the status. This single helper fixes C1, H3, H21, M25 at once. |
| **P6** | **Hardcoded constant that should be queried.** | 5 | Stats (M5 fan/6000, H7 GiB-vs-GB), Agents (H22 model catalog), Timer (M37 break length), Terminal (M31 env) | Query the source of truth once and cache it; where a catalog is unavoidable, make a miss *visible* rather than silently degrading. |

**And the meta-pattern:** the app's own comments repeatedly describe behaviour that the code does not
implement — `FilesTray`'s "the UI marks unreachable items instead (see `isAvailable`)" (H19),
`portLive`'s comment (M7), `ServersTab`'s daemon docs, `MediaWatcher`'s "NSAppleScript is
main-thread-only and blocks the UI, so it's reserved for the rare one-shot" (violated by H10). The
doc comments are a reliable index of *intended* behaviour worth auditing against.

---

## 6 · Verification matrix — 11 tabs × 5 dimensions

`C` = CONFIRMED (measured/reproduced) · `S` = SUSPECTED (code reasoning) · `NT` = NOT TESTED

| Tab | Truthfulness | Lifecycle | Staleness on expand | Failure visibility | Robustness |
|---|---|---|---|---|---|
| **Media** | `C` — now-playing correct; virtual outputs hidden M13; lyrics C2 | `C` — ungated YouTube poll, ~960 spawns/h closed (H11) | `S` — `onAppear` never re-fires; volume/AirPlay stale (M16) | `C` — dead `readPlayerVolume` M17; `S` — spectrum fakes a waveform H12 | `C` — main-thread colour extraction H9 + blocking AppleScript H10 |
| **Notes** | `C` — only 9 notes shown M35 | `NT` | `C` — pulls on every expand (`AppDelegate.swift:955`) | `C` — failures swallowed M34 | `C` — 64 KiB deadlock C1; whitespace loss H18; edit-on-quit H17 ⚠*rewritten 19:07* |
| **Timer** | `C` — hardcoded "5m break" M37; ring goes negative M38; setting lost M39 | `S` — publishes 1 Hz while collapsed | `NT` — wall-clock design should self-correct (needs U-check) | `C` — end-of-phase toast suppressed when expanded/fullscreen M40 | `C` — wall-clock based, survives sleep (good) |
| **Tray** | `C` — drag-out is a copy, not a move M27 | `NT` — no `.tray` branch in either lifecycle hook | `C` — nothing revalidates on expand (H19) | `C` — dead files look normal H19; QL error discarded H20 | `C` — O(n²) multi-drop; `S` — persistence fails silently M28 |
| **Terminal** | `C` — 6-var env, no `SSH_AUTH_SOCK` M31 | `C` — PTY parsed on main queue, ungated M29 | `NT` | `S` — `.none` on 24-hop cap; untimed osascript | `C` — SIGKILL orphans background jobs H21; `S` — raw-pid kill M30 |
| **Agents** | `C` — model catalog stale H22; subagent clock frozen H23 | `C` — tab body + 1 Hz clock run while closed M19; `shutdown()` *does* exist | `NT` | `C` — missing dir → "no sessions" H24; Automation denial → "tab not found" H25 | `C` — 4× RSS on cold adopt M21; parsers never evicted M22 |
| **Servers** | `C` — IPv4-only H2; squatter reads as running H4; orphan survives quit H1 | `C` — gated, but not behind the Settings overlay M8 | `C` — `setPolling(true)` polls immediately ✅ | `C` — failed launch invisible H3; `readLog` has no caller | `C` — logs unbounded M9; port/favorite leak M10 |
| **Calendar** | `C` — month view drops all-day/multi-day M32; list capped at 10 M33 | `C` — no timer at all; only loads on tab switch | `C` — **not refreshed on expand** H16 | `C` — denied ≡ never-asked, dead button H15 | `C` — synchronous EventKit inside a SwiftUI body |
| **Mirror** | `S` — `isRunning` true regardless of actual start M48 | `S` — camera survives lock/sleep and pinning H14 | `NT` | `S` — permanently dead after one denial H13 | `S` — observers never removed; `preferredCameraID` raced |
| **Stats** | `C` — **fan dead** (§2); disk GiB/GB H7; GPU ✅ correct; CPU ✅; battery ✅ | `C` — gated correctly both directions ✅; not behind Settings overlay | `C` — first post-expand CPU is a stale average H8; first-ever expand reads 0% M1 | `C` — no sentinel restore M3; unavailable battery paints RED M4 | `C` — 4.8 ms main-thread `pollDisk` per tick M2; `mach_host_self` handled correctly ✅ |
| **Controls** | `C` — volume/desktop read once H5; Dark Mode + Mute hardcoded `false` M41/M42; sliders echo own writes M46 | `S` — TouchSensor armed 24/7, cannot be stopped M47 | `C` — brightness read once at mount H6 | `C` — **Lock Screen is a permanent no-op** C3; all six actions swallow errors M43 | `C` — 100 ms AppleScript on main at launch M44; `S` — TouchSensor thread race M47 |

**Coverage gaps worth naming:**

- **Per-tab expanded cost is entirely NT** — every runtime measurement is closed-state.
- **Staleness is NT for Notes, Terminal, Agents, Mirror** — each needs an expand gesture.
- **Timer's sleep behaviour is NT** — the wall-clock design predicts it self-corrects; unconfirmed.
- **Agents / Tray+Terminal / runtime-cost findings never went through adversarial verification.**
  Given that verification killed or narrowed 11 of the 47 it *did* review (~23%), expect a similar
  rate among these.

---

## 7 · Checks that need you (batched — one pass)

The audit could not open the notch, hover, or play media. These are ordered so one sitting covers them.

**Highest value first:**

1. **U1 — isolate C4.** With **no** Claude session working (no pulsing dot), notch closed:
   `ps -o time= -p $(pgrep -x Notchbook)` twice, 30 s apart. Then repeat *with* a session working.
   Expected if the animator theory holds: <1.5 s per 30 s (~4%) idle vs ~5.2 s (~17%) working. **This
   one measurement decides the app's biggest open question.**
2. **U2 — Stats:** open to Stats. Does Fan read "—"? Read CPU the instant it appears and again 3 s
   later (H8). Compare the Disk tile against Finder's Get Info (expect ~689 vs ~740, H7).
3. **U3 — Controls:** click **Lock Screen** (expect: nothing, C3). Click **Dark Mode** and **Mute** —
   does either tile ever turn orange (M41/M42)? Note the brightness bar, close, press F1/F2, reopen —
   did it move (H6)? With Controls *open*, press F1/F2 — does it track (M46)?
4. **U4 — Calendar:** what does the tab show — real events or "Connect your Calendar"? If the latter,
   click "Allow Access" once: does a system dialog appear, or nothing (H15)? Then note the list,
   collapse, wait for an event to end, re-expand **without switching tabs** (H16).
5. **U5 — Media:** with Music playing, open Media. Do the waveform bars move *with* the music or in a
   steady mechanical rhythm (the latter = the synthetic sine, H12)? Let the track change with lyrics
   on — does it say "No lyrics for this song" for a song that has them (C2)? Toggle lyrics off/on: if
   they appear, C2 is confirmed end-to-end.
6. **U6 — Agents:** confirm the `claude-opus-5[1m]` rows show a raw model badge and **no** context bar,
   while the Fable row shows a normal badge *with* a bar (H22).
7. **U7 — Servers:** confirm the header reads "1 running · 5 total" with a green dot only on foglamp.
   Tap ▶ on Marginal-Economics (:8080 is free) and time it — any intermediate feedback? Tap it twice
   rapidly — any response at all (H3)?
8. **U8 — Tray:** drop a file, delete it in Finder, reopen Tray — still a normal full-colour icon
   (H19)? Right-click → AirDrop: nothing at all (LOW)?
9. **U9 — Mirror (privacy):** start the mirror, confirm the green light, lock with Ctrl-Cmd-Q, and
   report whether the green light **stays lit behind the lock screen** (H14).
10. **U10 — Terminal:** `echo $SSH_AUTH_SOCK` in the island's terminal vs Terminal.app (M31). Then
    `sleep 400 &`, quit the app, and check `ps -ax | grep 'sleep 400'` for a surviving ppid-1 process
    (H21).
11. **U11 — Timer:** start 45m, wait 5 min, tap the "15m" chip — ring collapses while digits read
    ~40:00 (M38)? Set break to 10 min in Settings — does the tab still say "+ 5m break" (M37)?
12. **U12 — Notes (⚠ touches real Notes data, only if willing):** paste an indented code block into a
    synced note, wait 5 s, collapse and re-expand — indentation gone (H18)?

**Two decisions for you:**

- **D1:** Confirm the 19:11 rebuild/relaunch was you or a parallel session. If it was neither, that is
  a finding in itself.
- **D2:** The orphaned foglamp server (**PID 1099**, up since 17:21:59, holding :8123, parent
  launchd) is still running. It was deliberately **not** killed. It will outlive the app until killed
  manually.

---

## 8 · Suggested remediation sequence

Not applied — this is the ordering for a later fix session.

**Wave 1 — one-line truths, zero risk, immediately visible** (independent, parallelizable):
`KeyInfo` padding (§2) · disk GiB→GB (H7) · `prevTicks = nil` (H8) · fan denominator (M5) ·
"+ 5m break" (M37) · `visibleTabs` stored (M49) · drop the SIGKILL (H21) · `refreshRate` clamp (M6).

**Wave 2 — the shared helpers that each close a whole pattern class:**
1. The subprocess helper (P5) — drain-then-wait + timeout + returned status. Closes **C1, H3, H21,
   M25** and de-risks H10.
2. The `PermissionGate` view (P2) — closes **H15, H13, H12, H25** and makes M18 visible.
3. The `unavailable`/`failure` channel (P1) — closes **M3, M4, H20, H24, M34, M43** and makes the
   next fan-tile-class bug self-reporting.

**Wave 3 — lifecycle, one PR since it all touches `NotchView`'s two hooks (P3/P4):** extend
`setPolling` to Toggles/Media-YouTube/Calendar/Agents; include `showingSettings` in the predicate;
unmount heavy tabs instead of fading them; add the wake observer. Closes **H5, H6, H11, H16, H26,
M8, M19, M29, M46** and part of C4.

**Wave 4 — C4 proper**, once U1 has isolated it. Do this *after* Wave 3, because Wave 3 removes
several confounds.

**Wave 5 — Servers correctness as a unit** (H1, H2, H4, M11, M14-pids): they all depend on the same
missing ingredient — actually *using* the pid file that `start()` already writes.

**Wave 6 — Agents** (H22, H23, M20-M24), and **re-audit Notes from scratch** against the rewritten
`NotesSyncModel.swift`.

**Prerequisite for everything:** re-run the affected verifications against the current tree, since
five files moved during this audit.

---

## 9 · Visual advice — no changes made

Advice only. Nothing here was applied. Ranked within each tab; `TabViews.swift` line numbers are the
least reliable (+315 lines landed mid-audit).

### Highest value

1. **`NotchView.swift:1054-1060` — replace the collapsed pill's perpetual pulse with a state
   *transition*.** A static filled dot plus a thin ring that animates only on idle→working→complete,
   or the pulse rendered in a `Canvas` leaf. Apple's own Dynamic Island uses colour and glyph, not
   perpetual motion, for background state. This is the one visual decision that may cost ~17% of a
   core permanently.
2. **`TabViews.swift:1507-1513, 1544-1549` — give `StatTile` an `unavailable` state.** Today "no data"
   and "0%" paint the identical 0.02 green stub, and an unavailable Battery paints a **red** one
   because `invertSeverity` turns fraction 0 into an alarm. Dash the track and drop to
   `.white.opacity(0.18)` when the value is "—".
3. **`TabViews.swift:1387-1408` (Mirror) — give the denied/unavailable states an action row.** These
   are the only screens in the app with no affordance at all, and they are exactly the states the user
   is stuck in permanently. Two buttons: "Open Privacy Settings" + "Try Again".
4. **Calendar empty state — split "no events" from "no permission"** with a "Grant Calendar Access…"
   button. Apple's apps always *name* a missing permission rather than showing emptiness.
5. **`TabViews.swift:980-994` (TrayTile) — desaturate + badge unreachable files.** `.saturation(0)`,
   `.opacity(0.45)`, and an orange `exclamationmark.triangle.fill` bottom-leading. This is the visual
   half of H19; Finder sidebar favourites and Dock stacks already establish the idiom.
6. **`ServersTab.swift:153` — make the status dot three-state** (green = up and ours, amber = port live
   but held by another process, gray = down). The binary dot currently conflates "your server" with
   "a stranger on your port" and "stopped" with "IPv6-only so we can't see it".
7. **`AgentsTab.swift:609-617` — bound the model badge**: `.truncationMode(.tail)`,
   `.frame(maxWidth: 96, alignment: .trailing)`, `.layoutPriority(0)`. On 2 of 4 live sessions it
   currently renders the literal `claude-opus-5[1m]` at 8.5 pt with no width bound, eating the title
   row.
8. **`AgentsTab.swift:646-658` — render an empty context track instead of nothing** when the window is
   unknown. The meter vanishing changes row height and destroys the list's strongest visual rhythm.

### Layout stability (all the same bug shape: inserting a view on hover reflows its neighbours)

9. `TerminalTab.swift:98-105` — reserve the ×'s width and animate opacity only; today the chip row
   jitters as the pointer sweeps across it.
10. `AgentsTab.swift:386-396` — reserve the Open button's 30×22 slot rather than inserting it on hover,
    which currently reflows the context %, the terminal tag, and everything left of it.
11. `NotchView.swift:1070-1076` — give the count capsule an explicit width (single-digit vs "9+") so
    the collapsed ear stops jittering as sessions come and go.

### Per-tab polish

12. `TabViews.swift:1478` — normalize the fan ring against real `F0Mn`/`F0Mx` rather than a hardcoded
    6000 (currently reads 42% full on a cold idle Mac and saturates 550 rpm early).
13. `TabViews.swift:1459-1486` — thread a `.help(…)` string through every `StatTile` naming its source
    ("AppleSMC key F0Ac unavailable on this Mac"). The codebase already uses `.help()` 41 times, so
    this is the house idiom for exactly this problem, at zero layout cost.
14. `ServersTab.swift:168` — `Text(":\(server.port)")` renders a literal **`:0`** for entries with no
    assigned port. Render an em dash instead; `:0` reads like a truncation bug.
15. `ServersTab.swift:49` — reserve space after the header stat line for an amber "1 failed to start"
    capsule. `readLog` is already fully written and merely lacks a caller — the UI is one control away
    from turning every silent failure into a readable one.
16. `TabViews.swift:1211-1216` — stop using `Color.orange` for both the today-circle and the
    has-events dot; on today (the most-looked-at cell) the dot is nearly invisible against the fill.
17. `TabViews.swift:1189-1194` — render only the rows the month needs (5 usually, 6 when required)
    instead of a fixed 42-cell grid that wastes a dead row in most months inside a fixed-height panel.
18. `TabViews.swift:1307-1342` — group the event list by day with "Today"/"Tomorrow"/"Fri 31" headers
    and reduce each row's secondary line to the time range; six events today currently repeat the full
    date six times and still omit the end time.
19. `TabViews.swift:824-841` — give the three transport buttons equal ~24 pt circular targets with a
    shared `.white.opacity(0.08)` fill; three bare glyphs at different sizes read as unrelated
    affordances, and the 11 pt skip glyph is a very small target.
20. `TabViews.swift:436-452` — cross-dissolve the cover instead of hard-cutting through the
    placeholder; artwork is nil'd on every track change and can take ~1.6 s to arrive.
21. `NotchView.swift:902-905` + `TabViews.swift:1866-1872` — for small bar counts sample the *newest*
    levels rather than spreading the whole history. With `levels.count=60` and `barCount=4` the current
    formula picks indices 14/29/44/59, so adjacent ear bars are 0.9 s apart.
22. `TabViews.swift:330-395` — keep a compact transport strip visible when lyrics are on; today
    enabling lyrics swaps out play/pause, next, previous, shuffle, repeat, the progress bar *and* the
    volume row all at once.
23. `TabViews.swift:1638-1678` — rebuild `BrightnessCard`'s track in Control Center's idiom (full
    22 pt inner height, glyph inside the track). A 4 pt hairline in a 28 pt card is the only control
    in the tab that doesn't fill its tile.
24. `TabViews.swift:23-33` — add a placeholder ("Jot something down…") and a hairline stroke to the
    Notes editor; an empty note is currently an untextured grey rectangle that gives no cue it's
    editable, and it is the tab's entire content area.
25. `TabViews.swift:926-938` — differentiate the "Drag all" handle from the two adjacent buttons
    (dashed stroke, or a `line.3.horizontal` glyph); three identical capsules sit in a row and only two
    are buttons.
26. `TabViews.swift:946-952` — make Clear reversible or deliberate; one 9 pt tap silently discards a
    shelf curated over weeks, with no undo. The app already ships a hold-to-confirm idiom at
    `AgentsTab.swift:530-541`.
27. `AgentsTab.swift:327-340` — cap `approvePreview` at `.lineLimit(4)` with the full text in the
    existing `.help`; `toolDetail` currently lets a 2,000-character Bash command render unbounded.
