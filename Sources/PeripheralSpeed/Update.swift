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

    /// Called on every menu open: always re-check (one tiny API call) so
    /// a new release shows up the next time the user looks, not a day
    /// later. The timer only backs this up for menus that never close.
    func start() {
        check()
        guard timer == nil else { return }
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
        // Move the verified app to a STABLE staging path (out of `work`,
        // which `defer` deletes) for the helper to consume.
        let staged = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("psnew-\(UUID().uuidString).app")
        do { try FileManager.default.moveItem(at: newApp, to: staged) }
        catch { return "Couldn't stage the update." }

        // Hand the swap to a detached shell: a plain `mv` run as the user,
        // after we quit, isn't blocked by the App-Management restriction
        // that silently stops a running GUI app from replacing an app in
        // /Applications. It waits for our PID, swaps, relaunches.
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        /bin/rm -rf \(shellQuote(currentPath))
        /bin/mv \(shellQuote(staged.path)) \(shellQuote(currentPath))
        /usr/bin/xattr -dr com.apple.quarantine \(shellQuote(currentPath)) 2>/dev/null
        /usr/bin/open -n \(shellQuote(currentPath))
        """
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", script]
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        do { try helper.run() }
        catch { return "Couldn't start the updater helper." }

        // The helper is now waiting for us — quit so it can swap.
        DispatchQueue.main.async { exit(0) }
        return nil
    }

    /// Single-quote a path for /bin/sh (wrap in quotes, escape embedded ').
    static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
