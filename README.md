# PeripheralSpeed — menu-bar app MVP

The app version of `peripheral-speed/speedcheck.py`: a menu-bar item that
watches every USB / Thunderbolt link and turns red the moment a drive is
stuck on a slow cable. Same detection logic the script field-validated
(2026-09-05, see `../peripheral-speed/APP_ROADMAP.md`).

## Run it (no Xcode project needed — just Command Line Tools)

```bash
cd PeripheralSpeedApp
swift run
```

A ⚡ appears in the menu bar. Click it:

- Every USB device with its negotiated speed — green / yellow / red dot.
- Drives are labeled `· drive`, hubs `· hub`.
- A drive on a USB-2 link goes red with the fix spelled out under it.
- Thunderbolt/USB4 ports with link speed; 20 Gb/s links flagged yellow.
- Re-scans every 5 seconds, so plugging/unplugging updates by itself.
- The menu-bar icon switches to ⚠️ whenever a bottleneck exists.

To install it semi-permanently:

```bash
swift build -c release
cp .build/release/PeripheralSpeed /Applications/PeripheralSpeed
open /Applications/PeripheralSpeed
```

(Real .app bundle + login item + notarization come later.)

## Architecture notes

- `Scanner.swift` shells out to `ioreg` (IOKit registry) for USB and
  `system_profiler -xml` for Thunderbolt — the exact plumbing the Python
  prototype proved reliable when `system_profiler`'s USB reporting wedged.
- v1 should replace the `ioreg` subprocess with the IOKit C API +
  `IOServiceAddMatchingNotification`, giving instant plug/unplug events
  instead of 5-second polling. The parsing/verdict logic stays identical.

## Backlog (from APP_ROADMAP.md)

1. IOKit notifications (instant updates, no polling)
2. One-click drive benchmark + cable A/B compare
3. Offload ETA in footage terms ("128 GB card: 54 min → 4 min")
4. Recommended-cable link on every red flag (affiliate)
5. .app bundle, icon, notarized direct download
