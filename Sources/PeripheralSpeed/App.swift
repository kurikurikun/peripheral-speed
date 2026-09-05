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

    private var hasNestedDevices: Bool {
        scanner.result.usbDevices.contains { $0.depth > 0 }
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

                if !scanner.result.tbPorts.isEmpty {
                    section("Your Mac's USB-C / Thunderbolt ports") {
                        ForEach(scanner.result.tbPorts) { p in
                            if let name = p.deviceNames.first {
                                DeviceRow(dot: color(p.verdict),
                                          title: name,
                                          subtitle: tbSubtitle(p),
                                          advice: p.advice)
                            } else {
                                DeviceRow(dot: .gray,
                                          title: "Nothing plugged in",
                                          subtitle: "free port · up to 40 Gb/s",
                                          advice: nil)
                            }
                        }
                    }
                }

                if !scanner.result.usbDevices.isEmpty {
                    section("USB — what's plugged into what") {
                        ForEach(scanner.result.usbDevices) { d in
                            DeviceRow(dot: dot(for: d),
                                      title: d.name,
                                      subtitle: usbSubtitle(d),
                                      advice: d.advice,
                                      indent: d.depth)
                                .help(d.speedLabel)
                        }
                        if hasNestedDevices {
                            Text("Indented items are plugged into the hub, dock, or display above them. Empty ports on hubs and displays can't be seen — macOS only reports what's plugged in.")
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
        if d.isHub { return "its ports share \(shortSpeed(mbps))" }
        return d.speedLabel
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
