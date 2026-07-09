# Notchbook — Open-Source Ship Checklist

Goal: free, open-source release on GitHub. Each phase is shippable on its own;
don't gate phase 1 on phase 3.

## Phase 1 — Repo ready (an afternoon)

- [x] `git init`, `.gitignore` (.build/, Notchbook.app, *.p12, *.pem)
- [x] MIT `LICENSE`
- [ ] README overhaul for strangers:
  - [ ] Hero GIF at the top (hover → expand → media card; use QuickTime or
        `screencapture -v`), plus 3–4 stills (island ears, media, stats, tray)
  - [ ] Feature list with the **YouTube-in-Chrome integration first** — it's
        the thing the free competitors don't have
  - [ ] Requirements: Apple Silicon/Intel, macOS 13+, works without a notch
  - [ ] Install: build-from-source (`./make-app.sh`) as the primary path
  - [ ] **Permissions guide** (the #1 source of "it doesn't work" issues):
        Automation (Music/Spotify/Chrome/System Events), Camera, Calendar,
        and Chrome ▸ View ▸ Developer ▸ Allow JavaScript from Apple Events
  - [ ] Login-item setup (the LaunchAgent snippet, path made generic)
- [ ] Known-issues section (honesty builds trust):
  - Fan RPM shows "—" on some Apple Silicon machines (SMC key)
  - Brightness sliders use private frameworks (CoreBrightness /
    DisplayServices) — may break on future macOS, steppers are the fallback
  - YouTube volume requires the Chrome developer toggle
- [ ] Scrub personal bits: no hardcoded home-directory paths in code or
      docs (LaunchAgent doc should use `$HOME`)

## Phase 2 — Stranger-proofing (a weekend)

- [ ] Finish the crash/stress pass that was started (rapid hover cycles ✓;
      still to run: tab thrash + mirror start/stop cycling + media-event storm)
- [ ] Test on a non-notch external display as the only screen
- [ ] Test multi-display arrangement changes while expanded
- [ ] Fresh-user simulation: `tccutil reset All com.sensubeans.notchbook`, then
      walk every permission prompt as a new user would hit it
- [ ] First-run niceties: don't auto-query Music/Chrome at launch before the
      user has ever opened the media tab (defer first Automation prompts to
      an intentional moment)
- [ ] Graceful behavior when Chrome isn't installed at all
- [ ] An in-app way to install/remove the login item (checkbox in Controls)
      instead of hand-editing a LaunchAgent

## Phase 3 — Release mechanics

- [ ] Create public GitHub repo (`notchbook`), push `main`
- [ ] Topics: `macos`, `swift`, `swiftui`, `dynamic-island`, `notch`, `menubar`
- [ ] GitHub Release v0.1.0 with a zipped ad-hoc-signed `Notchbook.app`
      - Document the Gatekeeper dance: right-click → Open (or
        `xattr -dr com.apple.quarantine Notchbook.app`)
      - Build-from-source stays the recommended path until notarization
- [ ] Issue templates: bug (asks for macOS version + which permissions are
      granted) and feature request
- [ ] Optional later: Apple Developer account ($99/yr) → notarized releases +
      Sparkle auto-updates; only worth it if the repo gets traction

## Phase 4 — Launch (one morning, after 1–3)

- [ ] Show HN post: lead with the YouTube/Chrome media integration story
- [ ] r/macapps + r/MacOS posts with the GIF
- [ ] ProductHunt (optional; needs the GIF and 3 screenshots)
- [ ] X/Twitter thread: before/after of the notch, tag the notch-app niche
- [ ] Watch the first 48h of issues — permission problems will dominate;
      turn each one into a README FAQ entry

## Success signals to watch

- 100+ stars or a few "this replaced NotchNook for me" comments →
  demand is real; consider a paid v2 (notarized, auto-updating, settings UI)
- Mostly permission-support issues and silence → leave it as a portfolio
  piece; the README and the code still speak for you
