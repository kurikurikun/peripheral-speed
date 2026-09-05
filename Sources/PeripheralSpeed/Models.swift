import Foundation

enum Verdict {
    case good       // healthy link
    case caution    // worth checking (e.g. 5 Gb/s drive that might be rated 10)
    case bad        // real bottleneck with a known fix
}

struct USBDevice: Identifiable {
    let id = UUID()
    let name: String
    let vendor: String?
    let speedMbps: Double?
    let speedLabel: String
    let isStorage: Bool
    let isHub: Bool
    /// hops from a physical Mac port: 0 = plugged straight into the Mac,
    /// 1 = plugged into a hub/dock/display, 2 = hub behind a hub, …
    var depth: Int = 0

    var verdict: Verdict {
        guard let mbps = speedMbps else { return .good }
        if isStorage && mbps <= 480 { return .bad }
        if isStorage && mbps == 5_000 { return .caution }
        return .good
    }

    var advice: String? {
        switch verdict {
        case .bad:
            return "Drive stuck at USB 2 speed — swap the cable for one marked 10Gbps/SS, or plug it straight into the Mac."
        case .caution:
            return "Linked at 5 Gb/s. Fine for 5 Gb/s drives; if this SSD is rated 10 Gb/s, the cable or hub is halving it."
        case .good:
            return nil
        }
    }
}

struct TBPort: Identifiable {
    let id = UUID()
    let busName: String
    let speedText: String       // e.g. "Up to 40 Gb/s x1", or a status when empty
    let deviceNames: [String]
    let gbps: Double?

    var verdict: Verdict {
        guard let g = gbps else { return .good }
        return g <= 20 ? .caution : .good
    }

    var advice: String? {
        verdict == .caution
            ? "Linked at \(Int(gbps ?? 0)) Gb/s on a 40 Gb/s-capable port — usually a passive cable over 0.8 m or a plain USB-C cable. Use a Thunderbolt-certified cable (lightning-bolt logo)."
            : nil
    }
}

struct ScanResult {
    var usbDevices: [USBDevice] = []
    var tbPorts: [TBPort] = []
    var scannedAt: Date = .init()

    var bottlenecks: [String] {
        var out: [String] = []
        for d in usbDevices where d.verdict == .bad {
            out.append("\(d.name): \(d.advice ?? "")")
        }
        for d in usbDevices where d.verdict == .caution {
            out.append("\(d.name): \(d.advice ?? "")")
        }
        for p in tbPorts where p.verdict == .caution {
            out.append("\(p.busName): \(p.advice ?? "")")
        }
        return out
    }

    var worstVerdict: Verdict {
        if usbDevices.contains(where: { $0.verdict == .bad }) { return .bad }
        if usbDevices.contains(where: { $0.verdict == .caution })
            || tbPorts.contains(where: { $0.verdict == .caution }) { return .caution }
        return .good
    }
}
