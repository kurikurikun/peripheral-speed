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
/// Counts and speeds from Apple's tech-specs pages per model identifier.
struct PortInventory {
    let marketingName: String
    let usbC: Int       // USB-C ports of any flavor (Thunderbolt or not)
    let usbA: Int
    let usbAGbps: Int   // link speed the USB-A ports run at
    /// Custom free-USB-C subtitle for machines whose USB-C ports differ
    /// from the usual "Thunderbolt, ≈ 2–3 GB/s for a drive" story.
    var usbCLabel: String? = nil
    /// false on Macs with no Thunderbolt at all (MacBook Neo) — free-port
    /// counting then can't lean on the Thunderbolt bus report.
    var hasThunderbolt: Bool = true
    /// Per-port breakdown for machines whose USB-C ports are NOT equal,
    /// named by physical position so the user knows which hole is which.
    var usbCPorts: [USBCPort]? = nil
}

struct USBCPort {
    let label: String     // physical position, e.g. "left"
    let linkMbps: Double
}

extension PortInventory {
    static let known: [String: PortInventory] = {
        var t: [String: PortInventory] = [:]
        func add(_ ids: [String], _ inv: PortInventory) { for id in ids { t[id] = inv } }

        // MacBook Air
        add(["MacBookAir10,1"], .init(marketingName: "MacBook Air (M1)", usbC: 2, usbA: 0, usbAGbps: 0))
        add(["Mac14,2"], .init(marketingName: "MacBook Air 13″ (M2)", usbC: 2, usbA: 0, usbAGbps: 0))
        add(["Mac14,15"], .init(marketingName: "MacBook Air 15″ (M2)", usbC: 2, usbA: 0, usbAGbps: 0))
        add(["Mac15,12"], .init(marketingName: "MacBook Air 13″ (M3)", usbC: 2, usbA: 0, usbAGbps: 0))
        add(["Mac15,13"], .init(marketingName: "MacBook Air 15″ (M3)", usbC: 2, usbA: 0, usbAGbps: 0))
        add(["Mac16,12"], .init(marketingName: "MacBook Air 13″ (M4)", usbC: 2, usbA: 0, usbAGbps: 0))
        add(["Mac16,13"], .init(marketingName: "MacBook Air 15″ (M4)", usbC: 2, usbA: 0, usbAGbps: 0))
        add(["Mac17,3"], .init(marketingName: "MacBook Air 13″ (M5)", usbC: 2, usbA: 0, usbAGbps: 0))
        add(["Mac17,4"], .init(marketingName: "MacBook Air 15″ (M5)", usbC: 2, usbA: 0, usbAGbps: 0))

        // MacBook Neo — no Thunderbolt; the two ports are NOT equal
        // (Apple tech specs: left = USB 3 10 Gb/s, right = USB 2 480 Mb/s)
        add(["Mac17,5"], .init(marketingName: "MacBook Neo", usbC: 2, usbA: 0, usbAGbps: 0,
            hasThunderbolt: false,
            usbCPorts: [USBCPort(label: "left", linkMbps: 10_000),
                        USBCPort(label: "right", linkMbps: 480)]))

        // MacBook Pro
        add(["MacBookPro17,1"], .init(marketingName: "MacBook Pro 13″ (M1)", usbC: 2, usbA: 0, usbAGbps: 0))
        add(["MacBookPro18,3", "MacBookPro18,4"], .init(marketingName: "MacBook Pro 14″ (M1 Pro/Max)", usbC: 3, usbA: 0, usbAGbps: 0))
        add(["MacBookPro18,1", "MacBookPro18,2"], .init(marketingName: "MacBook Pro 16″ (M1 Pro/Max)", usbC: 3, usbA: 0, usbAGbps: 0))
        add(["Mac14,7"], .init(marketingName: "MacBook Pro 13″ (M2)", usbC: 2, usbA: 0, usbAGbps: 0))
        add(["Mac14,5", "Mac14,6"], .init(marketingName: "MacBook Pro 14″ (M2 Pro/Max)", usbC: 3, usbA: 0, usbAGbps: 0))
        add(["Mac14,9", "Mac14,10"], .init(marketingName: "MacBook Pro 16″ (M2 Pro/Max)", usbC: 3, usbA: 0, usbAGbps: 0))
        add(["Mac15,3"], .init(marketingName: "MacBook Pro 14″ (M3)", usbC: 2, usbA: 0, usbAGbps: 0))
        add(["Mac15,6", "Mac15,8", "Mac15,10"], .init(marketingName: "MacBook Pro 14″ (M3 Pro/Max)", usbC: 3, usbA: 0, usbAGbps: 0))
        add(["Mac15,7", "Mac15,9", "Mac15,11"], .init(marketingName: "MacBook Pro 16″ (M3 Pro/Max)", usbC: 3, usbA: 0, usbAGbps: 0))
        add(["Mac16,1"], .init(marketingName: "MacBook Pro 14″ (M4)", usbC: 3, usbA: 0, usbAGbps: 0))
        add(["Mac16,6", "Mac16,8"], .init(marketingName: "MacBook Pro 14″ (M4 Pro/Max)", usbC: 3, usbA: 0, usbAGbps: 0))
        add(["Mac16,5", "Mac16,7"], .init(marketingName: "MacBook Pro 16″ (M4 Pro/Max)", usbC: 3, usbA: 0, usbAGbps: 0))
        add(["Mac17,2"], .init(marketingName: "MacBook Pro 14″ (M5)", usbC: 3, usbA: 0, usbAGbps: 0))
        add(["Mac17,7", "Mac17,9"], .init(marketingName: "MacBook Pro 14″ (M5 Pro/Max)", usbC: 3, usbA: 0, usbAGbps: 0))
        add(["Mac17,6", "Mac17,8"], .init(marketingName: "MacBook Pro 16″ (M5 Pro/Max)", usbC: 3, usbA: 0, usbAGbps: 0))

        // Mac mini
        add(["Macmini9,1"], .init(marketingName: "Mac mini (M1)", usbC: 2, usbA: 2, usbAGbps: 5))
        add(["Mac14,3"], .init(marketingName: "Mac mini (M2)", usbC: 2, usbA: 2, usbAGbps: 5))
        add(["Mac14,12"], .init(marketingName: "Mac mini (M2 Pro)", usbC: 4, usbA: 2, usbAGbps: 5))
        add(["Mac16,10"], .init(marketingName: "Mac mini (M4)", usbC: 5, usbA: 0, usbAGbps: 0))
        add(["Mac16,11"], .init(marketingName: "Mac mini (M4 Pro)", usbC: 5, usbA: 0, usbAGbps: 0))
        add(["Mac17,16", "Mac18,5"], .init(marketingName: "Mac mini (2026)", usbC: 5, usbA: 0, usbAGbps: 0))

        // iMac
        add(["iMac21,1"], .init(marketingName: "iMac 24″ (M1)", usbC: 4, usbA: 0, usbAGbps: 0))
        add(["iMac21,2"], .init(marketingName: "iMac 24″ (M1)", usbC: 2, usbA: 0, usbAGbps: 0))
        add(["Mac15,4"], .init(marketingName: "iMac 24″ (M3)", usbC: 2, usbA: 0, usbAGbps: 0))
        add(["Mac15,5"], .init(marketingName: "iMac 24″ (M3)", usbC: 4, usbA: 0, usbAGbps: 0))
        add(["Mac16,2"], .init(marketingName: "iMac 24″ (M4)", usbC: 4, usbA: 0, usbAGbps: 0))
        add(["Mac16,3"], .init(marketingName: "iMac 24″ (M4)", usbC: 2, usbA: 0, usbAGbps: 0))

        // Mac Studio / Mac Pro
        add(["Mac13,1"], .init(marketingName: "Mac Studio (M1 Max)", usbC: 6, usbA: 2, usbAGbps: 10))
        add(["Mac13,2"], .init(marketingName: "Mac Studio (M1 Ultra)", usbC: 6, usbA: 2, usbAGbps: 10))
        add(["Mac14,13"], .init(marketingName: "Mac Studio (M2 Max)", usbC: 6, usbA: 2, usbAGbps: 10))
        add(["Mac14,14"], .init(marketingName: "Mac Studio (M2 Ultra)", usbC: 6, usbA: 2, usbAGbps: 10))
        add(["Mac16,9"], .init(marketingName: "Mac Studio (M4 Max)", usbC: 6, usbA: 2, usbAGbps: 10))
        add(["Mac15,14"], .init(marketingName: "Mac Studio (M3 Ultra)", usbC: 6, usbA: 2, usbAGbps: 10))
        add(["Mac17,14", "Mac17,15"], .init(marketingName: "Mac Studio (M5)", usbC: 6, usbA: 2, usbAGbps: 10))
        add(["Mac14,8"], .init(marketingName: "Mac Pro (M2 Ultra)", usbC: 8, usbA: 2, usbAGbps: 10))

        return t
    }()
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
