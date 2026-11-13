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
    /// 壁纸列表的指纹，变了就重新拉 /api/wallpapers（旧版桌面端没有这个字段）
    var wallsRev: String?
    var dest: String
    var sampleCount: Int
    var libraryDirs: Int
    /// 手机上能改的几项设置（第 3 期；旧版桌面端没有，界面上就只读）
    var settings: RemoteSettings?
    /// 最近一次可以撤销的移出（壁纸文件名）
    var undoName: String?
    /// 「不再选」名单里有几张
    var excluded: Int?
    /// 图库没连上时在电脑上排队的删除原图，图库连上后自动执行（旧版桌面端没有）
    var pending: Int?

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

/// 手机上能改的设置（desktop/remoteextra.go 的 remoteSettings）。
struct RemoteSettings: Codable, Equatable {
    var sampleCount: Int
    /// 0 表示不自动换
    var autoRunHours: Int
    var autoOptions: [Int]
    var deleteDuringFilter: Bool
    var preferUnseen: Bool
    var refreshWallpaper: Bool

    /// 和桌面端 autoRunLabel 一样的说法。
    static func autoLabel(_ h: Int) -> String {
        switch h {
        case ...0: "关闭"
        case 24: "每天"
        case 168: "每周"
        case let h where h % 24 == 0: "每 \(h / 24) 天"
        default: "每 \(h) 小时"
        }
    }
}

/// 「不再选」名单里的一张原图。
struct ExcludedItem: Codable, Identifiable, Hashable {
    /// 完整路径（恢复时原样传回去）
    var path: String
    /// ~ 缩写的路径
    var display: String
    var id: String { path }
    var name: String { (display as NSString).lastPathComponent }
    var folder: String { (display as NSString).deletingLastPathComponent }
}

/// 删除记录里的一条。
struct Deletion: Codable, Identifiable, Hashable {
    var at: Double
    var name: String
    var dir: String
    var reason: String?
    var id: String { "\(at)|\(dir)/\(name)" }
    var date: Date { Date(timeIntervalSince1970: at) }
}

struct DeletionList: Codable {
    var total: Int
    /// 按筛选规则删的、手动删的张数（全部记录，不只是 items 里这些）；旧版桌面端没有
    var filter: Int?
    var manual: Int?
    var items: [Deletion]
}

/// 壁纸文件夹里的一张（desktop/remotewalls.go 的 remoteWall）。
struct Wallpaper: Codable, Identifiable, Hashable {
    /// 壁纸文件夹里的文件名，也是接口路径里的 id
    var name: String
    /// 原图路径；旧版本换上的没有记录，只能移出
    var source: String?
    var id: String { name }
    var hasSource: Bool { !(source ?? "").isEmpty }
}

struct WallpaperList: Codable {
    var rev: String
    /// 横幅图（和桌面概览顶部那张一样）；旧版桌面端没有
    var hero: String?
    var items: [Wallpaper]
}

/// 要哪种尺寸的图：缩略图（360 宽）、横幅（1600 宽）或大图（2048 宽）。
enum ImageKind: String {
    case thumb, hero, image

    var isLarge: Bool { self != .thumb }
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
