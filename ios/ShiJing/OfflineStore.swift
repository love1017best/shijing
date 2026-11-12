import Foundation

/// 最后一次连上电脑时看到的壁纸列表和状态，按 Mac 存在磁盘上。
///
/// 手机连不上 Mac（睡眠、拾景没开、不在同一个网络）时，App 打开仍然显示上次的样子：
/// 概览、壁纸网格、大图都还在（图片靠 ImageStore 的磁盘缓存），界面上标出「离线 · X 前同步」。
/// 只在拿到过完整的一份（状态 + 壁纸列表）时才写，连上后每次状态更新覆盖一次。
@MainActor
final class OfflineStore {
    struct Snapshot: Codable {
        var state: RemoteState
        var walls: [Wallpaper]
        var hero: String?
        var at: Date
    }

    static let shared = OfflineStore()

    private let dir: URL?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        let fm = FileManager.default
        let base = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let d = base?.appending(path: "拾景/offline", directoryHint: .isDirectory)
        dir = d
        guard let d else { return }
        try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        // 快照只是为了让离线时能看，不进 iCloud 备份
        var d2 = d
        var v = URLResourceValues()
        v.isExcludedFromBackup = true
        try? d2.setResourceValues(v)
    }

    private func file(_ id: String) -> URL? {
        dir?.appending(path: id + ".json", directoryHint: .notDirectory)
    }

    func load(_ id: String) -> Snapshot? {
        guard let f = file(id), let data = try? Data(contentsOf: f) else { return nil }
        return try? decoder.decode(Snapshot.self, from: data)
    }

    func save(_ id: String, _ snap: Snapshot) {
        guard let f = file(id), let data = try? encoder.encode(snap) else { return }
        try? data.write(to: f, options: .atomic)
    }

    func clear(_ id: String) {
        guard let f = file(id) else { return }
        try? FileManager.default.removeItem(at: f)
    }
}
