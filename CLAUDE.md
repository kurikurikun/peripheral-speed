# Peripheral Speed — development notes

Menu-bar app (⚡) answering: how fast can data actually copy through this Mac's ports, and what's slowing it down. Owner: Chris (kurikurikun / move-ment). Built collaboratively with Claude Code, Sep 2026.

## Build & run

- `swift run` — dev build (Command Line Tools only, no Xcode project).
- `./make-app.sh` — assembles PeripheralSpeed.app + `build/PeripheralSpeed-<version>.zip`. Signs with Developer ID + notarizes + staples IF the keychain has a "Developer ID Application" cert and a notarytool profile named `peripheralspeed-notary`; otherwise ad-hoc signs (then installs need the xattr quarantine command). The bundle is staged in /tmp because iCloud-synced folders re-stamp xattrs that strict codesigning rejects.
- Hidden flag: `PeripheralSpeed --snapshot-about out.png` renders the About view to PNG (docs/screenshots).

## Release ritual

1. Bump `AppInfo.version` in `Sources/PeripheralSpeed/Models.swift` (single source of truth; shown in the panel header).
2. Commit, push, `./make-app.sh`, `git tag vX.Y && git push origin vX.Y`.
3. Create a GitHub Release for the tag and attach the zip TWICE: the versioned name AND a copy named exactly `PeripheralSpeed.zip` — the move-ment.co/peripheral-speed download button uses `releases/latest/download/PeripheralSpeed.zip`, which needs that stable asset name on every release. The app checks `releases/latest` daily and shows a download row to older versions — so a GitHub Release IS the update announcement.
4. Notarized releases currently only from Chris's M1 Mac mini (cert + notary profile in its keychain, Team ID PNDN4CQY5T).

## Architecture (Sources/PeripheralSpeed/)

- `Scanner.swift` — spawns `ioreg`/`system_profiler`/`diskutil`, parses plists. Event-driven: IOKit attach/detach notifications + 60 s fallback timer (never poll faster; idle CPU must stay ~0). Also: eject, measured speed test (F_NOCACHE write/read of a temp file), diagnostic report, BSD-name mapping (walk nested USB devices, credit IOMedia to the INNERMOST device).
- `Models.swift` — Verdict, Speed (unit rules below), USBDevice/TBPort, PortInventory: per-model port database keyed by hw.model identifier.
- `Update.swift` — GitHub releases/latest check, daily.
- `App.swift` — SwiftUI MenuBarExtra. Row identity MUST derive from hardware (locationID etc.), never UUID-per-scan (breaks tooltips/hover).

## Design rules the owner converged on (do not regress)

- One unit everywhere: real-world GB/s (link Mb/s ÷10 ÷1000). Never show raw Gb/s in the UI; raw link label goes in tooltips.
- Speed numbers ONLY where data flows: drives (with "500 GB ≈ X min" ETA), free ports, degraded links. Chargers/displays/hubs = name only, gray dot. Green dot is reserved for drives at full speed.
- Layout by physical location: "On your <Mac model>" then "On your <display>". Front/back tags on M4-family minis, left/right on MacBook Neo.
- Eject button sits LEFT of the drive name (next to the dot); gauge (speed test) on the right.

## Hardware facts (field-verified — the hard-won stuff)

- USB3 hubs are two hubs in one shell (fast+slow plane). Planes are merged by locationID port-nibble matching (`mergedHubRows`); a device faster than 480 Mb/s can only be on a fast port.
- Apple Silicon bus detection by root controller class: `EmbeddedUSBXHCIFL*` = USB-A ports; `*USBXHCITR` = Thunderbolt-tunneled (displays/docks); other `*USBXHCI` = built-in USB-C. One USB-C controller == one physical port.
- M4-family Mac mini: 3 back TB controllers + 1 controller carrying an internal Apple "USB3 Gen2 Hub"/"USB2 Hub" pair = the 2 front ports (same hub silicon as a Studio Display — distinguish by bus, NOT by name/vendor).
- Studio Display internals: generic Apple hubs on the tunneled bus, plus a USB device named after the display (camera/speakers) — all hidden from the UI.
- MacBook Neo (Mac17,5): no Thunderbolt; left port USB3 10 Gb/s, right port USB-2 only. PortInventory.usbCPorts drives per-port labels.
- Empty ports are invisible to macOS except TB buses — free-port counts come from the model database.
- Unknown Macs: the About panel's "Copy diagnostic info" produces the controller fingerprint needed to add a model to PortInventory. Never guess a topology; get the fingerprint.

## Distribution

- Public repo, MIT. Family/friends install from GitHub Releases (v0.17+: drag-and-open, notarized).
- Roadmap ideas parked: Sparkle true self-update, Japanese localization, drive speed history/degradation alerts, SD-slot awareness, Mac Studio + 4-port iMac topologies (need fingerprints).
