import Foundation

/// Checks GitHub Releases for a newer version — on launch and once a day.
/// Public API, no auth, fails silently offline.
final class UpdateChecker: ObservableObject {
    @Published var latest: (version: String, url: String)?

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
