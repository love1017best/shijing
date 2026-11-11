import AppIntents
import ImageIO
import SwiftUI
import WidgetKit

@main
struct ShiJingWidgets: WidgetBundle {
    var body: some Widget { StatusWidget() }
}

/// 主屏幕小组件：背景是当前壁纸里的一张（一刻钟换一张），上面是 Mac 上拾景的状态和「换一批」/「停止」按钮。
/// 连的是 App 里选中的那台 Mac（共享钥匙串里的 CurrentMac）。
struct StatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "status", provider: Provider()) { entry in
            StatusView(entry: entry)
                .containerBackground(for: .widget) { Backdrop(image: entry.image) }
        }
        .configurationDisplayName("拾景")
        .description("当前壁纸轮流当背景，看状态、一键换一批。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
        .contentMarginsDisabled()
    }
}

struct Provider: TimelineProvider {
    /// 不在换壁纸时，一次排几张背景、每张显示多久
    private static let rotateCount = 3
    private static let rotateEvery: TimeInterval = 15 * 60

    func placeholder(in context: Context) -> Entry { .sample }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (Entry) -> Void) {
        Task { completion(await entries(context, count: 1).first ?? .sample) }
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<Entry>) -> Void) {
        Task {
            let list = await entries(context, count: Self.rotateCount)
            let policy: TimelineReloadPolicy = if list.first?.state?.running == true {
                .after(Date().addingTimeInterval(60)) // 运行中一分钟刷一次（系统会限流，实际可能更慢）
            } else if list.first?.state == nil {
                .after(Date().addingTimeInterval(15 * 60))
            } else {
                .atEnd // 背景轮完一圈再取一次状态
            }
            completion(Timeline(entries: list, policy: policy))
        }
    }

    /// 取一次状态，再按时间排几张背景图。运行中只排一张（马上就要刷新）。
    private func entries(_ context: Context, count: Int) async -> [Entry] {
        guard let mac = CurrentMac.load() else {
            return [Entry(problem: "打开拾景配对一台 Mac")]
        }
        let client: APIClient
        let state: RemoteState
        do {
            client = try mac.client()
            state = try await client.state()
        } catch APIError.unauthorized {
            return [Entry(mac: mac.name, problem: "配对已失效，打开拾景重新配对")]
        } catch {
            return [Entry(mac: mac.name, problem: "连不上，Mac 可能睡着了")]
        }
        RunNotifier.observe(old: nil, new: state, mac: mac.name)

        let base = Entry(mac: mac.name, state: state)
        guard let list = try? await client.wallpapers(), !list.items.isEmpty else { return [base] }
        let n = state.running ? 1 : count
        let names = Self.pick(list, count: n)
        let maxPixels = Self.maxPixels(context)
        // 几张图并发下载；读不了的那张就没有背景
        let images = await withTaskGroup(of: (Int, UIImage?).self) { group in
            for (i, name) in names.enumerated() {
                group.addTask { (i, await Self.image(client, name, hasHero: list.hero != nil, maxPixels: maxPixels)) }
            }
            var out = [UIImage?](repeating: nil, count: names.count)
            for await (i, img) in group { out[i] = img }
            return out
        }
        let now = Date()
        return names.indices.map { i in
            var e = base
            e.date = now.addingTimeInterval(Double(i) * Self.rotateEvery)
            e.image = images[i]
            e.wallName = names[i]
            return e
        }
    }

    /// 选哪几张：第一张是桌面横幅那张，之后按时间段在整个壁纸文件夹里跳着轮（每一刻钟换一批起点，看着随机）。
    private static func pick(_ list: WallpaperList, count: Int) -> [String] {
        let all = list.items.map(\.name)
        let slot = Int(Date().timeIntervalSince1970 / rotateEvery)
        var out: [String] = []
        for i in 0..<min(count, all.count) {
            let idx = (slot &* 7919 &+ i &* 104_729) % all.count
            out.append(all[(idx + all.count) % all.count])
        }
        return out
    }

    /// 背景图要多少像素：按小组件的实际尺寸（3 倍屏），封顶 1200（小组件进程内存很紧）。
    private static func maxPixels(_ context: Context) -> Int {
        let s = context.displaySize
        return min(1200, Int(max(s.width, s.height) * 3))
    }

    private static func image(_ client: APIClient, _ name: String, hasHero: Bool, maxPixels: Int) async -> UIImage? {
        // 有横幅尺寸（1600 宽，电脑上有磁盘缓存）就用它，旧版桌面端退回缩略图
        let kinds: [ImageKind] = hasHero ? [.hero, .thumb] : [.thumb]
        for kind in kinds {
            if let data = try? await client.imageData(name, kind: kind), let img = downsample(data, maxPixels: maxPixels) {
                return img
            }
        }
        return nil
    }

    /// 解码时直接缩到目标尺寸，不在内存里放整张大图。
    private static func downsample(_ data: Data, maxPixels: Int) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary).map { UIImage(cgImage: $0) }
    }
}

