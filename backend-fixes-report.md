# Dynamic Island — Backend Remediation Report

Execution of `opus-backend-fixes.md` against `backend-audit-findings.md`.
Baseline `564b6f5` · 2026-07-25 · 20 files, +970/−180 across six commits, all pushed to `main`.

| commit | wave |
|---|---|
| `6dda48b` | 1 — one-line truths |
| `836c651` | 2 — subprocess helper + C3 |
| `229ae02` | 2 — PermissionGate + failure channel |
| `20054b8` | 3 — lifecycle gating |
| `bee3716` | — repair (see §4, a defect I introduced) |
| `bb4ca9b` | 4 — pill animator (**did not achieve its goal**, see §3) |

**Status: waves 1–3 complete and verified. Wave 4 attempted, negative result.
Waves 5–6 not started.** §6 lists exactly what remains.

---

## 1 · Fixed and verified

Each row was reproduced before fixing and re-probed after, per the prompt's method rule.

| # | Finding | Evidence after fix |
|---|---|---|
| §2 | **SMC fan ABI (76 vs 80)** | Shipped binary now passes `mov w3, #0x50` (was `0x4c`). Probe: 80-byte call returns `F0Mn`=2317, `F0Mx`=6550. Added `assert(MemoryLayout<KeyData>.size == 80)` so it cannot regress silently. |
| H7 | Disk GiB labelled GB | Tile **689 → 740 GB**. `diskutil` free = 727.6 GB; the 12 GB delta is purgeable space, which `volumeAvailableCapacityForImportantUsage` counts and Finder shows too. |
| M5 | Fan gauge ÷ hardcoded 6000 | Normalized to live `F0Mn`/`F0Mx`. |
| H8 | CPU tile shows a stale average on re-expand | `prevTicks = nil` on stop. |
| M1 | First-ever expand reads a confident 0% | `cpu` starts at −1 → renders "—". |
| M6 | `refreshRate` unclamped → spin loop | Clamped `[0.5, 10]` at read. |
| M49 | `visibleTabs` recomputed per access | Stored; recomputed on `tabOrder`/`hiddenTabs` change. |
| **H21** | **Quit orphans every background job** | PTY probe, old vs new: old → `sleep 400` **ALIVE, ppid 1**; new → **gone**. |
| **C1** | Notes ≥64 KiB deadlock | See §2 — *already fixed* by the rewrite; a **narrower variant survived and is now fixed**. |
| P5 | Four hand-rolled `Process` call sites | `Subprocess.swift`: concurrent drain, bounded wait, returns `(out, err, status)`. Probe: 400 KB stdout ✓, **70 KB stderr ✓ (old code hung here)**, 400 KB both ✓, hung child killed at deadline with no orphan ✓. |
| **C3** | **Lock Screen was a permanent no-op** | `CGSession` does not exist on macOS 26 (`User.menu` is absent); the launch error went into a `try?`. Now `SACLockScreenImmediate` via `dlopen`, Ctrl-Cmd-Q fallback. **Needs your click to confirm — §5.** |
| M43 | Six Controls buttons fail invisibly | `shell()` returns success and records `lastActionFailed`; Keep Awake no longer lights up when `caffeinate` fails to spawn, and reverts if it dies. |
| **H25** | Automation denial reported as "Terminal tab not found" | stderr captured; `notAuthorized`/`appNotRunning`/`timedOut` outcomes threaded through the model (not a `Bool`) so the toast names the real problem. |
| M25 | No timeout on osascript | 5 s deadline. |
| H15 | Calendar denied ≡ never-asked | `PermissionGate` switches on the real state; Settings deep-link for denied/restricted, write-only handled. |
| H13 | Mirror bricked after one denial | `denied`/`unavailable` recomputed from the live system, never latched; retry always offered. |
| **H12** | **Audio tap failure rendered as a bouncing waveform** | Four silent returns now record a reason; the ear renders **static** instead of animating a synthetic sine; the tab names the cause. |
| M3/M4 | Dead tiles freeze on last value; unavailable Battery paints **red** | Sentinel restored per poll with a reason; `StatTile` gets a real unavailable state (no trim stub, neutral ring). |
| L | Battery picks the last power source | Filters to `kIOPSInternalBatteryType` and breaks — a UPS no longer wins. |
| H19/H20 | Dead tray files look normal; QuickLook error discarded | `ThumbState` (loading/noPreview/missing/denied); dead tiles desaturate + badge + strike, and Open/Reveal/AirDrop are disabled. |
| H24 | Missing `~/.claude/sessions` → "No Claude Code sessions running" | `DiscoveryState` distinguishes ok / missing / unreadable. |
| **H11** | YouTube poller ungated | Visibility-gated, 30 s cold cadence, skips when Chrome isn't running. **Measured, notch closed, Chrome running: 4 spawns in 100 s (1 per 25 s) vs the audited 1 per 3.75 s** (~27 expected). |
| H16 | Calendar never refreshed on expand | Real visibility hook + 60 s tick while open. |
| H5/H6/M46 | Controls read once at launch | Re-read on the visibility edge; 0.5 s tick tracks F1/F2 live. |
| M8 | Polling continued behind the Settings overlay | `showingSettings` is now in every predicate. |
| H26 | No wake-from-sleep handling | `didWakeNotification` observer (narrowed form, per verification). |
| M19 | Agents 1 Hz clock ran while closed | Ticks only when that tab is visible. |

**Design note.** Waves 2–3 replaced three divergent gating handlers with one
`applyGating(expanded:tab:settingsShowing:)`. That is the systemic fix for pattern
class P3 — the previous shape is what let eight of eleven models run ungated.

**A regression I caught before shipping it:** the Controls 0.5 s tick initially
called `readVolume()`, a ~100 ms synchronous `NSAppleScript` on the main thread —
twice a second. Split into `refreshCheap()` (C calls + plist reads) on the tick and
the expensive read on the visibility edge only.

---

## 2 · Re-audited, verdict changed

The prompt required re-auditing before fixing. Two findings did not survive contact.

**C1 — Notes 64 KiB deadlock → ALREADY FIXED, narrower variant found and fixed.**
The rewritten `NotesSyncModel.run()` already drains both pipes *before*
`waitUntilExit`. Probe against the current code: 400 KB stdout returns in 1.38 s
where the audited code hung permanently at 70 KB. **But the drain was sequential**,
so >64 KiB on *stderr* still deadlocked — reproduced at exactly the same threshold
(65,000 ok / 70,000 hang). Migrating to `Subprocess` fixed the survivor.

**M37 — break-hint hardcoded "5m" → DEFERRED, not fixed.** A parallel session's
TimerTab restructure (`opus-timer-layout.md`) landed uncommitted in the working
tree, and the one-line edit is entangled with it. Per the prompt's coordination
rule I did not restructure TimerTab. Re-apply once that work commits.

---

## 3 · Wave 4 (C4) — attempted, goal not met

Stating this plainly as the prompt requires: **the CPU burn is not fixed, and my
mitigation produced no measurable improvement.**

### Measurements (cumulative-CPU delta, notch closed)

| condition | CPU |
|---|---|
| HEAD before pill fix | **14.8%** |
| HEAD after pill fix (`bb4ca9b`) | **19.9%** |
| working tree (+2 sessions' uncommitted features) | 23–26%, later **50.7%** |
| audit's original baseline | 17.5% working / 3.6–5% quiet |

### What the evidence says

- **It is not the transcript tailing.** CPU held a flat 19.9–20.5% across six
  consecutive windows with **zero** jsonl writes. This refutes the audit's rival
  hypothesis as the dominant cost.
- **It is not (only) the pill animator.** After replacing the `.repeatForever`
  opacity animation with a TimelineView-driven `Canvas` leaf, a 15 s sample still
  shows the full-tree relayout: `NSDisplayCycleFlush` ×11, `ViewGraphRootValueUpdater`
  ×42, `LayoutEngineBox` ×124 — with the new `Canvas` visible in the stacks, so the
  `.working` branch *was* being exercised. The animator was at most a contributor.
- **A large share is not mine.** The HEAD-only build (19.9%) versus the working-tree
  build (23–50%) isolates ~30 points to the two parallel sessions' uncommitted
  features. Their files were unchanged between measurements, so that share is real
  but not attributable to the audited code.
- **The 23→50% swing on identical code** is the strongest new clue: it varies with
  which tab is current. Because the expanded panel is never unmounted, the current
  tab's view tree keeps rendering while the notch is closed.

### Next suspect

**The always-mounted tab architecture**, not any single animation. `NotchView`
renders `expandedContent` unconditionally and expresses collapse as opacity, so
whichever tab is selected keeps its body live. The prompt explicitly forbade
flipping that wholesale (it underpins the liquid choreography), so the fix is
per-tab: hoist the heavy tabs behind `if state.isExpanded || morphHoldExpanded`,
starting with Agents and Media.

`bb4ca9b` is kept — a Canvas leaf is architecturally correct and drops the
invalidation rate from display refresh to 20 Hz — but **it is not a fix for C4 and
should not be recorded as one.**

---

## 4 · A defect I introduced and had to repair

Waves 1–3 were staged hunk-by-hunk with `git apply --cached --unidiff-zero` to keep
two parallel sessions' uncommitted work out of my commits. **That was the wrong
tool.** Zero-context hunks carry no anchor text, so git applied them at line numbers
taken from the full working-tree diff — which were wrong once the other sessions'
hunks were filtered out.

**Three commits on `main` did not compile.** `recomputeVisibleTabs()` landed after
the closing braces of both `didSet` blocks; the wake observer was spliced into the
middle of the `didChangeScreenParameters` registration; several `TabViews` additions
landed inside unrelated functions. The working tree built fine throughout, which is
exactly why it went unnoticed — I was verifying the tree, not `HEAD`.

Found by building `HEAD` in a detached worktree while chasing the CPU number.
Repaired in `bee3716` by rebuilding the three files from the `564b6f5` blobs with
**content-anchored replacements**, which cannot be misplaced, then verifying with a
hard reset + clean build.

**Process lesson:** when partial staging is unavoidable, verify the commit, not the
working tree — `git worktree add --detach HEAD && swift build`. That check should
have run before the first commit, not after the third.

---

## 5 · What needs you

**Re-grant TCC first.** The app is ad-hoc signed (M18), so every rebuild invalidates
its identity and silently drops Automation, audio-capture and camera grants. Several
checks below will look broken until you do.

1. **Lock Screen** (C3) — click it in Controls. Expect the screen to lock. This is
   the one fix I could not verify without locking your session mid-run.
2. **Fan** (§2) — open Stats. Expect a live RPM under load. Note it will read **"off"**
   when the fan is genuinely stopped, which is correct and new; it used to read "—"
   regardless. It read 0 RPM all through this session because the machine was cool.
3. **Disk** — expect "740 GB free", matching Finder.
4. **CPU tile** — expect "—" on first open rather than a confident 0%, and no jump
   from a stale average after a long close.
5. **Calendar** — if it says access is off, expect an "Open Settings" button that
   works. Revoke access while running and confirm the tab says so instead of showing
   an empty week.
6. **Mirror** — deny the camera prompt, then confirm you can still get back via "Try
   Again"/"Open Settings" without relaunching.
7. **Media waveform** — if the audio tap is denied, expect **static** bars plus a
   reason, never a bouncing fake.
8. **Tray** — delete a file that's in the shelf; expect a desaturated, badged,
   struck-through tile with Open/Reveal/AirDrop disabled.
9. **Agents** — a denied Automation grant should now say so, not "Terminal tab not
   found".
10. **Terminal** — `sleep 400 &`, quit the app, then `ps -ax | grep 'sleep 400'`.
    Expect **nothing** (this is the H21 fix; verified by probe, worth confirming live).

---

## 6 · Not done

| item | status |
|---|---|
| **Wave 5 — Servers** (H1 orphan reconciliation, H2 IPv6 `portLive`, H3 launch-failure surfacing, H4 ownership check, M9–M12) | **not started** |
| **Wave 6 — Agents** (H22 model catalog, H23 sidechain keep-alive, M20–M24) | **not started** |
| **Wave 6 — Notes re-audit** (H17, H18, M34–M36 against the rewritten file) | **not started** — C1 done (§2) |
| C4 root cause | **open** — see §3 |
| M37 break hint | deferred — blocked on the parallel TimerTab work |
| M29 PTY parsing on the main queue | deferred — SwiftTerm does not expose the queue through `LocalProcessTerminalView.init`; needs a subclass |
| §9 visual items 1–8, 12–15 | partially done via the failure-channel work (§9-2 StatTile, §9-3 Mirror actions, §9-4 Calendar, §9-5 tray badging, §9-12 fan range); 1, 6, 7, 8, 13–15 not done |

**The orphaned foglamp server (PID 1099, port 8123) is still running and untouched**,
as instructed — it remains the intended test fixture for the H1 reconciliation work.
