import Foundation
import IOKit

/// Reads USB devices from the IOKit registry (via ioreg) and Thunderbolt
/// ports via system_profiler — the exact plumbing the speedcheck.py
/// prototype field-validated. v1 should move to the IOKit C API directly;
/// same data, no subprocess.
final class PeripheralScanner: ObservableObject {
    @Published var result = ScanResult()
    @Published var scanning = false

    // Eject state, keyed by locationID (stable while the device stays
    // plugged in, even after its media goes away post-eject).
    @Published var ejectingLocations: Set<Int> = []
    @Published var ejectedLocations: Set<Int> = []
    @Published var ejectErrors: [Int: String] = [:]

    // Per-drive volume capacity (free/total bytes) and live transfer
    // activity (bytes/sec), keyed by locationID. Activity is sampled only
    // while the menu is open — the idle-cost promise stands.
    @Published var capacities: [Int: (free: Int64, total: Int64)] = [:]
    @Published var activityBps: [Int: Double] = [:]
    private var mountPoints: [Int: String] = [:]
    private var activityTimer: Timer?
    private var lastBlockSample: (bytes: [String: Int64], at: Date)?

    // Measured speed-test state, also keyed by locationID.
    @Published var testingLocations: Set<Int> = []
    @Published var testResults: [Int: (write: Double, read: Double)] = [:]  // GB/s
    @Published var testErrors: [Int: String] = [:]

    private var timer: Timer?
    private var notifyPort: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var debounce: DispatchWorkItem?

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

    /// Called on every menu open: rescan immediately, and (once) arm
    /// IOKit attach/detach notifications so scans otherwise run only when
    /// hardware actually changes. A slow timer is kept as a safety net
    /// for anything the USB notifications can't see.
    func start() {
        scan()
        armNotifications()
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                self?.scan()
            }
        }
    }

    private func armNotifications() {
        guard notifyPort == nil,
              let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notifyPort = port
        IONotificationPortSetDispatchQueue(port, .main)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            var obj = IOIteratorNext(iterator)
            while obj != 0 { IOObjectRelease(obj); obj = IOIteratorNext(iterator) }
            guard let refcon else { return }
            Unmanaged<PeripheralScanner>.fromOpaque(refcon)
                .takeUnretainedValue().deviceEvent()
        }
        for kind in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iter: io_iterator_t = 0
            if IOServiceAddMatchingNotification(port, kind,
                                                IOServiceMatching("IOUSBHostDevice"),
                                                callback, refcon, &iter) == KERN_SUCCESS {
                // drain to arm the notification
                var obj = IOIteratorNext(iter)
                while obj != 0 { IOObjectRelease(obj); obj = IOIteratorNext(iter) }
                iterators.append(iter)
            }
        }
    }

    /// Devices settle in bursts (a hub brings several children) — collapse
    /// them into one scan a moment after the last event.
    private func deviceEvent() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scan() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// Synchronous scan for the snapshot tool — same pipeline, no queues.
    func scanSync() {
        var r = ScanResult()
        r.usbDevices = scanUSB()
        r.tbPorts = scanThunderbolt()
        r.modelId = Self.modelIdentifier()
        result = r
    }

    func scan() {
        guard !scanning else { return }
        scanning = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var r = ScanResult()
            r.usbDevices = self.scanUSB()
            r.modelId = Self.modelIdentifier()
            // Built-in SDXC slot (MacBook Pro) is PCIe, invisible to the
            // USB scan — read it separately and inject synthetic rows.
            if PortInventory.known[r.modelId]?.hasSDSlot == true {
                r.usbDevices += self.scanCardReaders()
            }
            r.tbPorts = self.scanThunderbolt()
            var caps: [Int: (free: Int64, total: Int64)] = [:]
            var mps: [Int: String] = [:]
            for d in r.usbDevices where d.isStorage {
                if let bsd = d.bsdName, let mp = self.mountPoint(forWholeDisk: bsd) {
                    mps[d.locationID] = mp
                    var fs = statfs()
                    if statfs(mp, &fs) == 0 {
                        caps[d.locationID] = (Int64(fs.f_bavail) * Int64(fs.f_bsize),
                                              Int64(fs.f_blocks) * Int64(fs.f_bsize))
                    }
                }
            }
            DispatchQueue.main.async {
                self.result = r
                self.scanning = false
                // forget eject/test state for devices that were unplugged
                let present = Set(r.usbDevices.map(\.locationID))
                self.ejectedLocations.formIntersection(present)
                self.ejectErrors = self.ejectErrors.filter { present.contains($0.key) }
                self.testResults = self.testResults.filter { present.contains($0.key) }
                self.testErrors = self.testErrors.filter { present.contains($0.key) }
                self.capacities = caps
                self.mountPoints = mps
            }
        }
    }

    /// Plain-text hardware fingerprint for debugging a Mac we've never
    /// seen: app/OS/model, every root USB controller with its device tree
    /// (names, speeds, locationIDs — no serial numbers), and the TB buses.
    func diagnosticReport() -> String {
        var lines = ["PeripheralSpeed v\(AppInfo.version)",
                     "Model: \(Self.modelIdentifier()) (\(result.inventory?.marketingName ?? "not in port database"))",
                     "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
                     "", "USB controllers:"]
        if let root = runPlist("/usr/sbin/ioreg", ["-p", "IOUSB", "-a", "-l"]) as? [String: Any] {
            func walk(_ n: [String: Any], indent: Int) {
                for k in n["IORegistryEntryChildren"] as? [[String: Any]] ?? [] {
                    let name = (k["USB Product Name"] as? String)
                        ?? (k["IORegistryEntryName"] as? String) ?? "?"
                    let vendor = (k["USB Vendor Name"] as? String).map { " [\($0)]" } ?? ""
                    let speed = (k["USBSpeed"] as? Int) ?? (k["Device Speed"] as? Int)
                    let loc = k["locationID"] as? Int ?? 0
                    lines.append(String(repeating: "  ", count: indent)
                        + "\(name)\(vendor) speed=\(speed.map(String.init) ?? "-")"
                        + String(format: " loc=0x%08x", loc))
                    walk(k, indent: indent + 1)
                }
            }
            for c in root["IORegistryEntryChildren"] as? [[String: Any]] ?? [] {
                let loc = c["locationID"] as? Int ?? 0
                lines.append("\(c["IOObjectClass"] as? String ?? "?")"
                    + String(format: " loc=0x%08x", loc))
                walk(c, indent: 1)
            }
        }
        lines.append("")
        lines.append("Thunderbolt buses:")
        for p in result.tbPorts {
            lines.append("  \(p.busName): \(p.speedText.isEmpty ? "-" : p.speedText)"
                + " devices=[\(p.deviceNames.joined(separator: ", "))]")
        }
        // Built-in SD reader (MacBook Pro) keys vary by macOS — capture raw.
        if let arr = runPlist("/usr/sbin/system_profiler",
                              ["-xml", "SPCardReaderDataType"]) as? [[String: Any]],
           let readers = arr.first?["_items"] as? [[String: Any]] {
            lines.append("")
            lines.append("Card readers (built-in SDXC):")
            for r in readers {
                lines.append("  reader keys: \(r.keys.sorted().joined(separator: ", "))")
                for c in r["_items"] as? [[String: Any]] ?? [] {
                    let kv = c.compactMap { k, v in (v is String || v is NSNumber) ? "\(k)=\(v)" : nil }
                    lines.append("    card: \(kv.sorted().joined(separator: " | "))")
                }
            }
        }
        return lines.joined(separator: "\n")
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

    /// locationID -> whole-disk BSD name, via the USB devices' IOService
    /// subtrees (the IOMedia node lives there, not in the IOUSB plane).
    /// ioreg nests a drive inside its hub's subtree, so the walk descends
    /// through nested USB devices and credits each disk to the INNERMOST
    /// device above it — a hub never claims a plugged-in drive's disk.
    private func bsdNames() -> [Int: String] {
        var map: [Int: String] = [:]
        guard let trees = runPlist("/usr/sbin/ioreg",
                                   ["-c", "IOUSBHostDevice", "-a", "-r", "-l"])
                as? [[String: Any]] else { return map }
        func walk(_ n: [String: Any], owner: Int?) {
            var owner = owner
            let cls = n["IOObjectClass"] as? String ?? ""
            if cls == "IOUSBHostDevice" || cls == "IOUSBDevice",
               let loc = n["locationID"] as? Int {
                owner = loc
            }
            if n["Whole"] as? Bool == true, let bsd = n["BSD Name"] as? String,
               let owner, map[owner] == nil {
                map[owner] = bsd
            }
            for c in n["IORegistryEntryChildren"] as? [[String: Any]] ?? [] {
                walk(c, owner: owner)
            }
        }
        for tree in trees { walk(tree, owner: nil) }
        return map
    }

    // MARK: - live transfer activity (menu-open only)

    func startActivity() {
        guard activityTimer == nil else { return }
        lastBlockSample = nil
        sampleActivity()
        activityTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.sampleActivity()
        }
    }

    func stopActivity() {
        activityTimer?.invalidate()
        activityTimer = nil
        activityBps = [:]
    }

    /// Cumulative read+write bytes per whole disk, from the block-storage
    /// driver statistics in the IO registry.
    private func blockBytes() -> [String: Int64] {
        var map: [String: Int64] = [:]
        guard let trees = runPlist("/usr/sbin/ioreg",
                                   ["-c", "IOBlockStorageDriver", "-a", "-r", "-l"])
                as? [[String: Any]] else { return map }
        func findBSD(_ n: [String: Any]) -> String? {
            if n["Whole"] as? Bool == true, let b = n["BSD Name"] as? String { return b }
            for c in n["IORegistryEntryChildren"] as? [[String: Any]] ?? [] {
                if let f = findBSD(c) { return f }
            }
            return nil
        }
        for t in trees {
            guard let stats = t["Statistics"] as? [String: Any],
                  let bsd = findBSD(t) else { continue }
            let read = (stats["Bytes (Read)"] as? NSNumber)?.int64Value ?? 0
            let write = (stats["Bytes (Write)"] as? NSNumber)?.int64Value ?? 0
            map[bsd] = read + write
        }
        return map
    }

    private func sampleActivity() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let now = Date()
            let bytes = self.blockBytes()
            let prev = self.lastBlockSample
            self.lastBlockSample = (bytes, now)
            guard let prev else { return }
            let dt = now.timeIntervalSince(prev.at)
            guard dt > 0.2 else { return }
            DispatchQueue.main.async {
                var act: [Int: Double] = [:]
                for d in self.result.usbDevices where d.isStorage {
                    if let bsd = d.bsdName, let cur = bytes[bsd],
                       let old = prev.bytes[bsd], cur > old {
                        act[d.locationID] = Double(cur - old) / dt
                    }
                }
                self.activityBps = act
                // live-refresh capacity so the bar moves while a copy runs
                for (loc, mp) in self.mountPoints {
                    var fs = statfs()
                    if statfs(mp, &fs) == 0 {
                        self.capacities[loc] = (Int64(fs.f_bavail) * Int64(fs.f_bsize),
                                                Int64(fs.f_blocks) * Int64(fs.f_bsize))
                    }
                }
            }
        }
    }

    /// diskutil eject: unmounts every volume and offlines the media —
    /// same as Finder's eject, refuses politely if files are open.
    func eject(_ bsd: String, location: Int) {
        ejectingLocations.insert(location)
        ejectErrors[location] = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
            p.arguments = ["eject", bsd]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            var ok = false
            do {
                try p.run()
                _ = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                ok = p.terminationStatus == 0
            } catch {}
            DispatchQueue.main.async {
                self?.ejectingLocations.remove(location)
                if ok {
                    self?.ejectedLocations.insert(location)
                } else {
                    self?.ejectErrors[location] =
                        "Couldn't eject — close any files open on it and try again."
                }
            }
        }
    }

    // MARK: - measured speed test

    /// First mounted volume living on the given whole disk — direct
    /// partitions or APFS volumes whose container's physical store is on it.
    private func mountPoint(forWholeDisk whole: String) -> String? {
        guard let dict = runPlist("/usr/sbin/diskutil", ["list", "-plist"]) as? [String: Any],
              let all = dict["AllDisksAndPartitions"] as? [[String: Any]] else { return nil }
        func mounts(_ vols: [[String: Any]]?) -> [String] {
            (vols ?? []).compactMap { $0["MountPoint"] as? String }
                .filter { $0.hasPrefix("/Volumes/") }
        }
        var points: [String] = []
        for d in all {
            let id = d["DeviceIdentifier"] as? String ?? ""
            let stores = (d["APFSPhysicalStores"] as? [[String: Any]])?
                .compactMap { $0["DeviceIdentifier"] as? String } ?? []
            let onThisDisk = id == whole || id.hasPrefix(whole + "s")
                || stores.contains { $0 == whole || $0.hasPrefix(whole + "s") }
            guard onThisDisk else { continue }
            points += mounts(d["Partitions"] as? [[String: Any]])
            points += mounts(d["APFSVolumes"] as? [[String: Any]])
        }
        return points.first
    }

    func speedTest(_ bsd: String, location: Int) {
        testingLocations.insert(location)
        testErrors[location] = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var result: (write: Double, read: Double)?
            var error: String?
            if let volume = self.mountPoint(forWholeDisk: bsd) {
                (result, error) = Self.measure(volume: volume)
            } else {
                error = "No mounted volume to test — is the drive ejected?"
            }
            DispatchQueue.main.async {
                self.testingLocations.remove(location)
                if let result { self.testResults[location] = result }
                if let error { self.testErrors[location] = error }
            }
        }
    }

    /// Write then re-read a temp file with the OS cache bypassed
    /// (F_NOCACHE), a few seconds each way. Returns GB/s.
    private static func measure(volume: String) -> ((write: Double, read: Double)?, String?) {
        var fs = statfs()
        guard statfs(volume, &fs) == 0 else { return (nil, "Couldn't inspect the drive.") }
        let avail = UInt64(fs.f_bavail) * UInt64(fs.f_bsize)
        let maxBytes = min(2 << 30, Int(avail / 2))
        guard maxBytes >= 64 << 20 else { return (nil, "Not enough free space to run a test.") }

        let path = volume + "/.peripheralspeed-test-\(UUID().uuidString)"
        let fd = open(path, O_CREAT | O_RDWR | O_TRUNC, 0o600)
        guard fd >= 0 else { return (nil, "This volume doesn't allow writing.") }
        defer { close(fd); unlink(path) }
        _ = fcntl(fd, F_NOCACHE, 1)

        let chunk = 8 << 20
        var buf = [UInt8](repeating: 0, count: chunk)
        arc4random_buf(&buf, chunk)

        let deadline: TimeInterval = 3
        var written = 0
        let wStart = Date()
        while Date().timeIntervalSince(wStart) < deadline && written < maxBytes {
            let n = write(fd, buf, chunk)
            if n <= 0 { return (nil, "Writing failed mid-test.") }
            written += n
        }
        fsync(fd)
        let wSecs = Date().timeIntervalSince(wStart)
        let writeGBps = Double(written) / wSecs / 1e9

        lseek(fd, 0, SEEK_SET)
        var readBytes = 0
        let rStart = Date()
        while readBytes < written {
            let n = read(fd, &buf, chunk)
            if n <= 0 { break }
            readBytes += n
        }
        let rSecs = max(Date().timeIntervalSince(rStart), 0.001)
        let readGBps = Double(readBytes) / rSecs / 1e9
        return ((write: writeGBps, read: readGBps), nil)
    }

    /// The built-in SDXC slot (MacBook Pro) is PCIe, not USB. Read it via
    /// SPCardReaderDataType and synthesize storage rows so the rest of the
    /// app (capacity, eject, speed test) treats an inserted card like any
    /// other drive. bsd/volume come straight from the reader report.
    private func scanCardReaders() -> [USBDevice] {
        guard let arr = runPlist("/usr/sbin/system_profiler",
                                 ["-xml", "SPCardReaderDataType"]) as? [[String: Any]],
              let readers = arr.first?["_items"] as? [[String: Any]] else { return [] }
        // Whole-disk BSD like "disk8" (not a partition "disk8s1"), from any
        // key containing "bsd" — the report's key names vary by macOS.
        func wholeDiskBSD(_ card: [String: Any]) -> String? {
            let bsds = card.compactMap { k, v -> String? in
                guard k.lowercased().contains("bsd"), let s = v as? String,
                      s.hasPrefix("disk") else { return nil }
                // trim any partition suffix: disk8s1 -> disk8
                if let r = s.range(of: #"^disk\d+"#, options: .regularExpression) {
                    return String(s[r])
                }
                return s
            }
            return bsds.first
        }
        var out: [USBDevice] = []
        var idx = 0
        for reader in readers {
            let cards = reader["_items"] as? [[String: Any]] ?? []
            if cards.isEmpty {
                out.append(sdDevice(name: "SD card slot", bsd: nil, index: idx)); idx += 1
                continue
            }
            for card in cards {
                let disk = wholeDiskBSD(card)
                let volName = disk.flatMap { mountPoint(forWholeDisk: $0) }
                    .map { URL(fileURLWithPath: $0).lastPathComponent }
                out.append(sdDevice(name: volName ?? "SD card", bsd: disk,
                                    specMbps: Self.sdSpecMbps(card), index: idx))
                idx += 1
            }
        }
        return out
    }

    private func sdDevice(name: String, bsd: String?, specMbps: Double? = nil,
                          index: Int) -> USBDevice {
        USBDevice(name: name, vendor: nil, speedMbps: specMbps, speedLabel: "SD card slot",
                  isStorage: true, isHub: false, depth: 0, bus: .builtInSD,
                  locationID: 0x5D_0000 + index, controllerID: -2, bsdName: bsd)
    }

    /// A card's real-world speed ceiling from its SD spec version, encoded
    /// as the app's link-Mbps (÷10 000 = GB/s). SD reports MB/s-class buses,
    /// not a bit link, so we set the value to land on the right GB/s:
    /// UHS-I (spec 3.x) ≈ 0.1 GB/s, UHS-II (4.x+) ≈ 0.3 GB/s. Cards vary
    /// below this — it's an "up to"; the gauge measures the truth.
    static func sdSpecMbps(_ card: [String: Any]) -> Double? {
        let spec = (card["spcardreader_card_specversion"] as? String) ?? ""
        let gbps: Double?
        switch spec.first {
        case "6", "7": gbps = 0.6   // SD Express-era
        case "4", "5": gbps = 0.3   // UHS-II
        case "3":      gbps = 0.1   // UHS-I
        case "1", "2": gbps = 0.025 // High Speed
        default:       gbps = nil
        }
        return gbps.map { $0 * 10_000 }
    }

    private func scanUSB() -> [USBDevice] {
        guard let root = runPlist("/usr/sbin/ioreg", ["-p", "IOUSB", "-a", "-l"])
                as? [String: Any] else { return [] }
        let storageLocs = storageLocations()
        let disks = bsdNames()
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
            let rawName = (n["USB Product Name"] as? String)
                ?? (n["IORegistryEntryName"] as? String) ?? "?"
            // USB Billboard Devices (bDeviceClass 0x11) are alt-mode
            // negotiation artifacts, not real peripherals — skip entirely.
            let isBillboard = (n["bDeviceClass"] as? Int == 0x11)
                || rawName.localizedCaseInsensitiveContains("billboard")
            if let speed, !isBillboard {
                let name = rawName
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
                    locationID: loc ?? 0,
                    controllerID: controller,
                    bsdName: storage ? loc.flatMap { disks[$0] } : nil))
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
        // Apple Silicon has no built-in EHCI/OHCI — those only arrive
        // tunneled behind Thunderbolt (e.g. Pro Display XDR's USB2 side).
        if controllerClass.contains("EHCI") || controllerClass.contains("OHCI") { return .thunderbolt }
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
