# Peripheral Speed — development notes

Menu-bar app (⚡) answering: how fast can data actually copy through this Mac's ports, and what's slowing it down. Owner: Chris (kurikurikun / move-ment). Built collaboratively with Claude Code, Sep 2026.

## Build & run

- `swift run` — dev build (Command Line Tools only, no Xcode project).
- CLT 27.0 (Sep 2026) ships no `libSwiftUIMacros.dylib`, so `@State` fails to expand and every SwiftUI file errors. Either install Xcode, or build against the older SDK still on disk: `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift build` (nothing is lost — deployment target is macOS 13). `make-app.sh` handles this itself: it compiles one SwiftUI line as a probe and, if that fails, walks the installed SDKs newest first until one builds.
- SwiftPM's build cache lives in `~/Library/Caches/PeripheralSpeed/build` (`--scratch-path`), never in the repo: the repo is in iCloud Drive, and a synced `.build` arrives on another Mac as thousands of cloud-only placeholders that stall the compiler for many minutes. For a manual build, pass the same `--scratch-path`.
- `./make-app.sh` — assembles PeripheralSpeed.app + `build/PeripheralSpeed-<version>.zip`. Signs with Developer ID + notarizes + staples IF the keychain has a "Developer ID Application" cert and a notarytool profile named `peripheralspeed-notary`; otherwise ad-hoc signs (then installs need the xattr quarantine command). The bundle is staged in /tmp because iCloud-synced folders re-stamp xattrs that strict codesigning rejects.
- Hidden flags: `--snapshot-about out.png` and `--snapshot-panel out.png` render those views to PNG (docs/screenshots); `--diagnostic` prints the About panel's fingerprint to stdout.

## Release ritual

1. Bump `AppInfo.version` in `Sources/PeripheralSpeed/Models.swift` (single source of truth; shown in the panel header).
2. Commit, push, `./make-app.sh`, `git tag vX.Y && git push origin vX.Y`.
3. Create a GitHub Release for the tag and attach the zip TWICE: the versioned name AND a copy named exactly `PeripheralSpeed.zip` — the move-ment.co/peripheral-speed download button uses `releases/latest/download/PeripheralSpeed.zip`, which needs that stable asset name on every release. The app checks `releases/latest` daily and shows a download row to older versions — so a GitHub Release IS the update announcement.
4. Notarized releases currently only from Chris's M1 Mac mini (cert + notary profile in its keychain, Team ID PNDN4CQY5T).

## Architecture (Sources/PeripheralSpeed/)

- `Scanner.swift` — spawns `ioreg`/`system_profiler`/`diskutil`, parses plists. Event-driven: IOKit attach/detach notifications + 60 s fallback timer (never poll faster; idle CPU must stay ~0). Also: eject, measured speed test (F_NOCACHE write/read of a temp file), diagnostic report, BSD-name mapping (walk nested USB devices, credit IOMedia to the INNERMOST device).
- `Models.swift` — Verdict, Speed (unit rules below), USBDevice/TBPort, PortInventory: per-model port database keyed by hw.model identifier.
- `Scanner.scanTBStorage` — drives inside Thunderbolt enclosures are NVMe on tunneled PCIe, not USB: found via `ioreg -c IOPCIDevice -k IOPCITunnelRootDeviceModelID` and injected as synthetic USBDevices (bus `.tbPCIe`, locationID `0x7B0000 + FNV(serial)`), same trick as the SD slot. Everything downstream — mount path, capacity, eject, gauge, activity, offload calculator — keys off bsdName/locationID and works for free.
- `Update.swift` — GitHub releases/latest check, daily.
- `App.swift` — SwiftUI MenuBarExtra. Row identity MUST derive from hardware (locationID etc.), never UUID-per-scan (breaks tooltips/hover).

## Design rules the owner converged on (do not regress)

- One unit everywhere: real-world GB/s (link Mb/s ÷10 ÷1000). Never show raw Gb/s in the UI; raw link label goes in tooltips.
- Speed numbers ONLY where data flows: drives (with "500 GB ≈ X min" ETA), free ports, degraded links. Chargers/displays/hubs = name only, gray dot. Green dot is reserved for drives at full speed.
- Layout by physical location: "On your <Mac model>" then "On your <display>". Front/back tags on M4-family minis and on the MacBook Neo (back = nearest the screen).
- Eject button sits LEFT of the drive name (next to the dot); gauge (speed test) on the right.

## Hardware facts (field-verified — the hard-won stuff)

- USB3 hubs are two hubs in one shell (fast+slow plane). Planes are merged by locationID port-nibble matching (`mergedHubRows`); a device faster than 480 Mb/s can only be on a fast port.
- Apple Silicon bus detection by root controller class: `EmbeddedUSBXHCIFL*` = USB-A ports; `*USBXHCITR` = Thunderbolt-tunneled (displays/docks); other `*USBXHCI` = built-in USB-C. One USB-C controller == one physical port.
- M4-family Mac mini: 3 back TB controllers + 1 controller carrying an internal Apple "USB3 Gen2 Hub"/"USB2 Hub" pair = the 2 front ports (same hub silicon as a Studio Display — distinguish by bus, NOT by name/vendor).
- Studio Display internals: generic Apple hubs on the tunneled bus, plus a USB device named after the display (camera/speakers) — all hidden from the UI.
- MacBook Neo (Mac17,5), field-verified Nov 2026 on the owner's Neo: no Thunderbolt, and ONE xHCI serves both ports, so "one controller == one port" does NOT hold. Back port (nearest the screen) = USB 3 10 Gb/s: fast wires on root port 2, slow wires on port 2 of an internal Apple "USB2.0 Hub" at root port 1. Front port = USB 2 only: internal hub port 1. That internal hub enumerates only while a port is in use, with a fresh kUSBContainerID each time — hide it (`internalUSB2HubPath`). `USBCPort.paths` maps locationID port-hop chains to physical ports; App's `mappedPortRows` places devices by those instead of by controller.
- One product = one row via kUSBContainerID: a USB 3 hub's slow half ("USB2.0 Hub"), fast half ("USB3.0 Hub") and its billboard chip (e.g. "Anker USB-C Hub Device", class 0x11) share one. The billboard's name becomes the hub's `productName`; generic chipset names alone read as "USB hub". Today this merge runs only on mapped ports (Neo); other Macs still use `mergedHubRows`.
- Empty ports are invisible to macOS except TB buses — free-port counts come from the model database.
- Thunderbolt drives are pinned to their port by ID, never by counting: `IOPCITunnelRootDeviceVendorID`/`ModelID` on the drive's PCI node equal the vendor/device IDs `SPThunderboltDataType` prints for that Thunderbolt device (Ash Creek = 8086:0002, Pro Display XDR = 0001:801f, Thunderbolt Display = 0001:8002). The limit: those IDs name the controller silicon, not the box, and no serial crosses the tunnel — two identical enclosures share one key, so `tbDriveAssignment` pairs them off one drive per port.
- Thunderbolt hands PCIe ~70 % of the raw link (TB3 40 Gb/s → ≈ 2.8 GB/s). Like an SD card's spec ceiling it's an "up to" — the drive inside is often slower, and the gauge is what settles it.
- Enclosure vendors report Intel's silicon codename ("Ash Creek"), never a product name, so a box holding drives is titled by what it is ("Thunderbolt 3 enclosure") with the reported name in the tooltip. `mode_key` in the XML is a localization key (`thunderbolt_three`), not the string System Information shows.
- Unknown Macs: the About panel's "Copy diagnostic info" produces the controller fingerprint needed to add a model to PortInventory. Never guess a topology; get the fingerprint.

## Distribution

- Public repo, MIT. Family/friends install from GitHub Releases (v0.17+: drag-and-open, notarized).
- Roadmap ideas parked: Sparkle true self-update, Japanese localization, drive speed history/degradation alerts, SD-slot awareness, Mac Studio + 4-port iMac topologies (need fingerprints).
