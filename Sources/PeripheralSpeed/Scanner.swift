import Foundation

/// Reads USB devices from the IOKit registry (via ioreg) and Thunderbolt
/// ports via system_profiler — the exact plumbing the speedcheck.py
/// prototype field-validated. v1 should move to the IOKit C API directly;
/// same data, no subprocess.
final class PeripheralScanner: ObservableObject {
    @Published var result = ScanResult()
    @Published var scanning = false

    private var timer: Timer?

    // ioreg speed codes -> (Mb/s, label). Two families, two maps.
    private static let hostSpeeds: [Int: (Double, String)] = [
        1: (1.5, "USB 1.0 — 1.5 Mb/s"), 2: (12, "USB 1.1 — 12 Mb/s"),
        3: (480, "USB 2.0 — 480 Mb/s"), 4: (5_000, "USB 3 — 5 Gb/s"),
        5: (10_000, "USB 3 — 10 Gb/s"), 6: (20_000, "USB 3 — 20 Gb/s"),
    ]
    private static let legacySpeeds: [Int: (Double, String)] = [
        0: (1.5, "USB 1.0 — 1.5 Mb/s"), 1: (12, "USB 1.1 — 12 Mb/s"),
        2: (480, "USB 2.0 — 480 Mb/s"), 3: (5_000, "USB 3 — 5 Gb/s"),
        4: (10_000, "USB 3 — 10 Gb/s"), 5: (20_000, "USB 3 — 20 Gb/s"),
    ]

    func start() {
        scan()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.scan()
        }
    }

    func scan() {
        guard !scanning else { return }
        scanning = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var r = ScanResult()
            r.usbDevices = self.scanUSB()
            r.tbPorts = self.scanThunderbolt()
            r.modelId = Self.modelIdentifier()
            DispatchQueue.main.async {
                self.result = r
                self.scanning = false
            }
        }
    }

    // MARK: - subprocess + plist helpers

    private func runPlist(_ path: String, _ args: [String]) -> Any? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do {
            try p.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard !data.isEmpty else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil)
    }

    // MARK: - USB via IOKit registry

    /// locationIDs of devices exposing a mass-storage interface (class 8).
    /// Interfaces live in the IOService plane, matched by locationID.
    private func storageLocations() -> Set<Int> {
        var locs = Set<Int>()
        for cls in ["IOUSBHostInterface", "IOUSBInterface"] {
            guard let trees = runPlist("/usr/sbin/ioreg", ["-c", cls, "-a", "-r", "-l"])
                    as? [[String: Any]] else { continue }
            func visit(_ n: [String: Any]) {
                if n["bInterfaceClass"] as? Int == 8, let loc = n["locationID"] as? Int {
                    locs.insert(loc)
                }
                for c in n["IORegistryEntryChildren"] as? [[String: Any]] ?? [] { visit(c) }
            }
            trees.forEach(visit)
            if !locs.isEmpty { break }
        }
        return locs
    }

    private func scanUSB() -> [USBDevice] {
        guard let root = runPlist("/usr/sbin/ioreg", ["-p", "IOUSB", "-a", "-l"])
                as? [String: Any] else { return [] }
        let storageLocs = storageLocations()
        var devices: [USBDevice] = []

        func isDevice(_ n: [String: Any]) -> Bool {
            n["USBSpeed"] != nil || n["Device Speed"] != nil
        }

        func hasMassStorage(_ n: [String: Any]) -> Bool {
            if n["bInterfaceClass"] as? Int == 8 { return true }
            for c in n["IORegistryEntryChildren"] as? [[String: Any]] ?? []
            where !isDevice(c) {
                if hasMassStorage(c) { return true }
            }
            return false
        }

        // DFS keeps a device right after the hub it hangs off; depth counts
        // device-node ancestors, so depth 0 = a physical Mac port.
        func visit(_ n: [String: Any], depth: Int, bus: USBBus, controller: Int) {
            var speed: (Double, String)? = nil
            if let code = n["USBSpeed"] as? Int {
                speed = Self.hostSpeeds[code]
            } else if let code = n["Device Speed"] as? Int {
                speed = Self.legacySpeeds[code]
            }
            var childDepth = depth
            if let speed {
                let name = (n["USB Product Name"] as? String)
                    ?? (n["IORegistryEntryName"] as? String) ?? "?"
                let loc = n["locationID"] as? Int
                let storage = hasMassStorage(n) || (loc.map { storageLocs.contains($0) } ?? false)
                let hub = (n["bDeviceClass"] as? Int == 9)
                    || name.lowercased().contains("hub")
                devices.append(USBDevice(
                    name: name,
                    vendor: n["USB Vendor Name"] as? String,
                    speedMbps: speed.0,
                    speedLabel: speed.1,
                    isStorage: storage,
                    isHub: hub,
                    depth: depth,
                    bus: bus,
                    controllerID: controller))
                childDepth = depth + 1
            }
            for c in n["IORegistryEntryChildren"] as? [[String: Any]] ?? [] {
                visit(c, depth: childDepth, bus: bus, controller: controller)
            }
        }
        // Root children are the host controllers; their class names say
        // which physical wiring they serve (see USBBus).
        let controllers = root["IORegistryEntryChildren"] as? [[String: Any]] ?? []
        for (i, c) in controllers.enumerated() {
            let cls = (c["IOObjectClass"] as? String) ?? ""
            visit(c, depth: 0, bus: Self.busKind(cls), controller: i)
        }
        return devices
    }

    static func busKind(_ controllerClass: String) -> USBBus {
        if controllerClass.contains("XHCITR") { return .thunderbolt }
        if controllerClass.contains("EmbeddedUSBXHCIFL") { return .usbA }
        if controllerClass.contains("USBXHCI") { return .usbC }
        return .unknown
    }

    static func modelIdentifier() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    // MARK: - Thunderbolt via system_profiler

    private func scanThunderbolt() -> [TBPort] {
        guard let arr = runPlist("/usr/sbin/system_profiler",
                                 ["-xml", "SPThunderboltDataType"]) as? [[String: Any]],
              let items = arr.first?["_items"] as? [[String: Any]] else { return [] }
        var ports: [TBPort] = []
        for bus in items {
            let busName = bus["_name"] as? String ?? "Thunderbolt Bus"
            var speedText = ""
            for (k, v) in bus {
                if k.lowercased().contains("receptacle"), let tag = v as? [String: Any] {
                    for (tk, tv) in tag {
                        let lk = tk.lowercased()
                        if lk.contains("speed"), let s = tv as? String { speedText = s }
                        if speedText.isEmpty, lk.contains("status"),
                           let s = tv as? String { speedText = s }
                    }
                }
            }
            var names: [String] = []
            func collect(_ n: [String: Any]) {
                if let dn = (n["device_name_key"] as? String) ?? (n["_name"] as? String) {
                    let vn = n["vendor_name_key"] as? String
                    names.append([vn, dn].compactMap { $0 }.joined(separator: " "))
                }
                for c in n["_items"] as? [[String: Any]] ?? [] { collect(c) }
            }
            for c in bus["_items"] as? [[String: Any]] ?? [] { collect(c) }
            ports.append(TBPort(
                busName: busName,
                speedText: speedText,
                deviceNames: names,
                gbps: Self.parseGbps(speedText)))
        }
        return ports
    }

    static func parseGbps(_ text: String) -> Double? {
        let tokens = text.replacingOccurrences(of: "/", with: " ")
            .split(separator: " ").map(String.init)
        for (i, tok) in tokens.enumerated() {
            let l = tok.lowercased()
            if (l == "gb" || l == "gbps" || l == "gb/s"), i > 0 {
                return Double(tokens[i - 1])
            }
        }
        return nil
    }
}
