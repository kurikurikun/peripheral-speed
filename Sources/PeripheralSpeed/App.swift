import SwiftUI
import AppKit
import ServiceManagement

@main
struct PeripheralSpeedApp: App {
    @StateObject private var scanner = PeripheralScanner()
    @StateObject private var updates = UpdateChecker()

    init() {
        // dev tool: render the About view to a PNG and exit
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot-about"), i + 1 < args.count {
            Self.snapshotAbout(to: args[i + 1])
            exit(0)
        }
        if let i = args.firstIndex(of: "--set-login-item"), i + 1 < args.count {
            // dev/test hook: on | off | status
            switch args[i + 1] {
            case "on":
                do { try SMAppService.mainApp.register(); print("login item enabled") }
                catch { print("failed: \(error)"); exit(1) }
            case "off":
                do { try SMAppService.mainApp.unregister(); print("login item disabled") }
                catch { print("failed: \(error)"); exit(1) }
            default:
                print(SMAppService.mainApp.status == .enabled ? "enabled" : "not enabled")
            }
            exit(0)
        }
        if args.contains("--install-update") {
            // dev/test hook: run the full self-update synchronously
            if let err = UpdateChecker.performUpdate() {
                print("update failed: \(err)")
                exit(1)
            }
            print("update installed, new version launched")
            exit(0)
        }
        if let i = args.firstIndex(of: "--snapshot-panel"), i + 1 < args.count {
            Self.snapshotPanel(to: args[i + 1])
            exit(0)
        }
        // Start-at-login defaults ON, set exactly once at first launch —
        // the footer checkbox stays in charge afterward, and macOS posts
        // its own "added as login item" notice so nothing is hidden.
        // Only for the installed copy, never for dev builds.
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "didDefaultLoginItem"),
           Bundle.main.bundlePath == "/Applications/PeripheralSpeed.app" {
            defaults.set(true, forKey: "didDefaultLoginItem")
            if SMAppService.mainApp.status != .enabled {
                try? SMAppService.mainApp.register()
            }
        }
        // menu-bar only: no Dock icon, no app switcher entry
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    /// Render the live panel (real scan of this Mac) to a PNG.
    private static func snapshotPanel(to path: String) {
        let scanner = PeripheralScanner()
        scanner.scanSync()
        let content = MenuContent(scanner: scanner, updates: UpdateChecker())
            .background(Color(nsColor: .windowBackgroundColor))
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        if let img = renderer.nsImage, let tiff = img.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }

    private static func snapshotAbout(to path: String) {
        let content = VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Peripheral Speed").font(.headline)
                Text(AppInfo.display).font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            AboutView(scanner: PeripheralScanner(), linkAsText: true)
        }
        .padding(12)
        .frame(width: 340)
        .background(Color(nsColor: .windowBackgroundColor))
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        if let img = renderer.nsImage, let tiff = img.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(scanner: scanner, updates: updates)
                .onAppear {
                    scanner.start()
                    scanner.startActivity()
                    updates.start()
                }
                .onDisappear { scanner.stopActivity() }
        } label: {
            Image(systemName: scanner.result.worstVerdict == .bad
                  ? "exclamationmark.triangle.fill"
                  : "bolt.horizontal")
        }
        .menuBarExtraStyle(.window)
    }
}

/// Layout: the physical hierarchy (the Mac's ports, then the display's),
/// because that's how the user finds things on their desk. Numbers: only
/// where data can actually flow — drives get a GB/s copy speed, free ports
/// get what a drive would do there, and everything else (chargers,
/// displays, hub plumbing) keeps its place in the tree with no speed.
struct MenuContent: View {
    @ObservedObject var scanner: PeripheralScanner
    @ObservedObject var updates: UpdateChecker
    @State private var startAtLogin = SMAppService.mainApp.status == .enabled
    @State private var showAbout = false
    @State private var diagCopied = false

    /// One top-level USB device plus everything hanging off it.
    private struct USBBlock: Identifiable {
        let root: USBDevice
        var children: [USBDevice] = []
        var id: String { root.id }
    }

    private var blocks: [USBBlock] {
        var out: [USBBlock] = []
        for d in scanner.result.usbDevices {
            if d.depth == 0 || out.isEmpty {
                out.append(USBBlock(root: d))
            } else {
                out[out.count - 1].children.append(d)
            }
        }
        return out
    }

    /// Search EVERY device in every TB chain — a display can sit behind a
    /// dock (e.g. Pro Display XDR daisy-chained off an Anker TB4 dock).
    private var tbDisplayName: String? {
        scanner.result.tbPorts.flatMap(\.deviceNames)
            .first { $0.localizedCaseInsensitiveContains("display") }
    }

    private var tbAllNames: [String] { scanner.result.tbPorts.flatMap(\.deviceNames) }

    /// Vendors punctuate inconsistently across planes ("Thunderbolt 4"
    /// vs "Thunderbolt4") — compare with spaces stripped, case folded.
    private func matchesTBDevice(_ name: String) -> Bool {
        func norm(_ s: String) -> String {
            s.lowercased().replacingOccurrences(of: " ", with: "")
        }
        let n = norm(name)
        guard n.count >= 6 else { return false }
        return tbAllNames.contains {
            let t = norm($0)
            return t.contains(n) || n.contains(t)
        }
    }

    /// A TB dock also exposes a "USB companion" plane on the Mac's own
    /// controller, betrayed by a billboard device named like the TB device
    /// (e.g. "Thunderbolt4 Mini Dock" under a built-in controller). That
    /// controller is the SAME physical port as the TB row — never a second
    /// occupied port.
    private var companionControllers: Set<Int> {
        var out = Set<Int>()
        for b in blocks where b.root.bus == .usbC {
            if ([b.root.name] + b.children.map(\.name)).contains(where: matchesTBDevice) {
                out.insert(b.root.controllerID)
            }
        }
        return out
    }

    /// Real devices living on companion planes (a drive in the dock's USB
    /// port) — shown under the TB row; hubs and billboards stay hidden.
    private var companionExtras: [USBDevice] {
        blocks.filter { companionControllers.contains($0.root.controllerID) }
            .flatMap { [$0.root] + $0.children }
            .filter { $0.isStorage || (!$0.isHub && !matchesTBDevice($0.name)) }
    }

    private var displayShortName: String {
        (tbDisplayName ?? "display").replacingOccurrences(of: "Apple Inc. ", with: "")
    }

    /// An Apple display announces itself as generically named Apple hubs on
    /// the Thunderbolt-tunneled controller — plumbing, not user gear. The
    /// bus check matters: M4-family minis carry an identical-looking Apple
    /// hub pair on a plain USB-C controller, but that one is the FRONT
    /// PORTS, not the display (see isFrontInternalHub).
    private func isDisplayInternalHub(_ d: USBDevice) -> Bool {
        guard tbDisplayName != nil, d.isHub, d.depth == 0,
              d.bus == .thunderbolt || d.bus == .unknown else { return false }
        let appleOrAnon = (d.vendor ?? "apple").localizedCaseInsensitiveContains("apple")
        return appleOrAnon && (d.name.localizedCaseInsensitiveContains("hub")
                               || d.name == "IOUSBHostDevice")
    }

    /// On models with usbCFront > 0 the front USB-C ports live behind an
    /// internal Apple hub pair on one non-tunneled controller.
    private var frontPortCount: Int { scanner.result.inventory?.usbCFront ?? 0 }

    private func isFrontInternalHub(_ d: USBDevice) -> Bool {
        guard frontPortCount > 0, d.isHub, d.depth == 0, d.bus == .usbC else { return false }
        return (d.vendor ?? "").localizedCaseInsensitiveContains("apple")
            && d.name.localizedCaseInsensitiveContains("hub")
    }

    /// The display's camera/speakers enumerate as a USB device named after
    /// the display itself — internal, not a port anyone can use.
    private func isDisplayBuiltin(_ d: USBDevice) -> Bool {
        tbDisplayName != nil && !d.isHub && !d.isStorage
            && d.name.localizedCaseInsensitiveContains("display")
    }

    private var displayBlocks: [USBBlock] { blocks.filter { isDisplayInternalHub($0.root) } }
    private var frontBlocks: [USBBlock] { blocks.filter { isFrontInternalHub($0.root) } }
    private var macBlocks: [USBBlock] {
        blocks.filter { !isDisplayInternalHub($0.root) && !isFrontInternalHub($0.root) }
    }
    private var usbABlocks: [USBBlock] { macBlocks.filter { $0.root.bus == .usbA } }
    private var usbCBlocks: [USBBlock] {
        macBlocks.filter { $0.root.bus != .usbA
            && !companionControllers.contains($0.root.controllerID) }
    }

    /// Devices sharing a controller share a physical USB-C port — show the
    /// first as the port, nest the rest under it.
    private var usbCRows: [(block: USBBlock, first: Bool)] {
        var seen = Set<Int>()
        return usbCBlocks.map { b in
            let first = !seen.contains(b.root.controllerID)
            seen.insert(b.root.controllerID)
            return (block: b, first: first)
        }
    }

    /// Free rear/Thunderbolt USB-C ports: empty TB buses minus ports
    /// occupied by USB-mode devices the TB report can't see (one
    /// controller == one physical port; front ports are counted
    /// separately). MacBook Neo has no TB report at all — count from the
    /// model's known ports instead.
    private var freeUSBCCount: Int {
        let usbModePorts = Set(usbCBlocks.filter { $0.root.bus == .usbC }
            .map(\.root.controllerID)).count   // companions already excluded
        if let inv = scanner.result.inventory, !inv.hasThunderbolt {
            return max(0, inv.usbC - usbModePorts)
        }
        let emptyTB = scanner.result.tbPorts.filter { $0.deviceNames.isEmpty }.count
        return max(0, emptyTB - usbModePorts)
    }

    /// Physical front ports in use: children of the front internal hub
    /// pair, deduplicated across its fast/slow planes by port number.
    private var freeFrontCount: Int {
        var ports = Set<Int>()
        for b in frontBlocks {
            let rc = portChain(b.root.locationID)
            for d in b.children {
                let dc = portChain(d.locationID)
                if dc.count > rc.count { ports.insert(dc[rc.count]) }
            }
        }
        return max(0, frontPortCount - ports.count)
    }

    /// "back" only when the model actually has separately listed front ports.
    private var backTag: String { frontPortCount > 0 ? "USB-C back" : "USB-C" }

    private var freeUSBACount: Int {
        guard let inv = scanner.result.inventory else { return 0 }
        return max(0, inv.usbA - usbABlocks.count)
    }

    /// On machines with unequal USB-C ports (MacBook Neo), name each free
    /// port by position. Occupied ports are retired from the pool by a
    /// speed argument: a device faster than 480 Mb/s can only be on a
    /// fast port; a slow device is assumed to sit on the slowest port.
    private var freeUSBCPortRows: [(title: String, subtitle: String)]? {
        guard let inv = scanner.result.inventory,
              let ports = inv.usbCPorts, !inv.hasThunderbolt else { return nil }
        var pool = ports.sorted { $0.linkMbps > $1.linkMbps }
        let occupiedSpeeds = Dictionary(grouping: usbCBlocks.filter { $0.root.bus == .usbC },
                                        by: \.root.controllerID)
            .values.map { blocks in
                blocks.flatMap { [$0.root] + $0.children }.compactMap(\.speedMbps).max() ?? 0
            }
        for speed in occupiedSpeeds.sorted(by: >) where !pool.isEmpty {
            if speed > 480, let i = pool.firstIndex(where: { $0.linkMbps > 480 }) {
                pool.remove(at: i)
            } else {
                pool.removeLast()
            }
        }
        return pool.map { p in
            p.linkMbps > 480
                ? ("USB-C \(p.label) — free", "≈ \(Speed.gbCopy(linkMbps: p.linkMbps))")
                : ("USB-C \(p.label) — free", "only ≈ \(Speed.gbCopy(linkMbps: p.linkMbps)) — not for drives")
        }
    }

    /// Every USB device renders through this: dot, subtitle, advice, and —
    /// for a drive with mounted media — the test/eject buttons and outcomes.
    @ViewBuilder
    private func deviceRow(_ d: USBDevice, title: String? = nil, indent: Int = 0) -> some View {
        let loc = d.locationID
        let ejected = scanner.ejectedLocations.contains(loc)
        let busy = scanner.ejectingLocations.contains(loc) || scanner.testingLocations.contains(loc)
        DeviceRow(dot: dot(for: d),
                  title: title ?? (d.name == "IOUSBHostDevice"
                                   ? (d.vendor ?? "USB device") : d.name),
                  subtitle: ejected ? "" : subtitle(d),
                  advice: adviceFor(d),
                  indent: indent,
                  note: rowNote(d, ejected: ejected),
                  detail: capacityDetail(d),
                  fillFraction: {
                      guard d.isStorage, let c = scanner.capacities[d.locationID],
                            c.total > 0 else { return nil }
                      return Double(c.total - c.free) / Double(c.total)
                  }(),
                  ejecting: busy,
                  onEject: {
                      guard d.isStorage, !ejected, !busy, let bsd = d.bsdName else { return nil }
                      return { scanner.eject(bsd, location: loc) }
                  }(),
                  onTest: {
                      guard d.isStorage, !ejected, !busy, let bsd = d.bsdName else { return nil }
                      return { scanner.speedTest(bsd, location: loc) }
                  }())
            .help(d.speedLabel)
    }

    private func rowNote(_ d: USBDevice, ejected: Bool) -> (text: String, color: Color)? {
        let loc = d.locationID
        if ejected { return ("Ejected — safe to unplug.", .green) }
        if let e = scanner.ejectErrors[loc] { return (e, .orange) }
        if let e = scanner.testErrors[loc] { return (e, .orange) }
        if let bps = scanner.activityBps[loc], bps > 20_000_000 {
            return ("Copying right now ≈ \(Speed.format(bps / 1e9))", .blue)
        }
        if let tip = moveSuggestion(d) { return tip }
        if let r = scanner.testResults[loc] {
            // orange when the drive delivers well under what its link allows
            let expected = Speed.gbps(linkMbps: d.speedMbps ?? 0)
            let healthy = expected == 0 || min(r.write, r.read) > expected * 0.5
            return ("Measured: writes \(Speed.format(r.write)) · reads \(Speed.format(r.read))",
                    healthy ? .green : .orange)
        }
        return nil
    }

    /// "1 TB drive · 487 GB free" — orange when nearly full, because a
    /// too-small drive ruins an offload as surely as a slow one.
    private func capacityDetail(_ d: USBDevice) -> (text: String, color: Color)? {
        guard d.isStorage, let c = scanner.capacities[d.locationID], c.total > 0 else { return nil }
        let free = ByteCountFormatter.string(fromByteCount: c.free, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: c.total, countStyle: .file)
        let low = Double(c.free) < Double(c.total) * 0.1
        return ("\(total) drive · \(free) free" + (low ? " — nearly full" : ""),
                low ? .orange : .secondary)
    }

    /// Model-aware upgrade of a drive's advice: on a Neo a USB-2-speed
    /// drive is most likely just in the wrong port.
    private func adviceFor(_ d: USBDevice) -> String? {
        if d.isStorage, d.verdict == .bad, d.bus == .usbC,
           let ports = scanner.result.inventory?.usbCPorts,
           let fast = ports.max(by: { $0.linkMbps < $1.linkMbps }) {
            return "Stuck at ≈ 0.05 GB/s. Move it to the \(fast.label) port — the other one is USB-2 only. If it's already there, swap the cable."
        }
        return d.advice
    }

    private var drives: [USBDevice] { scanner.result.usbDevices.filter(\.isStorage) }

    /// Port hops from a locationID (top byte = bus, then a nibble per hop).
    private func portChain(_ loc: Int) -> [Int] {
        var out: [Int] = []
        var shift = 20
        while shift >= 0 {
            let nib = (loc >> shift) & 0xF
            if nib == 0 { break }
            out.append(nib)
            shift -= 4
        }
        return out
    }

    /// Rows behind an internal Apple hub pair (a display's ports, or the
    /// M4 mini's front ports), with the dual-plane split healed: a USB 3
    /// hub shows up as a hub node on the slow plane while fast devices
    /// behind it attach to the fast plane directly. Both planes number
    /// physical ports the same way, so a fast device whose first port hop
    /// matches a slow-plane hub's is physically behind that hub.
    private func mergedHubRows(_ hubBlocks: [USBBlock],
                               excluding: (USBDevice) -> Bool) -> [(d: USBDevice, indent: Int)] {
        func tail(_ d: USBDevice, root: USBDevice) -> [Int] {
            let rc = portChain(root.locationID), dc = portChain(d.locationID)
            return dc.count > rc.count ? Array(dc.dropFirst(rc.count)) : []
        }
        let fastRoots = hubBlocks.filter { ($0.root.speedMbps ?? 0) >= 5_000 }
        let slowRoots = hubBlocks.filter { ($0.root.speedMbps ?? 0) < 5_000 }
        var fastItems = fastRoots.flatMap { b in
            b.children.filter { !excluding($0) }
                .map { (d: $0, t: tail($0, root: b.root)) }
        }
        var rows: [(d: USBDevice, indent: Int)] = []
        for slow in slowRoots {
            for d in slow.children where !excluding(d) {
                rows.append((d, max(0, d.depth - 1)))
                if d.isHub, let port = tail(d, root: slow.root).first {
                    let behind = fastItems.filter { $0.t.first == port }
                    fastItems.removeAll { $0.t.first == port }
                    for f in behind { rows.append((f.d, max(0, f.d.depth - 1) + 1)) }
                }
            }
        }
        for f in fastItems { rows.append((f.d, max(0, f.d.depth - 1))) }
        return rows
    }

    private var displayRows: [(d: USBDevice, indent: Int)] {
        mergedHubRows(displayBlocks, excluding: isDisplayBuiltin)
    }

    private var displayDeviceIDs: Set<String> { Set(displayRows.map(\.d.id)) }

    private var displayUplinkMbps: Double? { displayBlocks.compactMap(\.root.speedMbps).max() }

    /// What a USB drive would negotiate on the best FREE Mac port right
    /// now (USB mode: 10 Gb/s on any free USB-C; USB-A per model).
    private var bestFreeMacMbps: Double {
        if freeUSBCCount > 0 || freeFrontCount > 0 { return 10_000 }
        if freeUSBACount > 0 { return Double(scanner.result.inventory?.usbAGbps ?? 5) * 1_000 }
        return 0
    }

    /// The nearest hub above a nested device, in scan order.
    private func parentHubSpeed(of d: USBDevice) -> Double? {
        for b in blocks {
            let seq = [b.root] + b.children
            guard let idx = seq.firstIndex(where: { $0.id == d.id }), idx > 0 else { continue }
            for j in stride(from: idx - 1, through: 0, by: -1)
            where seq[j].depth == d.depth - 1 {
                return seq[j].isHub ? seq[j].speedMbps : nil
            }
            return nil
        }
        return nil
    }

    /// Placement coaching: a drive saturating the lane above it (display
    /// uplink or hub plane) while a faster free Mac port sits empty is
    /// worth moving — say so, with the gain. A drive slow by its own
    /// nature, or with nothing better free, gets silence: silence means
    /// "already on the best port".
    private func moveSuggestion(_ d: USBDevice) -> (text: String, color: Color)? {
        guard d.isStorage, let mbps = d.speedMbps, bestFreeMacMbps > mbps else { return nil }
        if displayDeviceIDs.contains(d.id), let uplink = displayUplinkMbps, mbps >= uplink {
            return ("Tip: a free Mac port would give this drive up to ≈ \(Speed.gbCopy(linkMbps: bestFreeMacMbps)) — worth moving for big copies.",
                    .blue)
        }
        if d.depth > 0, let hubSpeed = parentHubSpeed(of: d), mbps >= hubSpeed {
            return ("Tip: this hub is the limit — straight into a free Mac port this could reach ≈ \(Speed.gbCopy(linkMbps: bestFreeMacMbps)).",
                    .blue)
        }
        return nil
    }

    private var frontRows: [(d: USBDevice, indent: Int)] {
        mergedHubRows(frontBlocks, excluding: { _ in false })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Peripheral Speed").font(.headline)
                Text(AppInfo.display).font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                if scanner.scanning {
                    ProgressView().controlSize(.small)
                        .help("Re-checking")
                }
                Button {
                    showAbout.toggle()
                    diagCopied = false
                } label: {
                    Image(systemName: showAbout ? "xmark.circle.fill" : "questionmark.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(showAbout ? "Back to the port list" : "About this app")
            }

            if showAbout {
                aboutView
            } else if scanner.result.usbDevices.isEmpty && scanner.result.tbPorts.isEmpty {
                Text("Scanning…").foregroundStyle(.secondary)
            } else {
                statusBanner

                section(macSectionTitle) {
                    ForEach(scanner.result.tbPorts.filter { !$0.deviceNames.isEmpty }) { p in
                        DeviceRow(dot: p.verdict == .good ? .gray : color(p.verdict),
                                  title: "\(backTag) — \(p.deviceNames.first ?? "?")",
                                  subtitle: tbSubtitle(p),
                                  advice: p.advice)
                    }
                    ForEach(companionExtras) { d in
                        deviceRow(d, indent: 1)
                    }
                    ForEach(usbCRows, id: \.block.id) { row in
                        let extra = row.first ? 0 : 1
                        deviceRow(row.block.root,
                                  title: row.first ? "\(backTag) — \(row.block.root.name)"
                                                   : row.block.root.name,
                                  indent: extra)
                        ForEach(row.block.children) { d in
                            deviceRow(d, indent: d.depth + extra)
                        }
                    }
                    if let portRows = freeUSBCPortRows {
                        ForEach(portRows, id: \.title) { row in
                            DeviceRow(dot: .gray, title: row.title,
                                      subtitle: row.subtitle, advice: nil)
                        }
                    } else {
                        ForEach(0..<freeUSBCCount, id: \.self) { _ in
                            DeviceRow(dot: .gray, title: "\(backTag) — free",
                                      subtitle: scanner.result.inventory?.usbCLabel
                                                ?? "≈ 2–3 GB/s",
                                      advice: nil)
                                .help("Marketed as 40 Gb/s (Thunderbolt / USB4) — gigaBITS. ÷10 for real-world copying in gigaBYTES.")
                        }
                    }

                    ForEach(frontRows, id: \.d.id) { row in
                        deviceRow(row.d,
                                  title: row.indent == 0 ? "USB-C front — \(row.d.name)" : nil,
                                  indent: row.indent)
                    }
                    ForEach(0..<freeFrontCount, id: \.self) { _ in
                        DeviceRow(dot: .gray, title: "USB-C front — free",
                                  subtitle: "≈ 1.0 GB/s", advice: nil)
                            .help("Marketed as 10 Gb/s — gigaBITS. ÷10 for real-world copying in gigaBYTES.")
                    }

                    ForEach(usbABlocks) { b in
                        deviceRow(b.root, title: "USB-A — \(b.root.name)")
                        ForEach(b.children) { d in
                            deviceRow(d, indent: d.depth)
                        }
                    }
                    ForEach(0..<freeUSBACount, id: \.self) { _ in
                        let gbits = scanner.result.inventory?.usbAGbps ?? 5
                        DeviceRow(dot: .gray, title: "USB-A — free",
                                  subtitle: "≈ \(Speed.gbCopy(linkMbps: Double(gbits) * 1_000))",
                                  advice: nil)
                            .help("Marketed as \(gbits) Gb/s — gigaBITS. ÷10 for real-world copying in gigaBYTES.")
                    }
                }

                if !displayBlocks.isEmpty {
                    section("On your \(displayShortName)") {
                        let rows = displayRows
                        ForEach(rows, id: \.d.id) { row in
                            deviceRow(row.d, indent: row.indent)
                        }
                        if rows.isEmpty {
                            Text("Nothing plugged into its ports right now")
                                .font(.caption).foregroundStyle(.secondary)
                                .padding(.leading, 14)
                        }
                        // The shared uplink only matters when a drive rides it.
                        if rows.contains(where: \.d.isStorage),
                           let uplink = displayBlocks.compactMap(\.root.speedMbps).max() {
                            Text("Drives on the display share ≈ \(Speed.gbCopy(linkMbps: uplink)) back to the Mac.")
                                .font(.caption2).foregroundStyle(.secondary)
                                .padding(.leading, 14)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            if updates.updating {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Updating — the app will relaunch itself…").font(.caption)
                }
            } else if let latest = updates.latest {
                Button {
                    updates.installUpdate()
                } label: {
                    Label("v\(latest.version) is out — update now",
                          systemImage: "arrow.down.circle.fill")
                }
                .font(.caption)
                if let err = updates.updateError, let url = URL(string: latest.url) {
                    Text(err).font(.caption2).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Link("Download manually instead", destination: url).font(.caption2)
                }
            }

            Divider()
            HStack {
                Button("Rescan") { scanner.scan() }
                    .help("Ports also update by themselves when devices change")
                Spacer()
                Toggle("Start at login", isOn: $startAtLogin)
                    .toggleStyle(.checkbox)
                    .onChange(of: startAtLogin) { on in
                        do {
                            if on { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch {
                            startAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                    .help("Open Peripheral Speed automatically after every restart")
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 340)
    }

    // MARK: - pieces

    private var aboutView: some View { AboutView(scanner: scanner) }

    private var macSectionTitle: String {
        guard let inv = scanner.result.inventory else { return "On your Mac" }
        var parts = ["\(inv.usbC) × USB-C"]
        if inv.usbA > 0 { parts.append("\(inv.usbA) × USB-A") }
        return "On your \(inv.marketingName) — \(parts.joined(separator: ", "))"
    }

    @ViewBuilder private var statusBanner: some View {
        let (text, icon, tint): (String, String, Color) = {
            switch scanner.result.worstVerdict {
            case .bad:
                return ("A drive is being slowed down — fix below",
                        "exclamationmark.triangle.fill", .red)
            case .caution:
                return ("Worth a look — one link may be running slow",
                        "questionmark.circle.fill", .orange)
            case .good:
                return (drives.isEmpty
                        ? "No drives connected"
                        : "All good — every drive is at full speed",
                        "checkmark.circle.fill", .green)
            }
        }()
        Label(text, systemImage: icon)
            .font(.callout.weight(.medium))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6).padding(.horizontal, 8)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    /// Speed only where data can flow: drives get their real-world copy
    /// speed plus what that means for a big offload — measured write
    /// speed once a test has run, the link estimate before that.
    private func subtitle(_ d: USBDevice) -> String {
        guard d.isStorage, let mbps = d.speedMbps else { return "" }
        let g = scanner.testResults[d.locationID]?.write ?? Speed.gbps(linkMbps: mbps)
        return "≈ \(Speed.format(g)) · 500 GB \(Speed.eta(gb: 500, gbPerSec: g))"
    }

    private func tbSubtitle(_ p: TBPort) -> String {
        if p.isLegacyDisplay, let g = p.gbps, g <= 20 {
            return "older display — ≈ \(Speed.gbCopy(linkMbps: g * 1_000)) is its max"
        }
        guard p.verdict != .good, let g = p.gbps else { return "" }
        return "caps drives at ≈ \(Speed.gbCopy(linkMbps: g * 1_000))"
    }

    /// Green is reserved for drives at full speed; gray means "fine, and
    /// speed doesn't apply"; yellow/red mark real slowdowns.
    private func dot(for d: USBDevice) -> Color {
        if d.verdict == .good && !d.isStorage { return .gray }
        return color(d.verdict)
    }

    private func color(_ v: Verdict) -> Color {
        switch v {
        case .good: return .green
        case .caution: return .yellow
        case .bad: return .red
        }
    }
}

struct AboutView: View {
    let scanner: PeripheralScanner
    /// ImageRenderer can't draw a live Link; the snapshot draws the same
    /// text in link styling instead.
    var linkAsText = false
    @State private var diagCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Shows how fast data can move through this Mac's ports — and what's slowing it down.")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                Label("Green dot: a drive at full speed. Gray: speed doesn't matter for that device.", systemImage: "circle.fill")
                Label("Ejects a drive so it's safe to unplug.", systemImage: "eject.fill")
                Label("Measures a drive's real speed with a short test file.", systemImage: "gauge")
                Label("All numbers are real-world copy speeds in GB/s.", systemImage: "speedometer")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Divider()

            Button {
                copyDiagnostics()
            } label: {
                Label(diagCopied ? "Copied — ready to paste" : "Copy diagnostic info",
                      systemImage: diagCopied ? "checkmark.circle.fill" : "doc.on.doc")
            }
            Text("Copies this Mac's port wiring details (device names only — nothing personal). If the port list ever looks wrong, copy this and send it to Chris.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if linkAsText {
                Label("Useful? Buy us a ¥500 matcha latte — ko-fi.com/movementchris",
                      systemImage: "cup.and.saucer.fill")
                    .font(.caption).foregroundStyle(.blue)
            } else {
                Link(destination: URL(string: "https://ko-fi.com/movementchris")!) {
                    Label("Useful? Buy us a ¥500 matcha latte", systemImage: "cup.and.saucer.fill")
                }
                .font(.caption)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Made in Japan · Built with Claude Code · 2026")
                    .foregroundStyle(.tertiary)
                if linkAsText {
                    Text("www.move-ment.co").foregroundStyle(.blue)
                } else {
                    Link("www.move-ment.co", destination: URL(string: "https://www.move-ment.co")!)
                }
            }
            .font(.caption2)
        }
    }

    private func copyDiagnostics() {
        DispatchQueue.global(qos: .userInitiated).async {
            let report = scanner.diagnosticReport()
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(report, forType: .string)
                diagCopied = true
            }
        }
    }
}

struct DeviceRow: View {
    let dot: Color
    let title: String
    let subtitle: String
    let advice: String?
    var indent: Int = 0
    var note: (text: String, color: Color)? = nil
    var detail: (text: String, color: Color)? = nil
    var fillFraction: Double? = nil
    var ejecting: Bool = false
    var onEject: (() -> Void)? = nil
    var onTest: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if indent > 0 {
                    Text("└")
                        .font(.caption).foregroundStyle(.tertiary)
                        .padding(.leading, CGFloat(indent) * 14)
                }
                Circle().fill(dot).frame(width: 8, height: 8)
                if ejecting {
                    ProgressView().controlSize(.small)
                } else if let onEject {
                    Button(action: onEject) { Image(systemName: "eject.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Eject so it's safe to unplug")
                }
                Text(title).font(.system(.body, design: .rounded))
                    .lineLimit(1).truncationMode(.tail).layoutPriority(1)
                Spacer(minLength: 6)
                if !subtitle.isEmpty {
                    // the speed/ETA is the point — never let it truncate;
                    // the device name shortens first if space is tight.
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).fixedSize().layoutPriority(2)
                }
                if !ejecting, let onTest {
                    Button(action: onTest) { Image(systemName: "gauge") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Measure real copy speed (writes a temp file for a few seconds)")
                }
            }
            if let advice {
                Text(advice)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.leading, CGFloat(indent + 1) * 14)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note {
                Text(note.text)
                    .font(.caption)
                    .foregroundStyle(note.color)
                    .padding(.leading, CGFloat(indent + 1) * 14)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let detail {
                Text(detail.text)
                    .font(.caption2)
                    .foregroundStyle(detail.color)
                    .padding(.leading, CGFloat(indent + 1) * 14)
            }
            if let fillFraction {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.2))
                        Capsule()
                            .fill(fillFraction > 0.9 ? Color.orange : Color.accentColor)
                            .frame(width: max(3, geo.size.width * fillFraction))
                    }
                }
                .frame(height: 4)
                .padding(.leading, CGFloat(indent + 1) * 14)
                .padding(.trailing, 2)
                .animation(.easeOut(duration: 0.6), value: fillFraction)
            }
        }
    }
}
