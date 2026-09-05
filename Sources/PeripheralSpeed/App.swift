import SwiftUI
import AppKit

@main
struct PeripheralSpeedApp: App {
    @StateObject private var scanner = PeripheralScanner()

    init() {
        // menu-bar only: no Dock icon, no app switcher entry
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(scanner: scanner)
                .onAppear { scanner.start() }
        } label: {
            Image(systemName: scanner.result.worstVerdict == .bad
                  ? "exclamationmark.triangle.fill"
                  : "bolt.horizontal")
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuContent: View {
    @ObservedObject var scanner: PeripheralScanner

    /// One top-level USB device plus everything hanging off it.
    private struct USBBlock: Identifiable {
        let root: USBDevice
        var children: [USBDevice] = []
        var id: UUID { root.id }
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

    /// Name of a display attached over Thunderbolt (e.g. "Apple Inc. Studio
    /// Display"), used to claim its internal USB hubs.
    private var tbDisplayName: String? {
        scanner.result.tbPorts
            .compactMap { $0.deviceNames.first }
            .first { $0.localizedCaseInsensitiveContains("display") }
    }

    private var displayShortName: String {
        (tbDisplayName ?? "display").replacingOccurrences(of: "Apple Inc. ", with: "")
    }

    /// An Apple display/dock announces itself as generically named Apple hubs
    /// at the top of the USB tree — plumbing, not something the user plugged in.
    /// Must arrive over the Thunderbolt-tunneled controller: a hub on a Mac
    /// port stays a real hub even if Apple made it.
    private func isDisplayInternalHub(_ d: USBDevice) -> Bool {
        guard tbDisplayName != nil, d.isHub, d.depth == 0,
              d.bus == .thunderbolt || d.bus == .unknown else { return false }
        return (d.vendor ?? "").localizedCaseInsensitiveContains("apple")
            && d.name.localizedCaseInsensitiveContains("hub")
    }

    /// The display's camera/speakers enumerate as a USB device named after
    /// the display itself — internal, not a port anyone can unplug.
    private func isDisplayBuiltin(_ d: USBDevice) -> Bool {
        tbDisplayName != nil && !d.isHub && !d.isStorage
            && d.name.localizedCaseInsensitiveContains("display")
    }

    private var displayBlocks: [USBBlock] { blocks.filter { isDisplayInternalHub($0.root) } }
    private var macBlocks: [USBBlock] { blocks.filter { !isDisplayInternalHub($0.root) } }

    private var usbABlocks: [USBBlock] { macBlocks.filter { $0.root.bus == .usbA } }
    private var usbCBlocks: [USBBlock] { macBlocks.filter { $0.root.bus != .usbA } }

    /// Empty TB buses minus USB-C ports occupied by USB-mode devices the
    /// TB report can't see (one controller == one physical port).
    private var freeUSBCCount: Int {
        let emptyTB = scanner.result.tbPorts.filter { $0.deviceNames.isEmpty }.count
        let usbModePorts = Set(usbCBlocks.filter { $0.root.bus == .usbC }
            .map(\.root.controllerID)).count
        return max(0, emptyTB - usbModePorts)
    }

    private var freeUSBACount: Int {
        guard let inv = scanner.result.inventory else { return 0 }
        return max(0, inv.usbA - usbABlocks.count)
    }

    /// Devices sharing a controller share a physical USB-C port — a hub's
    /// USB2 side and a USB3 device behind it enumerate as siblings. Show
    /// the first as the port; nest the rest under it.
    private var usbCRows: [(block: USBBlock, first: Bool)] {
        var seen = Set<Int>()
        return usbCBlocks.map { b in
            let first = !seen.contains(b.root.controllerID)
            seen.insert(b.root.controllerID)
            return (block: b, first: first)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Peripheral Speed").font(.headline)
                Spacer()
                if scanner.scanning {
                    ProgressView().controlSize(.small)
                        .help("Re-checking — runs by itself every 5 seconds")
                }
            }

            if scanner.result.usbDevices.isEmpty && scanner.result.tbPorts.isEmpty {
                Text("Scanning…").foregroundStyle(.secondary)
            } else {
                statusBanner

                section(macSectionTitle) {
                    // USB-C / Thunderbolt: TB devices first, then USB-mode
                    // devices plugged into a Mac USB-C port, then free ports.
                    ForEach(scanner.result.tbPorts.filter { !$0.deviceNames.isEmpty }) { p in
                        DeviceRow(dot: color(p.verdict),
                                  title: "USB-C — \(p.deviceNames.first ?? "?")",
                                  subtitle: tbSubtitle(p),
                                  advice: p.advice)
                    }
                    ForEach(usbCRows, id: \.block.id) { row in
                        let extra = row.first ? 0 : 1
                        DeviceRow(dot: dot(for: row.block.root),
                                  title: row.first ? "USB-C — \(row.block.root.name)"
                                                   : row.block.root.name,
                                  subtitle: usbSubtitle(row.block.root),
                                  advice: row.block.root.advice,
                                  indent: extra)
                            .help(row.block.root.speedLabel)
                        ForEach(row.block.children) { d in
                            DeviceRow(dot: dot(for: d),
                                      title: d.name,
                                      subtitle: usbSubtitle(d),
                                      advice: d.advice,
                                      indent: d.depth + extra)
                                .help(d.speedLabel)
                        }
                    }
                    ForEach(0..<freeUSBCCount, id: \.self) { _ in
                        DeviceRow(dot: .gray, title: "USB-C — free",
                                  subtitle: "up to 40 Gb/s", advice: nil)
                    }

                    ForEach(usbABlocks) { b in
                        DeviceRow(dot: dot(for: b.root),
                                  title: "USB-A — \(b.root.name)",
                                  subtitle: usbSubtitle(b.root),
                                  advice: b.root.advice)
                            .help(b.root.speedLabel)
                        ForEach(b.children) { d in
                            DeviceRow(dot: dot(for: d),
                                      title: d.name,
                                      subtitle: usbSubtitle(d),
                                      advice: d.advice,
                                      indent: d.depth)
                                .help(d.speedLabel)
                        }
                    }
                    ForEach(0..<freeUSBACount, id: \.self) { _ in
                        DeviceRow(dot: .gray, title: "USB-A — free",
                                  subtitle: "up to \(scanner.result.inventory?.usbAGbps ?? 5) Gb/s",
                                  advice: nil)
                    }

                    Text(scanner.result.inventory == nil
                         ? "macOS can't say which physical port is which, and USB-A ports only show while something is plugged in."
                         : "macOS can't say which physical port is which — unplug and replug to see which row changes.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .padding(.leading, 14)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !displayBlocks.isEmpty {
                    section("On your \(displayShortName)") {
                        let plugged = displayBlocks.flatMap(\.children).filter { !isDisplayBuiltin($0) }
                        ForEach(plugged) { d in
                            DeviceRow(dot: dot(for: d),
                                      title: d.name,
                                      subtitle: usbSubtitle(d),
                                      advice: d.advice,
                                      indent: max(0, d.depth - 1))
                                .help(d.speedLabel)
                        }
                        if plugged.isEmpty {
                            Text("Nothing plugged into its ports right now")
                                .font(.caption).foregroundStyle(.secondary)
                                .padding(.leading, 14)
                        }
                        if let uplink = displayBlocks.compactMap(\.root.speedMbps).max() {
                            Text("Everything on its ports shares one \(shortSpeed(uplink)) line back to the Mac.")
                                .font(.caption2).foregroundStyle(.secondary)
                                .padding(.leading, 14)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            Divider()
            HStack {
                Button("Rescan") { scanner.scan() }
                Spacer()
                Text("checks itself every 5 s").font(.caption2)
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
                return ("All good — nothing is being slowed down",
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

    /// Drives get real-world copy speed (≈ link rate ÷ 10 after protocol
    /// overhead); hubs get what their downstream ports can feed off; the
    /// raw link label stays available as a tooltip.
    private func usbSubtitle(_ d: USBDevice) -> String {
        guard let mbps = d.speedMbps else { return d.speedLabel }
        if d.isStorage { return "copies up to ≈ \(Int(mbps / 10)) MB/s" }
        if d.isHub {
            // A USB 3 hub is two hubs in one shell; when something on this
            // port runs faster than this hub node, this node is only the
            // slow lane and its speed says nothing about the port.
            if fasterSiblingExists(than: d) { return "hub — slow lane, fast devices bypass it" }
            return "its ports share \(shortSpeed(mbps))"
        }
        return d.speedLabel
    }

    private func fasterSiblingExists(than d: USBDevice) -> Bool {
        scanner.result.usbDevices.contains {
            $0.controllerID == d.controllerID && !$0.isHub
                && ($0.speedMbps ?? 0) > (d.speedMbps ?? 0)
        }
    }

    private func shortSpeed(_ mbps: Double) -> String {
        mbps >= 1_000 ? "\(Int(mbps / 1_000)) Gb/s" : "\(Int(mbps)) Mb/s"
    }

    private func tbSubtitle(_ p: TBPort) -> String {
        guard let g = p.gbps else { return p.speedText.isEmpty ? p.busName : p.speedText }
        return g >= 40 ? "\(Int(g)) Gb/s — full speed" : "\(Int(g)) Gb/s"
    }

    /// Green is reserved for drives (where speed is the point); anything
    /// else that's fine shows gray so a slow charger never looks scary.
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

struct DeviceRow: View {
    let dot: Color
    let title: String
    let subtitle: String
    let advice: String?
    var indent: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if indent > 0 {
                    Text("└")
                        .font(.caption).foregroundStyle(.tertiary)
                        .padding(.leading, CGFloat(indent) * 14)
                }
                Circle().fill(dot).frame(width: 8, height: 8)
                Text(title).font(.system(.body, design: .rounded))
                Spacer()
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            if let advice {
                Text(advice)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.leading, CGFloat(indent + 1) * 14)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
