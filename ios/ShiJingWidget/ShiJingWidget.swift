import AppIntents
import ImageIO
import SwiftUI
import UIKit
import WidgetKit

@main
struct ShiJingWidgets: WidgetBundle {
    var body: some Widget {
        StatusWidget()
        PhotoWidget()
        if #available(iOS 18.0, *) {
            RunControl()
        }
    }
}

// MARK: - 两种小组件

/// 功能小组件：背景是当前壁纸里的一张（按设定的间隔换），上面是 Mac 上拾景的状态和「换一批」/「停止」按钮。
/// 锁定屏幕上（圆形 / 矩形 / 一行字）只显示状态。连的是 App 里选中的那台 Mac（共享钥匙串里的 CurrentMac）。
struct StatusWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "status", intent: StatusWidgetConfig.self, provider: StatusProvider()) { entry in
            StatusView(entry: entry)
                .widgetURL(entry.openURL)
                .containerBackground(for: .widget) { WidgetBackdrop(entry: entry) }
        }
        .configurationDisplayName("拾景")
        .description("看 Mac 上换壁纸的状态，一键换一批；背景轮流显示当前壁纸。长按可以改换图间隔。")
        .supportedFamilies(WidgetFamilies.status)
        .contentMarginsDisabled()
    }
}

/// 壁纸小组件：只显示当前壁纸里的一张，按设定的间隔换。点一下在拾景里打开这张的大图。
struct PhotoWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "photo", intent: PhotoWidgetConfig.self, provider: PhotoProvider()) { entry in
            PhotoView(entry: entry)
                .widgetURL(entry.openURL)
                .containerBackground(for: .widget) { WidgetBackdrop(entry: entry, dim: false) }
        }
        .configurationDisplayName("拾景壁纸")
        .description("轮流展示 Mac 壁纸文件夹里的图。长按可以改换图间隔；点一下看大图。")
        .supportedFamilies(WidgetFamilies.photo)
        .contentMarginsDisabled()
    }
}

/// 控制中心 / 锁定屏幕底部 / 操作按钮里的「换一批壁纸」。
@available(iOS 18.0, *)
struct RunControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.love1017best.shijing.ios.run") {
            ControlWidgetButton(action: RunWallpaperIntent()) {
                Label("换一批壁纸", systemImage: "shuffle")
            }
        }
        .displayName("换一批壁纸")
        .description("让 Mac 上的拾景换一批新壁纸（不删原图）。")
    }
}

// MARK: - 长按「编辑小组件」里的选项

enum RotateInterval: Int, AppEnum {
    case m1 = 60, m5 = 300, m15 = 900, m30 = 1800, h1 = 3600, h3 = 10800, h6 = 21600, h12 = 43200, d1 = 86400

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "换图间隔"
    static let caseDisplayRepresentations: [RotateInterval: DisplayRepresentation] = [
        .m1: "1 分钟", .m5: "5 分钟", .m15: "15 分钟", .m30: "30 分钟", .h1: "1 小时",
        .h3: "3 小时", .h6: "6 小时", .h12: "12 小时", .d1: "1 天",
    ]
}

struct StatusWidgetConfig: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "拾景"
    static let description = IntentDescription("背景每隔多久换一张壁纸。")

    @Parameter(title: "背景换图间隔", default: .m15)
    var interval: RotateInterval
}

struct PhotoWidgetConfig: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "拾景壁纸"
    static let description = IntentDescription("每隔多久换一张壁纸，要不要显示文件名。")

    @Parameter(title: "换图间隔", default: .m15)
    var interval: RotateInterval

    @Parameter(title: "显示文件名", default: false)
    var showName: Bool
}

// MARK: - 时间线

struct StatusProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> Entry { .sample }

    func snapshot(for configuration: StatusWidgetConfig, in context: Context) async -> Entry {
        await TimelineMaker.make(context, interval: configuration.interval, photo: false, preview: true).entries.first ?? .sample
    }

    func timeline(for configuration: StatusWidgetConfig, in context: Context) async -> Timeline<Entry> {
        await TimelineMaker.make(context, interval: configuration.interval, photo: false, preview: false)
    }
}

struct PhotoProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> Entry { .sample }

    func snapshot(for configuration: PhotoWidgetConfig, in context: Context) async -> Entry {
        var e = await TimelineMaker.make(context, interval: configuration.interval, photo: true, preview: true).entries.first ?? .sample
        e.showName = configuration.showName
        return e
    }

    func timeline(for configuration: PhotoWidgetConfig, in context: Context) async -> Timeline<Entry> {
        let t = await TimelineMaker.make(context, interval: configuration.interval, photo: true, preview: false)
        let entries = t.entries.map { e in
            var e = e
            e.showName = configuration.showName
            return e
        }
        return Timeline(entries: entries, policy: t.policy)
    }
}

/// 两种小组件共用：取状态和壁纸列表（取不到就用上次缓存的），按换图间隔排几张背景。
///
/// 背景图在小组件自己的缓存目录里存一份缩好的 JPEG（按 Mac、文件名、像素尺寸），
/// 时间线里只放文件路径、显示时才解码：小组件进程内存只有几十 MB，不能把几张大图一起放在内存里。
/// 不在局域网里、Mac 睡着时，用缓存的状态和已经下过的图接着轮换，标上「离线」，一刻钟后再试。
enum TimelineMaker {
    /// 系统给小组件的时间不多（几十秒），超了直接把扩展杀掉，屏幕上是**一块空白**，要等下一次刷新才恢复。
    /// 所以整条时间线自己限时：状态和列表各 6 秒，设图最多几张，到点没下到的图就留空（显示渐变），状态照常给。
    private static let budget: TimeInterval = 20
    private static let fastTimeout: TimeInterval = 6
    /// 一次时间线最多新下几张图：第一次添加小组件时一张缓存都没有，排 60 张不该下 60 次
    private static let maxNewDownloads = 8
    /// 本地缓存池尽量留住多少张图：1 分钟间隔排 60 条，池子有这么多就够轮一大阵不出重样
    private static let poolTarget = 48

    static func make(_ context: TimelineProviderContext, interval: RotateInterval, photo: Bool, preview: Bool) async -> Timeline<Entry> {
        let now = Date()
        let deadline = now.addingTimeInterval(budget)
        guard let mac = CurrentMac.load() else {
            return Timeline(entries: [Entry(problem: "打开拾景配对一台 Mac")], policy: .after(now.addingTimeInterval(3600)))
        }
        let key = "\(mac.host):\(mac.port)"
        let accessory = context.family.isAccessory

        // 1. 状态和列表：在线就取新的并缓存，取不到用缓存
        var snap: WidgetCache.Snapshot?
        var offlineSince: Date?
        var problem: String?
        var client: APIClient?
        do {
            let c = try mac.client()
            let state = try await c.state(timeout: fastTimeout)
            // 锁定屏幕上的功能小组件不用图，不拉列表
            let list = (photo || !accessory) ? (try? await c.wallpapers(timeout: fastTimeout)) : nil
            let cachedList = WidgetCache.load(key)?.list
            snap = WidgetCache.Snapshot(state: state, list: list ?? cachedList, at: now)
            WidgetCache.save(snap!, key)
            client = c
            if !preview { RunNotifier.observe(new: state, mac: mac.name) }
        } catch APIError.unauthorized {
            problem = "配对已失效，打开拾景重新配对"
        } catch {
            snap = WidgetCache.load(key)
            offlineSince = snap?.at
            if snap == nil { problem = "连不上 \(mac.name)，Mac 可能睡着了或不在同一个网络" }
        }

        var base = Entry(date: now, mac: mac.name, state: snap?.state, problem: problem)
        base.offlineSince = offlineSince
        let retry = now.addingTimeInterval(15 * 60)
        guard let snap, !(accessory && !photo) else {
            let running = snap?.state.running == true
            return Timeline(entries: [base], policy: .after(running ? now.addingTimeInterval(60) : retry))
        }

        // 2. 这段时间里依次显示哪几张：按「第几个间隔」挑，同一个间隔里重新取时间线还是同一张
        let step = TimeInterval(interval.rawValue)
        let running = snap.state.running && !photo
        // 一次排多久：1、5 分钟这种短间隔排 1 小时（1 分钟就是 60 条，之后靠系统再刷新接着排），其余排 2 小时；最多 60 条
        let horizon: TimeInterval = step <= 300 ? 3600 : 7200
        let count = preview || running ? 1 : min(60, max(2, Int((horizon / step).rounded(.up))))
        let slot0 = Int(now.timeIntervalSince1970 / step)
        let px = pixels(context)
        let allNames = snap.list?.items.map(\.name) ?? []
        // 手机（小组件自己的缓存目录）里已经存下来的图优先：轮换主要在这些图里转，1 分钟一换也不用等网络。
        // 离线时只有这一份；在线时算「本地缓存池」，池子还小就在后面用剩下的时间慢慢补。
        let cachedNames = allNames.filter { WidgetCache.hasImage(key, $0, px) }
        let names = cachedNames.isEmpty ? (client == nil ? [] : allNames) : cachedNames
        var entries: [Entry] = []
        var newDownloads = 0
        for i in 0..<count {
            var e = base
            e.date = i == 0 ? now : Date(timeIntervalSince1970: Double(slot0 + i) * step)
            if !names.isEmpty {
                let name = names[pick(slot0 + i, names.count)]
                e.wallName = name
                // 已经缓存上的直接用；没缓存的最多再下几张，其余的下次刷新再补
                var canDownload = false
                if !WidgetCache.hasImage(key, name, px), newDownloads < maxNewDownloads, Date() < deadline {
                    canDownload = true
                    newDownloads += 1
                }
                e.imageFile = await image(key, name, px, client: canDownload ? client : nil, hasHero: snap.list?.hero != nil, deadline: deadline)
            }
            entries.append(e)
        }

        // 2.1 缓存池子还小的时候，用剩下的时间再存几张进来：池子越大，短间隔轮换的选择越多
        if client != nil, cachedNames.count < poolTarget {
            for name in allNames where !WidgetCache.hasImage(key, name, px) {
                guard newDownloads < maxNewDownloads, Date() < deadline else { break }
                newDownloads += 1
                _ = await image(key, name, px, client: client, hasHero: snap.list?.hero != nil, deadline: deadline)
            }
        }

        // 3. 什么时候再取：离线一刻钟后重试；运行中一分钟；缓存池还没填满时也早点再来（1 分钟轮换要多备几张图）；
        //    功能小组件最多半小时刷一次状态；壁纸小组件轮完或 6 小时
        let end = Date(timeIntervalSince1970: Double(slot0 + count) * step)
        let filling = client != nil && cachedNames.count < poolTarget
        let next: Date = if client == nil {
            retry
        } else if running {
            now.addingTimeInterval(60)
        } else if filling {
            min(end, now.addingTimeInterval(15 * 60))
        } else {
            min(end, now.addingTimeInterval(photo ? 6 * 3600 : 30 * 60))
        }
        WidgetCache.prune()
        return Timeline(entries: entries, policy: .after(next))
    }

    /// 第 slot 个间隔显示第几张：在整个壁纸文件夹里跳着取，看着随机，但同一个间隔总是同一张。
    private static func pick(_ slot: Int, _ count: Int) -> Int {
        var x = UInt64(truncatingIfNeeded: slot) &* 0x9E37_79B9_7F4A_7C15
        x ^= x >> 29
        return Int(x % UInt64(count))
    }

    /// 背景图要多少像素：按小组件实际尺寸（3 倍屏、宽图铺满高的小组件时按 16:10 算宽），封顶 1600（横幅图本来就这么宽）。
    /// 取整到 200 一档，缓存好命中。
    private static func pixels(_ context: TimelineProviderContext) -> Int {
        let s = context.displaySize
        let need = max(s.width, s.height * 1.6) * 3
        return min(1600, max(400, Int((need / 200).rounded(.up)) * 200))
    }

    /// 缓存里有就直接用；没有且在线就下载（横幅尺寸，旧版桌面端退回缩略图）、缩好存起来。
    /// 超时按剩下的时间预算压短：慢慢传的时候宁可这张先空着，也不能让整个时间线拖过系统的上限。
    private static func image(_ key: String, _ name: String, _ px: Int, client: APIClient?, hasHero: Bool, deadline: Date) async -> URL? {
        let file = WidgetCache.imageFile(key, name, px)
        if FileManager.default.fileExists(atPath: file.path) {
            WidgetCache.touch(file)
            return file
        }
        guard let client else { return nil }
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 1 else { return nil }
        let kinds: [ImageKind] = hasHero ? [.hero, .thumb] : [.thumb]
        for kind in kinds {
            if let data = try? await client.imageData(name, kind: kind, timeout: max(2, min(remaining, 12))),
               let jpeg = downsample(data, maxPixels: px) {
                try? jpeg.write(to: file)
                return file
            }
        }
        return nil
    }

    /// 解码时直接缩到目标尺寸，再存成 JPEG。
    private static func downsample(_ data: Data, maxPixels: Int) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.85)
    }
}

/// 小组件自己的缓存目录（免费签名没有 App Groups，和 App 不共享，也用不着共享）。
enum WidgetCache {
    struct Snapshot: Codable {
        var state: RemoteState
        var list: WallpaperList?
        var at: Date
    }

    private static let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "widget", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private static func hash(_ s: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return String(h, radix: 36)
    }

    private static func stateFile(_ key: String) -> URL { dir.appending(path: "state-\(hash(key)).json") }

    static func save(_ s: Snapshot, _ key: String) {
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: stateFile(key), options: .atomic) }
    }

    static func load(_ key: String) -> Snapshot? {
        (try? Data(contentsOf: stateFile(key))).flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) }
    }

    static func imageFile(_ key: String, _ name: String, _ px: Int) -> URL {
        dir.appending(path: "img-\(hash(key + "|" + name))-\(px).jpg")
    }

    static func hasImage(_ key: String, _ name: String, _ px: Int) -> Bool {
        FileManager.default.fileExists(atPath: imageFile(key, name, px).path)
    }

    /// 用到的图更新修改时间，清理时按它留最近用过的。
    static func touch(_ file: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
    }

    /// 图最多留 120 张（离线时够轮好一阵），多了删最久没用的。
    static func prune(keep: Int = 120) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let imgs = files.filter { $0.lastPathComponent.hasPrefix("img-") }
        guard imgs.count > keep else { return }
        let dated = imgs.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for (f, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(keep) { try? fm.removeItem(at: f) }
    }
}
