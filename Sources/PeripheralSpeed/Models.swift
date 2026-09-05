import Foundation

enum Verdict {
    case good       // healthy link
    case caution    // worth checking (e.g. 5 Gb/s drive that might be rated 10)
    case bad        // real bottleneck with a known fix
}

/// Every user-facing number is a real-world copy speed in GB/s — one unit
/// everywhere, so values compare at a glance. Link rates come in bits/s
/// (Mb/Gb); dividing by 10 covers the bit→byte conversion plus protocol
/// overhead, then ÷1000 lands on GB/s.
enum Speed {
    static func gbCopy(linkMbps: Double) -> String {
        let gb = linkMbps / 10 / 1_000
        return gb >= 0.095 ? String(format: "%.1f GB/s", gb)
                           : String(format: "%.2f GB/s", gb)
    }
}

/// Which physical wiring a USB device entered the Mac through. On Apple
/// Silicon each root controller class gives it away: the Fresco Logic
/// controller drives the USB-A ports, AppleT####USBXHCI is a built-in
/// USB-C port's USB side, and AppleUSBXHCITR is tunneled over Thunderbolt
/// (i.e. behind a dock or display).
enum USBBus {
    case usbA, usbC, thunderbolt, unknown
}

/// What ports a given Mac model physically has — macOS can't enumerate
/// empty USB-A ports, but it does know what machine it is.
struct PortInventory {
    let marketingName: String
    let usbC: Int       // USB-C / Thunderbolt ports
    let usbA: Int
    let usbAGbps: Int   // link speed the USB-A ports run at

    static let known: [String: PortInventory] = [
        "Macmini9,1": .init(marketingName: "Mac mini (M1)", usbC: 2, usbA: 2, usbAGbps: 5),
        "Mac14,3": .init(marketingName: "Mac mini (M2)", usbC: 2, usbA: 2, usbAGbps: 5),
        "Mac14,12": .init(marketingName: "Mac mini (M2 Pro)", usbC: 4, usbA: 2, usbAGbps: 5),
        "Mac16,10": .init(marketingName: "Mac mini (M4)", usbC: 5, usbA: 0, usbAGbps: 0),
        "Mac16,11": .init(marketingName: "Mac mini (M4 Pro)", usbC: 5, usbA: 0, usbAGbps: 0),
        "Mac13,1": .init(marketingName: "Mac Studio (M1 Max)", usbC: 6, usbA: 2, usbAGbps: 10),
        "Mac13,2": .init(marketingName: "Mac Studio (M1 Ultra)", usbC: 6, usbA: 2, usbAGbps: 10),
    ]
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
    var bus: USBBus = .unknown
    /// IOKit locationID: top byte is the bus, then one nibble per hub port
    /// hop — the physical path to the socket the device is in.
    var locationID: Int = 0
    /// index of the root controller this device hangs off — on Apple
    /// Silicon one USB-C controller == one physical port, so siblings
    /// sharing a controllerID share a physical port.
    var controllerID: Int = -1

    var verdict: Verdict {
        guard let mbps = speedMbps else { return .good }
        if isStorage && mbps <= 480 { return .bad }
        if isStorage && mbps == 5_000 { return .caution }
        return .good
    }

    var advice: String? {
        switch verdict {
        case .bad:
            return "Stuck at ≈ 0.05 GB/s (old-USB speed) — swap the cable for one marked 10Gbps/SS, or plug it straight into the Mac."
        case .caution:
            return "Running at ≈ 0.5 GB/s. Fine for cheaper drives; if this SSD is rated ≈ 1 GB/s, the cable or hub is halving it."
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
            ? "This link moves ≈ \(Speed.gbCopy(linkMbps: (gbps ?? 0) * 1_000)) instead of ≈ 3 GB/s — usually a passive cable over 0.8 m or a plain USB-C cable. Use a Thunderbolt-certified cable (lightning-bolt logo)."
            : nil
    }
}

struct ScanResult {
    var usbDevices: [USBDevice] = []
    var tbPorts: [TBPort] = []
    var modelId: String = ""
    var scannedAt: Date = .init()

    var inventory: PortInventory? { PortInventory.known[modelId] }

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
