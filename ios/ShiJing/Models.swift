import Foundation

/// 桌面端推过来的状态快照，字段与 desktop/remote.go 的 remoteState 一一对应（JSON 是蛇形命名）。
struct RemoteState: Codable, Equatable {
    var version: String
    var eyebrow: String
    var title: String
    var running: Bool
    var stopping: Bool
    /// 这次会走哪几步：filter / scan / copy / refresh
    var steps: [String]
    var stage: String?
    var done: Int
    var total: Int
    /// 0~1；-1 表示进度未知
    var fraction: Double
    var label: String?
    var lastLine: String?
    var runDelete: Bool
    var rejected: Int
    var deleted: Int
    var deleteFailed: Int
    /// 「换一批」点不了的原因
    var blocked: String?
    var unmounted: Int
    /// 手动运行会删除不合格原图，运行前要确认
    var willDelete: Bool
    var deleteNote: String?
    var last: LastRun?
    /// 下一次自动换的时间（Unix 秒），没开自动换时为 nil
    var nextAuto: Double?
    var wallpapers: Int
    var dest: String
    var sampleCount: Int
    var libraryDirs: Int

    var nextAutoDate: Date? { nextAuto.map { Date(timeIntervalSince1970: $0) } }
}

struct LastRun: Codable, Equatable {
    var at: Double
    /// ok / stopped / failed
    var status: String
    var error: String?
    var selected: Int
    var copied: Int
    var failed: Int
    var elapsed: Double
    var brief: String?
    var detail: String?

    var date: Date { Date(timeIntervalSince1970: at) }
}

struct ServerInfo: Codable {
    var app: String
    var name: String
    var api: Int
    var version: String
    var paired: Bool
}

/// 运行步骤的显示名，顺序与桌面端一致。
enum Step: String, CaseIterable {
    case filter, scan, copy, refresh

    var title: String {
        switch self {
        case .filter: "筛选"
        case .scan: "采样"
        case .copy: "复制"
        case .refresh: "刷新"
        }
    }
}

/// 一台配对过的 Mac。令牌不放这里，存在钥匙串里（见 Keychain）。
struct SavedMac: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    /// Bonjour 服务名；Mac 换了 IP 时靠它重新找到
    var serviceName: String?
    var host: String
    var port: Int
}

struct MacAddress: Hashable {
    var host: String
    var port: Int

    var baseURL: URL? {
        // IPv6 地址要加方括号
        let h = host.contains(":") ? "[\(host)]" : host
        return URL(string: "http://\(h):\(port)")
    }
}

extension SavedMac {
    var address: MacAddress { MacAddress(host: host, port: port) }
}
