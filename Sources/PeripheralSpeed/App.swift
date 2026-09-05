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

/// The app answers one question: how fast can data copy right now?
/// So the menu shows drives, free ports a drive could go in, and problems.
/// Chargers, displays, hubs and other non-drive gear are scanned in the
/// background but only surface when they slow a drive down.
struct MenuContent: View {
    @ObservedObject var scanner: PeripheralScanner

    private var drives: [USBDevice] { scanner.result.usbDevices.filter(\.isStorage) }

    /// Name of a display attached over Thunderbolt, for locating drives
    /// plugged into its ports.
    private var tbDisplayName: String? {
        scanner.result.tbPorts
            .compactMap { $0.deviceNames.first }
            .first { $0.localizedCaseInsensitiveContains("display") }
    }

    private var displayShortName: String {
        (tbDisplayName ?? "display").replacingOccurrences(of: "Apple Inc. ", with: "")
    }

    /// Empty TB buses minus USB-C ports occupied by USB-mode devices the
    /// TB report can't see (one controller == one physical port).
    private var freeUSBCCount: Int {
        let emptyTB = scanner.result.tbPorts.filter { $0.deviceNames.isEmpty }.count
        let usbModePorts = Set(scanner.result.usbDevices
            .filter { $0.bus == .usbC && $0.depth == 0 }
            .map(\.controllerID)).count
        return max(0, emptyTB - usbModePorts)
    }

    private var freeUSBACount: Int {
        guard let inv = scanner.result.inventory else { return 0 }
        let occupied = Set(scanner.result.usbDevices
            .filter { $0.bus == .usbA && $0.depth == 0 }
            .map(\.id)).count
        return max(0, inv.usbA - occupied)
    }

    /// Degraded links that aren't drives (e.g. a dock negotiating 20 Gb/s
    /// on a 40 Gb/s port) still deserve a row — they cap any drive behind them.
    private var slowTBPorts: [TBPort] {
        scanner.result.tbPorts.filter { $0.verdict != .good }
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

                section("Drives") {
                    if drives.isEmpty {
                        Text("None connected — plug one in and it shows up here")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.leading, 14)
                    }
                    ForEach(drives) { d in
                        DeviceRow(dot: color(d.verdict),
                                  title: d.name,
                                  subtitle: driveSubtitle(d),
                                  advice: d.advice)
                            .help(d.speedLabel)
                    }
                }

                if freeUSBCCount > 0 || freeUSBACount > 0 {
                    section("Free ports for a drive") {
                        ForEach(0..<freeUSBCCount, id: \.self) { _ in
                            DeviceRow(dot: .gray, title: "USB-C",
                                      subtitle: "fastest — a good SSD copies ≈ 2–3 GB/s",
                                      advice: nil)
                        }
                        ForEach(0..<freeUSBACount, id: \.self) { _ in
                            let g = scanner.result.inventory?.usbAGbps ?? 5
                            DeviceRow(dot: .gray, title: "USB-A",
                                      subtitle: "a drive here tops out ≈ \(Speed.gbCopy(linkMbps: Double(g) * 1_000))",
                                      advice: nil)
                        }
                    }
                }

                if !slowTBPorts.isEmpty {
                    section("Slow links") {
                        ForEach(slowTBPorts) { p in
                            DeviceRow(dot: color(p.verdict),
                                      title: p.deviceNames.first ?? p.busName,
                                      subtitle: "caps drives at ≈ \(Speed.gbCopy(linkMbps: (p.gbps ?? 0) * 1_000))",
                                      advice: p.advice)
                                .help(p.speedText)
                        }
                    }
                }

                Text("Chargers, displays and hubs are checked too, but only shown if they slow a drive down.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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

    /// The number that matters (real-world copy speed) plus where the
    /// drive is plugged in.
    private func driveSubtitle(_ d: USBDevice) -> String {
        guard let mbps = d.speedMbps else { return d.speedLabel }
        let speed = "≈ \(Speed.gbCopy(linkMbps: mbps))"
        if let loc = location(d) { return "\(speed) · \(loc)" }
        return speed
    }

    private func location(_ d: USBDevice) -> String? {
        switch d.bus {
        case .usbA:
            return d.depth > 0 ? "USB-A, via hub" : "USB-A port"
        case .usbC:
            let viaHub = d.depth > 0 || scanner.result.usbDevices.contains {
                $0.controllerID == d.controllerID && $0.isHub && $0.id != d.id
            }
            return viaHub ? "USB-C, via hub" : "USB-C port"
        case .thunderbolt:
            return tbDisplayName != nil ? "on your \(displayShortName)" : "via Thunderbolt"
        case .unknown:
            return nil
        }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(dot).frame(width: 8, height: 8)
                Text(title).font(.system(.body, design: .rounded))
                Spacer()
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            if let advice {
                Text(advice)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.leading, 14)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
