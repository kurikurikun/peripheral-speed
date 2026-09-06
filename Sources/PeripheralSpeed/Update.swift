import Foundation
import Security

/// Checks GitHub Releases for a newer version — on launch and once a day.
/// Public API, no auth, fails silently offline.
final class UpdateChecker: ObservableObject {
    @Published var latest: (version: String, url: String)?
    @Published var updating = false
    @Published var updateError: String?

    private var timer: Timer?
    private static let releasesAPI =
        "https://api.github.com/repos/kurikurikun/peripheral-speed/releases/latest"

    func start() {
        guard timer == nil else { return }
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            self?.check()
        }
    }

    func check() {
        guard let url = URL(string: Self.releasesAPI) else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String,
                  let html = obj["html_url"] as? String else { return }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            guard Self.isNewer(version, than: AppInfo.version) else { return }
            DispatchQueue.main.async { self?.latest = (version, html) }
        }.resume()
    }

    /// Download the latest release, verify it is OUR signed app, swap it
    /// into place, relaunch. Any failure leaves the current install intact.
    func installUpdate() {
        guard !updating else { return }
        updating = true
        updateError = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let error = Self.performUpdate()
            DispatchQueue.main.async {
                self?.updating = false
                self?.updateError = error   // on success we never get here
            }
        }
    }

    static let downloadURL =
        "https://github.com/kurikurikun/peripheral-speed/releases/latest/download/PeripheralSpeed.zip"
    static let teamID = "PNDN4CQY5T"

    static func performUpdate() -> String? {
        let currentPath = Bundle.main.bundlePath
        guard currentPath.hasSuffix("PeripheralSpeed.app") else {
            return "Not running from an installed app — update manually."
        }
        // download
        guard let url = URL(string: downloadURL) else { return "Bad update URL." }
        let sem = DispatchSemaphore(value: 0)
        var zipData: Data?
        URLSession.shared.dataTask(with: url) { data, resp, _ in
            if let http = resp as? HTTPURLResponse, http.statusCode == 200 { zipData = data }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 120)
        guard let zipData, zipData.count > 100_000 else {
            return "Couldn't download the update — check your connection."
        }
        // unpack
        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("psupdate-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let zipPath = work.appendingPathComponent("update.zip")
        do { try zipData.write(to: zipPath) } catch { return "Couldn't save the update." }
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-xk", zipPath.path, work.path]
        try? unzip.run()
        unzip.waitUntilExit()
        let newApp = work.appendingPathComponent("PeripheralSpeed.app")
        guard FileManager.default.fileExists(atPath: newApp.path) else {
            return "Update package looked wrong — not installed."
        }
        // verify: valid signature AND our Developer ID team, or we refuse
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(newApp as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else { return "Couldn't inspect the update's signature." }
        var requirement: SecRequirement?
        let req = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\"" as CFString
        guard SecRequirementCreateWithString(req, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures),
                                         requirement) == errSecSuccess else {
            return "Update failed signature verification — not installed."
        }
        // swap: old aside (running process keeps its inode), new in place
        let aside = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("psold-\(UUID().uuidString).app")
        do {
            try FileManager.default.moveItem(atPath: currentPath, toPath: aside.path)
        } catch { return "Couldn't replace the installed app: \(error.localizedDescription)" }
        do {
            try FileManager.default.moveItem(at: newApp, to: URL(fileURLWithPath: currentPath))
        } catch {
            try? FileManager.default.moveItem(atPath: aside.path, toPath: currentPath)
            return "Install failed; the old version was kept."
        }
        try? FileManager.default.removeItem(at: aside)
        // relaunch the new version and bow out
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-n", currentPath]
        try? open.run()
        DispatchQueue.main.async { exit(0) }
        return nil
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
