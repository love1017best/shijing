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
        /// `walls` 对应的是哪一批（`walls_rev`）。不能拿 `state.wallsRev` 顶替：
        /// 状态推送比列表先到的那一小段时间里，两者不是同一批。旧版本的文件没有这个字段（nil）。
        var wallsRev: String?
        var at: Date
    }

    /// 记录页（运行日志、删除记录、不再选）的一份缓存，`at` 是同步的时间。
    /// 壁纸和状态跟着每次推送走，记录只有连上时才有机会拿，所以单独存、单独标时间。
    struct Cached<T: Codable>: Codable {
        var value: T
        var at: Date
    }

    static let shared = OfflineStore()

    nonisolated let dir: URL?
    private let decoder = JSONDecoder()

    /// 写盘都排在这一条串行队列上：编码一整份壁纸列表 + 状态要几毫秒，不该占主线程
    /// （每 5 秒就要写一次）；串行是为了保证先排的写完再写后一份，别让旧快照盖掉新的。
    private static let writeQueue = DispatchQueue(label: "com.love1017best.shijing.offline-write", qos: .utility)

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

    nonisolated private func file(_ id: String) -> URL? {
        dir?.appending(path: id + ".json", directoryHint: .notDirectory)
    }

    /// 启动时读快照：一整份壁纸列表解码起来要几十毫秒，放后台做，别占首帧。
    nonisolated func loadAsync(_ id: String) async -> Snapshot? {
        guard let f = file(id) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: f) else { return nil }
            return try? JSONDecoder().decode(Snapshot.self, from: data)
        }.value
    }

    func save(_ id: String, _ snap: Snapshot) {
        guard let f = file(id) else { return }
        Self.writeQueue.async {
            let encoder = JSONEncoder()
            guard let data = try? encoder.encode(snap) else { return }
            try? data.write(to: f, options: .atomic)
        }
    }

    func clear(_ id: String) {
        guard let f = file(id), let dir = dir else { return }
        // 和写盘排同一条队列：清掉之后不会被还在排队的旧快照又写回来
        Self.writeQueue.async {
            let fm = FileManager.default
            try? fm.removeItem(at: f)
            // 记录缓存也一起删掉
            let prefix = "records-\(id)-"
            for u in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            where u.lastPathComponent.hasPrefix(prefix) {
                try? fm.removeItem(at: u)
            }
        }
    }

    // MARK: 记录页的缓存（日志 / 删除记录 / 不再选）

    private func recordFile(_ id: String, _ kind: String) -> URL? {
        dir?.appending(path: "records-\(id)-\(kind).json", directoryHint: .notDirectory)
    }

    func saveRecord<T: Codable>(_ id: String, _ kind: RecordsKind, _ value: T, at: Date = Date()) {
        guard let f = recordFile(id, kind.rawValue) else { return }
        let cached = Cached(value: value, at: at)
        Self.writeQueue.async {
            let encoder = JSONEncoder()
            guard let data = try? encoder.encode(cached) else { return }
            try? data.write(to: f, options: .atomic)
        }
    }

    func loadRecord<T: Codable>(_ id: String, _ kind: RecordsKind) -> Cached<T>? {
        guard let f = recordFile(id, kind.rawValue), let data = try? Data(contentsOf: f) else { return nil }
        return try? decoder.decode(Cached<T>.self, from: data)
    }
}

/// 记录页缓存的种类，对应记录页里的三个列表。
enum RecordsKind: String {
    case log, deletions, excluded
}
