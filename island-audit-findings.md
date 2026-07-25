# Dynamic Island — Empirical Audit Findings

**Build audited:** `origin/main` @ `13b0798` ("Bottom nav: full identical choreography…").
**Method:** 11 hunter agents fanned per subsystem/lens, each finding adversarially
verified by an independent skeptic; pixel reproductions done in the main loop with
`-LiquidNavFreeze` + full-resolution `screencapture` + column-brightness analysis.
Music playback was **not** disturbed (user's queue left running), so music-dependent
repros are code-reasoned and flagged for the fix session to reproduce.

> ### ⚠️ Read this first — the checkout was stale
> The working tree started at `19b4feb`, **8 commits behind `origin/main`** (0 ahead,
> clean). Those 8 missing commits are the *entire architecture this audit targets*:
> `EarRevealModel` single-owner state machine (`b64f979`), settled-signal LOCKSTEP
> (`e92f8f8`), and **bottom nav as the default** (`4e12df5`→`13b0798`). The first
> build + workflow ran against the old code and were discarded. The tree was
> fast-forwarded to `origin/main` (safe: 0 ahead, clean, fix session still polling),
> rebuilt, and the whole audit re-run. **Everything below is against `13b0798`.**
> Note also: an orphan pref `general.navAtBottom=1` existed on disk before the
> feature's key existed in the old checkout — a red herring that confirmed the drift.

> ### Coverage caveat — 7 verifiers hit the session limit
> The adversarial-verify pass for the **nav-geometry, agent-pill, and close-morph**
> hunters failed (`session limit · resets 12:20am`). Those findings are recovered
> from the hunt phase but are **UNVERIFIED code-reasoning** — each is tagged
> `[UNVERIFIED]` below. Treat them as SUSPECTED with no second opinion; the fix
> session should reproduce before trusting.

---

## CONFIRMED (reproduced in pixels)

### C1 · Bottom-nav capsule is under-width — pin/settings/power float ~75 pt outside its right edge · **HIGH**
*(Known symptom #1. Reproduced in pixels by this session; the nav hunter did **not**
find it — the code reads "correct" because the width probe measures the full row, so
only the pixel test exposes the clamp. This is the headline finding.)*

**Evidence (pixels).** `-LiquidNavFreeze 1.0`, screen 1512×982 logical, notch center 756.
Full-res capture + PIL column-brightness scan of the settled nav bar:
- Glass capsule fill (luma ~24): logical **x540 → x900**, width **360 pt**, center **720**.
- Full control row (tabs + pin + gear + power): **x540 → x975**, width **435 pt**, center **757** (= notch center).
- pin/gear/power icons sit at **x~908–975** on bare desktop (luma ~14) — **~75 pt past** the capsule's rounded right edge.
- Capsule center **720** is **~37 pt LEFT** of the control-row/notch center 757.
- **TOP mode is identical** (capsule right edge also x≈900) — the "exact mirror geometry"
  commit makes both modes share the bug; it is *not* milder in top mode.
- Screenshots: `scratchpad/nav-bottom-capsule.png`, `nav-fullstrip.png`, `nav-top-capsule.png`.

**Mechanism.** `NotchView.swift:1075`
`let navBlobW = min(metrics.expandedSize().width - 16, navBarWidth + 22)`.
The capsule width is **clamped to the standard panel width** (`expandedSize().width - 16`),
but the control row — `navControls()` = tabBar + pin + gear + power (`NotchView.swift:1272-1310`)
— is *wider* than that panel. The `min()` clamp wins, so the capsule cannot grow to
enclose the trailing controls and they overflow past its right edge. The comment at
`1071-1074` states the intent (clamp so the capsule can't vary between a wide page (620)
and a standard one (460)) — but that clamp is exactly what truncates the capsule below
the control-row width. Note `navWidthProbe` (`NotchView.swift:1252`) *does* measure the
full row including pin/gear/power, so `navBarWidth` is ~right; it is the `min()` against
panel width that discards it. The apparent ~37 pt left-shift is a consequence: the row is
notch-centered and the capsule shares its left origin but is too short.

**Fix direction.** Size the capsule to the measured control-row width (`navBarWidth` +
breathing room), not clamped to the standard panel width — widen the constant canvas
world to fit the widest reachable control set. Keep the "constant across pages" property
by clamping to the widest *control row*, not the panel, and center capsule and row on the
same axis. (The canvas world is framed to the standard panel width at `NotchView.swift:1083+`
— that frame must also widen.)

---

## SUSPECTED (code-reasoned; adversarially verified except where tagged `[UNVERIFIED]`)

Ranked by user impact. "Verify: X" is the adversarial verifier's verdict.

### S1 · Hide-goo plays over a full-width opaque bar when music stops with the pomodoro countdown ear on · **MEDIUM** · Verify: CONFIRMED
*(Known symptom #2a.)* `NotchView.swift:314`
**Mechanism.** The backing's visibility/width key on `hasMedia = showMediaEar ||
(pomodoro.isRunning && settings.timerCountdownEar)` (`262-263`, `280`, `308`, `310`), but
the backing's opacity relay is `.opacity(showMediaEar ? smoothstep(0.9,1,e) : 1)` (`314`).
When music stops while the countdown ear is on, `showMediaEar` flips false and `earT`
drives the LiquidEar shrink goo (`322-337`), but `hasMedia` stays true (pomodoro term), so
the opacity takes the `else` branch = constant 1: the goo retracts against a static
full-width opaque black bar that never recedes. Verifier's refinement: the **rising edge
is the more visible artifact** — music starting while the countdown bar shows makes
`showMediaEar` flip true with `earT≈0`, so `314` jumps opacity 1→`smoothstep(0.9,1,~0)`=0
in one frame; the countdown bar blinks out, then the ear buds from a bare notch.
**Repro.** Settings → *Countdown in island ear*, start a pomodoro; start music (ear
reveals over countdown); stop the player → watch the 0.55 s hide. Reverse for the blink.
**Fix direction.** Gate the backing opacity/visibility on the same settled media signal
the goo uses (`showMediaEar`/`earT`); make the pomodoro-countdown backing its own branch
decoupled from the media-ear morph.

### S2 · Stale-artwork cluster on track flips — new title paired with previous cover · **MEDIUM** · Verify: CONFIRMED (×3) / medium
*(Known symptom #2b + #4 raw-state.)* A family of the same root cause — `media.artwork`
publishes asynchronously (after `nowPlaying`) and is never cleared on a track change, while
several view sites read it raw or via an independently-updated latch:
- **`NotchView.swift:766`** — collapsed ear content: title via `media.nowPlaying ??
  lastNowPlaying`, art via `media.artwork ?? lastArtwork`; the two latches (`573`/`576`) are
  written independently, never as one atomic bundle → on a fast flip the ear title swaps
  instantly while the thumbnail lags on the old cover. *(MEDIUM, CONFIRMED)*
- **`NotchView.swift:843`** — track-change toast reads `media.artwork ?? lastArtwork` at
  render while the toast fires off the `nowPlaying` edge → toast shows new title + old
  cover until decode. *(LOW, CONFIRMED)*
- **`EarRevealModel.swift:46`** — reveal gate checks only `art != nil`, so a lingering
  previous-track image satisfies the artwork budget and a fresh reveal fires showing the
  wrong art; the `?? lastArtwork` latches are never reset, so a genuinely art-less track
  displays the prior cover indefinitely. *(MEDIUM, CONFIRMED/medium)*
- **`MediaWatcher.swift:461`** — Spotify artwork commit guards only `artworkKey == key`,
  never that the fetched art belongs to the current title (the Music path deliberately
  guards `returnedName == title`); on scripting lag the previous cover sticks under the
  new key with no correction path. *(MEDIUM, CONFIRMED/medium)*
**Fix direction.** Latch `nowPlaying`+`artwork` as one bundle updated only when a complete,
track-matched pair is settled; render that bundle everywhere (ear, toast, pill). Make the
reveal art-gate track-aware (compare `artworkKey` to the current track) and clear/reset
artwork on a track change. Add the `returnedName == title` identity guard to the Spotify path.

### S3 · Spotify artwork fetch blocks the main thread on every track change · **MEDIUM** · Verify: CONFIRMED
`MediaWatcher.swift:453` — `handle()` runs on `.main` and calls `runAppleScript()`
(`NSAppleScript.executeAndReturnError`, a synchronous Apple-Event round-trip to Spotify) on
the **main thread**, on every Spotify track flip — precisely when the ear/pill choreography
is animating. The code's own comments (`90-92`) note NSAppleScript is main-thread-only and
blocks the UI; the Music artwork path was already moved off-thread (`480-483`) for this
reason. A slow/busy Spotify stalls the island for the round-trip → dropped animation frames.
**Fix direction.** Move the Spotify artwork-URL read onto `scriptQueue`/async like the Music
path; hop back to main only to assign `artwork`.

### S4 · Hover rect trails the springing island on SHRINK → panel collapses under the cursor · **MEDIUM** · Verify: CONFIRMED (×2)
Two facets of one LOCKSTEP gap:
- **`AppDelegate.swift:984`** (hug tabs) and **`AppDelegate.swift:123`** (general) —
  `islandRect()` is re-read live on every `mouseMoved` and returns the **endpoint** size
  (`state.tabHugHeight`, `mirror.wantsRunning`, etc.), while the rendered frame animates to
  those values over a ~0.3 s spring (`NotchView.swift:501/506`). On a size **decrease** the
  rect snaps small immediately while the panel is still rendered large; the still-visible
  bottom band lies outside the rect (only inset −6 pt, `985`) and the collapse guard
  (`1029-1031`) fires under the cursor. Growth is safe; only shrink misfires.
**Repro.** Agents/Servers with several rows; hover a lower row; remove a server row (or a
session ends → row count drops) and nudge the mouse during the down-spring. Or stop a live
Mirror (620×470 → standard) while the cursor rests in the lower half.
**Fix direction.** Drive the collapse hit-test from an animation-tracked height following
the same spring (or hold the rect at max(old,new) / add a transient inset while
`tabHugHeight` settles) so the hover rect never trails the render on shrink.

### S5 · Hug tabs dip to the 120 pt floor on mount before springing to real height · **MEDIUM** · Verify: CONFIRMED/medium
`AgentsTab.swift:46` / `ServersTab.swift:42` — `naturalHeight` is computed from `@State`
measurement vars that start at **0**, so the first `TabHugHeightKey` preference fires with
~0 *before* the GeometryReader `onAppear`s land real heights. `hugSize` maps that to
`max(120, …)` = the floor; a second pass delivers the true height. Because the height is
spring-animated (`NotchView.swift:501`), the panel visibly springs cap→120→real. The
`natural == nil ⇒ cap` guard is defeated — the first non-nil value *is* the tiny one.
**Fix direction.** Suppress the pre-measurement preference (report `nil`/omit until both
GeometryReaders have reported, or seed the vars) so the first published height is the cap
or the real content height, never the transient floor.

### S6 · Bottom-nav close: the nav-melt beat is spatially orphaned from the panel-into-notch collapse · **MEDIUM** · `[UNVERIFIED]`
`NotchView.swift:438` — LiquidClose has no bottom-mode variant: its geometry converges to
the hardware notch at the **top** (`LiquidClose.swift:65-77`) and its canvas spans only
notch→panel-bottom (`1156-1159`). In bottom mode the nav capsule is anchored *below* the
panel and melts via `navT→0` with no coupling to `closeT`. So on collapse the panel flies
up into the notch while the bottom capsule melts in place far below — a visibly growing gap
instead of one continuous Surface Return. Top mode reads continuous because the nav sits
between notch and panel.
**Repro.** `navAtBottom=true`, expand, hover bottom edge to reveal nav, collapse.
**Fix direction.** Give the bottom-nav close a beat that carries the melting capsule toward
the departing panel, or couple the `navT` melt to `closeT`.

### S7 · Agent-pill goo target rest-rect is read LIVE (not latched) — capsule teleports mid-bud when the media ear toggles · **MEDIUM** · `[UNVERIFIED]`
`NotchView.swift:352` — the goo host latches the **donor** side (`hasEar: agentEarLatch`
`351`, `withMedia: agentEarLatch` `357`, captured once at the reveal edge, `586`) but feeds
the **target** side live: `pillRect: agentPillFrame` (live `@State` from the label's
GeometryReader). `agentPillFrame` tracks the HStack, and the `ears` view mounts on
`showMediaEar || earLinger` (`743`); if that flips during the ~0.6 s bud (music starts, or
`earLinger` lapses), the row reflows, `agentPillFrame` jumps, and the flying capsule re-aims
mid-flight while the donor stays pinned — the exact teleport the donor latch was added to
prevent, left uncorrected on the target side.
**Fix direction.** Snapshot `agentPillFrame` into a companion `@State` at the reveal edge
(alongside `agentEarLatch`) and feed the latched rect to the goo.

### S8 · Agent-pill crisp label unmounts instantly on disappear (endpoint read) — pop/blank beat instead of a crisp→goo handoff · **MEDIUM** · `[UNVERIFIED]`
`NotchView.swift:891` — `agentPill` is evaluated in `body`, not inside a relay; its mount
condition `showAgentPill || renderAgentT > 0.001` reads `renderAgentT` (a `@State` set in
`withAnimation`) as the **endpoint**. On disappear the OR-clause (whose comment says "mounted
through the whole morph including the disappear leg") is dead → the crisp label unmounts at
frame 0 while the goo layer only mounts for `e ∈ (0.02, 0.999)`, leaving a brief blank beat,
then an empty capsule melts. The ear avoids this with the separate `earLinger` `@State` latch.
**Fix direction.** Mount the label inside the `NavTDriven` relay (like the ear at `322`) or
add an `agentLinger` latch mirroring `earLinger`.

### S9 · Auto-resume consumes the epoch BEFORE re-checking guards → a transient guard failure permanently cancels the resume · **MEDIUM** · Verify: PLAUSIBLE/low
`AgentSessionsModel.swift:819` — `fireDueResumes()` removes the arm and inserts the epoch
into `consumedEpochs` (`819-820`) *before* `fireOne()` (`822`) re-validates guards. On a
**transient** guard failure (`guard-busy` `839`, or transcript parser momentarily nil while
the file is rewritten `848-852`) `fireOne` returns without firing or re-arming, but the epoch
is already consumed, so `evaluateArming`'s `consumedEpochs.contains(...)` (`743`) blocks any
re-arm for the whole 5-hour window — the resume is lost though the next 1.5 s tick would have
cleared the condition. *(Verifier lowered confidence — treat as a real but not-fully-proven
race; reproduce via the log before fixing.)*
**Fix direction.** Consume the epoch only when the resume actually fires; on a transient
failure leave the arm live so a later tick retries, distinguishing transient (busy /
parser-missing) from terminal (pid dead / manual resume).

### S10 · Nav capsule drop-shadow casts *upward* in bottom mode · **LOW** · `[UNVERIFIED]`
`NotchView.swift:430` — bottom mode wraps `liquidNavLayer` in `.scaleEffect(y: -1)`, which
mirrors the two baked drop shadows (`1120`, `1129`, `y: 5`) to `y: -5`. The capsule casts its
shadow up (into the panel) while the panel's own shadow (`1212`, `y: 8`, outside the flipped
subtree) casts down — physically inconsistent in the default mode.
**Fix direction.** Apply the two nav `.shadow`s outside the flipped subtree, or negate their
`y` when `navAtBottom`.

### S11 · Live/zoomed Mirror snaps to standard size at the first frame of the close morph · **LOW** · `[UNVERIFIED]`
`NotchView.swift:1155` — `collapse()` synchronously sets `mirror.wantsRunning=false` and
`state.mirrorBig=false` *before* the morph starts (`AppDelegate.swift:826,829`), so
`expandedSize`'s `mirrorLive` flips false and reverts to standard size; `liquidCloseLayer`
captures that smaller `panel` and the Surface Return begins from the standard rect, not the
zoomed one on screen → a size snap at collapse start.
**Fix direction.** Latch the expanded panel size at collapse start (or defer the
`wantsRunning`/`mirrorBig` reset until the morph completes).

### S12 · `classify()` can wedge the working pill on indefinitely · **LOW** · `[UNVERIFIED]`
`AgentSessionsModel.swift:1397` — a last assistant message with `stop_reason != end_turn`
returns `.working` with **no age check** (unlike the user-last and end_turn branches).
`resolveState` normally rescues via `meta.status == idle`, but a live process whose
statusline keeps reporting `busy` (hung turn, or stale `<pid>.json` whose pid is reused)
keeps `.working` forever — a permanently lit pill with no self-healing timeout.
**Fix direction.** Apply an `idleMax` drop to the non-`end_turn` assistant path, or age-out a
`busy` status not refreshed within a bound.

### S13 · `consumedEpochs` grows unbounded at runtime · **LOW** · Verify: CONFIRMED
`AgentSessionsModel.swift:332` — pruned of expired windows only in `restoreResumeState()` at
launch; during a long run it only ever gains entries (settings-off explicitly does not clear
it), bloating memory and the persisted `consumed` array on every write.
**Fix direction.** Prune expired epochs on each `evaluateArming` tick (same predicate launch
already uses).

### S14 · Expanded-panel `allowsHitTesting` gate is dead on open · **LOW** · Verify: CONFIRMED
`NotchView.swift:469` — `.allowsHitTesting(state.isExpanded && renderCloseT < 0.05)` reads
`renderCloseT` in `body` (endpoint). On open, `closeT`'s target is 0 so the term is true from
frame 0 — hit testing is enabled for the entire 0.70 s open morph, defeating the "gated to
rest" intent; the `< 0.05` term never gates anything.
**Fix direction.** Gate through the close relay (derive from an Animatable `e`) or use
`state.isExpanded` alone, since the body read can't observe mid-morph.

### S15 · Agent-pill state-change spring guard reads an endpoint — active throughout appear · **LOW** · Verify: CONFIRMED
`NotchView.swift:920` — `.animation(renderAgentT > 0.99 ? .spring : nil, value: pill)` reads
`renderAgentT` in `body`. On appear the endpoint is 1, so the spring is enabled for the whole
appear morph; the guard (meant to suppress the spring "while the liquid morph runs" to avoid a
double-open) only holds on the disappear leg. A pill value change coincident with appear/re-bud
springs the label while the goo buds. *(Found independently by both the agent-pill and
cross-cutting-relay hunters.)*
**Fix direction.** Read morph progress inside the relay (or a settled boolean set once
`agentT` reaches rest).

### S16 · `AudioSpectrum.start()` partial-failure paths leave `active = true`, wedging future activations · **LOW** · Verify: CONFIRMED
`AudioSpectrum.swift:54` — `setActive()` sets `active = on` *before* `start()`, and several
`start()` early-returns (`48`, `54`, `66-69`) don't reset it (only the `AudioDeviceStart`
path does, `85`). After any partial failure a later `setActive(true)` no-ops via the
`on != active` guard (`42`), so the live waveform can never retry and stays on the synthetic
fallback until the tab hides.
**Fix direction.** Set `active = false` on every `start()` failure path, or only set true
after `start()` fully succeeds.

### S17 · Servers tab — three low-severity state issues · **LOW** · Verify: CONFIRMED/medium/low
- **`ServersModel.swift:90`** — `setPolling(false)` invalidates the timer but doesn't bump
  `generation`, so an in-flight completion still mutates published state after the tab hides;
  a late failure sets `reachable=false` and flashes "Local Starter isn't running" on re-show.
  *(CONFIRMED/medium)*
- **`ServersTab.swift:247`** — the favorite button calls a server-side *toggle* against a
  possibly-stale rendered star (start/stop deliberately use explicit endpoints to avoid exactly
  this stale-state inversion). *(CONFIRMED/low)*
- **`ServersModel.swift:176`** — a `running:true` entry whose port fell back to `0` builds
  `http://host:0` and silently fails to open, with no user feedback. *(PLAUSIBLE/low)*
**Fix direction.** Bump `generation` in `setPolling(false)`; use explicit favorite/unfavorite
endpoints; guard `open()` on `port > 0` and mark port-0 rows un-openable.

---

## USER-VERIFY (needs a human gesture / eye — cannot be settled from code or automated capture)

- **U1 · Bottom-edge hover stay/enter hysteresis feel** *(known symptom #3)* — whether the
  reveal/stay thresholds at the island's bottom edge feel right (no flicker on grazing, no
  dead zone) is a tactile judgment; cursor injection is disallowed. Have the user hover the
  bottom edge slowly in and out and report flicker/stickiness.
- **U2 · The S1 pomodoro-goo and S6 bottom-close orphan in motion** — code-confirmed, but the
  *visual severity* (how objectionable the opaque-bar hide / the melt gap looks) is best judged
  by eye. One-step for the user: enable *Countdown in island ear*, run a pomodoro, play then
  stop music (U2a); and reveal+collapse the bottom nav (U2b).
- **U3 · Fast-track-flip artwork lag (S2)** — reproducing needs rapid Music/Spotify skips
  (disturbs the queue); left to the fix session with the user's consent. Watch the ear
  thumbnail vs the title on back-to-back skips.

---

## Considered and REJECTED by adversarial verification (recorded for the fix session)

- `AppDelegate.swift:110` — "close-morph expanded/collapsed selector not mirrored." Rejected:
  `collapse()` stops the mouse-watch during the morph, so the drift is unreachable in practice
  (the ear-hover branch it could touch is held at opacity 0 by `morphHoldExpanded`).
- `AgentSessionsModel.swift:801` — "empty-due one-shot timer never rescheduled (silent
  missed-fire)." Rejected by the verifier; the reschedule path recomputes on the next rebuild
  tick. *(Low residual risk under wall-clock skew — noted, not asserted.)*
- `ServersModel.swift:17` — "name-only identity, duplicate names collide." Rejected: the
  whole API is name-keyed, implying the Starter enforces unique names (duplicates unreachable).
- `ServersTab.swift:18` — "naturalHeight collapses to ~8 pt on first open." Rejected as a
  near-duplicate of S5 (`AgentsTab.swift:46`), which the verifier kept as the canonical form.

---

## Coverage note — what was NOT examined

- **Pixels:** only symptom #1 (nav) was reproduced in pixels this session. All other visual
  findings are code-reasoned or await a gesture; the user's music queue was deliberately left
  running, so music-transition and pomodoro-ear repros (S1, S2, S3, U2, U3) were not driven.
- **Unverified findings:** S6, S7, S8, S10, S11, S12 and half of S15 lost their adversarial
  verifier to the session limit — single-source code reasoning only.
- **Interaction/feel:** hover hysteresis, settings swipe-out, tab swipes, parked-mode drag,
  and the close-morph *feel* were not exercised (no cursor injection) — see U1.
- **Live subsystems not driven:** real multi-session agent pill with live Claude sessions,
  actual auto-resume firing (log-trace only, not triggered), the Mirror camera, and the
  external `localhost:7780` Local Starter API server itself.
- **Subsystems not audited in depth:** Calendar, Notes/NotesSync, Stats, Toggles, Tray/Files,
  Lyrics rendering, TerminalTab/TerminalSessions, AudioOutput routing, and the SettingsViews UI
  were only lightly touched by the cross-cutting sweep — no dedicated hunter.
- **Not built/run under sanitizers or with Instruments** — no memory/leak/CPU profiling; the
  timer-leak and unbounded-set findings (S13, S16) are static-only.

<!-- AUDIT COMPLETE -->

---

## Fix pass — 2026-07-19 (Opus, regular session)

One commit per finding, pushed to `main` as SensuBeans. A parallel terminal
landed `5bb213b` (auto-resume cancel-grace) mid-pass, between C1 and S9; all
subsequent fixes build on top of it (every build compiled with it present).
Every change was `./make-app.sh`-built and the app relaunched flag-free on the
final build (ps-verified pid running `MacOS/Notchbook`). Prefs disturbed for
pixel repro (`general.navAtBottom`) restored to the user default (bottom);
no freeze/debug keys persisted.

### CONFIRMED
- **C1 — NOT REPRODUCED as stated; real issue fixed instead** (`5cf1cb1`).
  Red-tint capture (top + bottom modes, `-LiquidNavFreeze 1.0`) proved the glass
  capsule (`navBlobW=444`, centered at the notch) already **encloses** the
  tab-bar, pin, gear, and power with margin — the audit's column-brightness scan
  mismeasured the tab-bar's own inner pill (`Capsule().fill(.white.opacity(0.06))`,
  ends at the toggles icon) as the capsule edge. The capsule is not under-width.
  The real defect (confirmed with the user): the nav glass capsule was the lone
  frosted island rendered WITHOUT the `.14` white hairline rim the toast/badge/
  panel all carry, so its dark fill read as invisible and pin/gear/power looked
  orphaned. Added the rim; verified before/after in pixels (`nav_beforeafter.png`).

### FIXED (code-verified; music/gesture severity on USER-VERIFY)
- **S1** (`9464499`) — backing opacity now `max(media-ear reveal, pomodoro
  presence)`, decoupling the countdown bar from the media-ear morph (kills the
  rising-edge blink; countdown bar no longer pins/blinks). Normal media verified
  identical in pixels (no pomodoro ⇒ `max(smoothstep,0)≡smoothstep`).
- **S2** (`b62652b`) — MediaWatcher clears `artwork` on track change (root fix);
  NotchView latch resets `lastArtwork` on track change (churn protection kept);
  Spotify reads name+url together with a `returnedName==title` guard. Stable-track
  rendering verified unchanged (art persists).
- **S3** (`6c5a3f5`) — Spotify artwork URL read moved off the main thread via
  `runScriptAsync`; assigns back on main with an `artworkKey==key` guard.
- **S4** (`4b6e1b9`) — collapse hit-test rect held at recent max through the
  shrink spring (`collapseRect`, 0.4 s), so it never trails the render on shrink.
  Logic traced (grow→stable→shrink-hold→settle→adopt).
- **S5** (`0c13001`) — Agents/Servers `naturalHeight` optional, nil until both
  GeometryReaders report, so `hugSize` holds the cap instead of flooring to 120.
- **S9** (`8a8bd5e`) — `fireOne` returns `.fired/.transient/.terminal`; the epoch
  is consumed only on a definitive outcome, with a bounded retry backoff
  (10 s) + give-up (300 s) for transient busy/parser-nil. New `autoresume.log`
  markers make it observable.
- **S12** (`7c4ddc8`) — `classify` mid-turn ages out past `idleMax`; `resolveState`
  only trusts `busy` while `age < idleMax`, so a hung/stale busy self-heals.
- **S13** (`0e2fd73`) — `consumedEpochs` pruned every arming tick, not only at launch.
- **S14** (`4f5ff68`) — expanded-panel hit-testing gated on `state.isExpanded`
  alone; the `renderCloseT < 0.05` term was provably dead (endpoint read +
  isExpanded flips at close start). Behavior-identical.
- **S15** (`dc91693`) — agent-pill label spring gated on a new `agentSettled` flag
  (set on morph completion), not the `renderAgentT` endpoint. No more spring
  through the appear morph.
- **S16** (`aa33a96`) — `AudioSpectrum.active` set true only after `start()` fully
  succeeds, so a partial-failure path can't wedge future activations.
- **S17** (`8797c08`, **2 of 3**) — `setPolling` bumps `generation` (in-flight
  completions drop stale); `open()`/row guarded on `port > 0`. **S17b DEFERRED**:
  the Local Starter exposes only a toggle `/api/favorite` (verified in
  `server.py:308`), so an explicit favorite/unfavorite needs a cross-repo server
  change + Starter restart — disproportionate for a path where favorite state,
  unlike `running`, never changes autonomously.

### FIXED — UNVERIFIED in audit, mechanism confirmed by reading (verify by eye)
- **S7** (`f0674c9`) — agent-pill goo target rect frozen per-reveal
  (`agentPillFrameLatch`) so a mid-flight row reflow can't re-aim the capsule.
- **S8** (`f8b06af`) — `agentLinger` latch keeps the crisp label mounted through
  the disappear leg (mirrors `earLinger`); no blank beat.
- **S10** (`b95fbfc`) — nav capsule shadow `y` negated in bottom mode so it casts
  down (the layer flip was mirroring it upward).
- **S11** (`914cc5f`) — panel size latched at collapse start (`state.closePanelSize`)
  so a zoomed Mirror's Surface Return doesn't start from the reverted standard rect.

### DEFERRED
- **S6 — bottom-nav close orphan** [UNVERIFIED]. Mechanism confirmed by reading:
  the bottom-mode `navOffsetY` pins the nav at the original panel-bottom, and
  neither the nav goo nor the crisp controls sit inside a `closeT` relay, so on
  collapse the panel climbs (Surface Return) while the nav melts in place below —
  a growing gap. NOT fixed: the fix (wrap the nav offset in a `closeT` relay and
  match the panel's nonlinear climb) is a real choreography change to a WORKING
  morph, and there is no combined `closeT`+`navT` freeze harness to tune it
  statically — verifying needs a slowed bottom-nav-close recording (a human
  gesture: hover the bottom edge to reveal the nav, then collapse). Shipping it
  blind risks regressing the working close, so it is left for a session that can
  build the harness / capture the recording.
- **S17b** — see S17 above.

### USER-VERIFY (need a human gesture / eye)
- **U1** — bottom-edge hover stay/enter hysteresis feel (audit; untouched). Hover
  the bottom edge slowly in/out; report flicker or dead-zone.
- **U2** — S1 pomodoro-goo transition + S6 bottom-close gap, in motion. Enable
  *Countdown in island ear*, run a pomodoro, then play → stop music (watch the
  bar); and reveal + collapse the bottom nav (the S6 gap).
- **U3** — S2 fast-track-flip artwork. Skip Music/Spotify back-to-back; watch the
  ear thumbnail vs the title (should never show a new title over the old cover;
  a brief placeholder is expected instead).
- **S4** — nudge the mouse during a down-spring (remove a server/agents row, or
  stop a live Mirror, with the cursor in the lower half); the panel must not
  collapse under the cursor.
- **S7** — trigger an agent pill reveal coincident with a music start/stop; the
  budding capsule must not teleport.
- **S8** — let an agent pill disappear; watch for a crisp→goo handoff (no blank
  beat, no empty capsule).
- **S10** — in bottom mode, eyeball the nav capsule's drop shadow (should fall
  downward, away from the panel).
- **S11** — open Mirror, zoom it, then collapse; the Surface Return must start
  from the zoomed size (no snap to standard at the first frame).
- **S9** — auto-resume: confirm via `autoresume.log` that a transient
  `fire-retry guard-busy` / `fire-retry guard-parser` is later followed by a
  `fire` (not a permanent skip), and `fire-giveup transient-elapsed` bounds it.

<!-- FIX PASS COMPLETE -->
