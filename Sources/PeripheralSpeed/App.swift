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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Peripheral Speed").font(.headline)
                Spacer()
                if scanner.scanning {
                    ProgressView().controlSize(.small)
                }
            }

            if scanner.result.usbDevices.isEmpty && scanner.result.tbPorts.isEmpty {
                Text("Scanning…").foregroundStyle(.secondary)
            }

            if !scanner.result.usbDevices.isEmpty {
                Text("USB").font(.caption).foregroundStyle(.secondary)
                ForEach(scanner.result.usbDevices) { d in
                    DeviceRow(dot: color(d.verdict),
                              title: d.name,
                              subtitle: d.speedLabel + (d.isHub ? "  · hub" : "")
                                        + (d.isStorage ? "  · drive" : ""),
                              advice: d.advice)
                }
            }

            if !scanner.result.tbPorts.isEmpty {
                Text("Thunderbolt / USB4").font(.caption).foregroundStyle(.secondary)
                ForEach(scanner.result.tbPorts) { p in
                    DeviceRow(dot: color(p.verdict),
                              title: p.deviceNames.first ?? "Empty port",
                              subtitle: p.speedText.isEmpty ? p.busName : p.speedText,
                              advice: p.advice)
                }
            }

            let issues = scanner.result.bottlenecks
            if !issues.isEmpty {
                Divider()
                Label("\(issues.count) bottleneck\(issues.count == 1 ? "" : "s") found",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            } else if !scanner.result.usbDevices.isEmpty {
                Divider()
                Label("No bottlenecks — every link is healthy",
                      systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            }

            Divider()
            HStack {
                Button("Rescan") { scanner.scan() }
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
