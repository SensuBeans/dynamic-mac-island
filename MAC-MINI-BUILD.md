# Mac mini build — LOCAL ONLY, DO NOT PUSH

This branch (`mac-mini-build`) is the bespoke port of the Dynamic Island for a
**Mac mini driving an external display** — a machine with no physical notch.

`main` targets notched MacBooks. Do not merge this branch into `main`, and do
not push it to `origin` (github.com/SensuBeans/dynamic-mac-island). It exists
only on this machine.

## How it differs from `main`

- **No notch to hug.** `NotchMetrics.hasNotch` is false on this hardware, so the
  island renders as a small free-floating pill centered in the menu bar instead
  of a shape that hugs a physical notch silhouette.
- **Menu-bar-relative placement.** `pillDrop` centers the standby pill within the
  menu bar, with a separate offset for the low-DPI (non-retina) 1080p panel,
  which renders everything larger.
- **Pill media mode.** A compact now-playing pill (album art + live waveform)
  replaces the notch "ears" layout.
- **Signing check.** `make-app.sh` looks for the "Notchbook Signing" cert with
  `security find-certificate` rather than `find-identity`, which did not match a
  self-signed cert on this machine.

## Permissions this build depends on

The app holds **Accessibility** and **Apple Events / Automation** grants, which
are powerful (Accessibility can read and drive the UI of every app). Two things
keep that safe and must be preserved:

1. `make-app.sh` signs with the stable "Notchbook Signing" cert so TCC grants
   survive rebuilds. Losing that identity means re-granting permissions.
2. **Never interpolate track metadata into AppleScript source.** Every script the
   app builds interpolates only enum `rawValue`s, `Int`s, and `Bool`s. A track or
   album title containing a quote would otherwise be able to inject AppleScript.
   This is why `openMusicLibrary` looks the playing track up by *database ID*
   rather than by album name.
