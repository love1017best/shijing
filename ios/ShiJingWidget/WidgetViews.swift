import AppIntents
import SwiftUI
import WidgetKit

// 小组件的界面。App 的 Debug 构建也编译这个文件（启动参数 -demoWidgets 把各种尺寸摆在一页上），方便在模拟器里看排版。

struct Entry: TimelineEntry {
    var date = Date()
    var mac: String?
    var state: RemoteState?
    /// 连不上 / 没配对的说明（而且没有缓存可用）
    var problem: String?
    /// 连不上、用的是这个时间缓存的状态
    var offlineSince: Date?
    /// 背景图：小组件缓存目录里缩好的 JPEG
    var imageFile: URL?
    var wallName: String?
    /// 壁纸小组件：图上标出文件名
    var showName = false

    static let sample = Entry(mac: "我的 Mac")

    /// 点小组件打开拾景；有图时直接打开这张的大图。
    var openURL: URL {
        guard let wallName else { return URL(string: "shijing://home")! }
        return URL(string: "shijing://wall")!.appending(path: wallName)
    }

    var image: UIImage? {
        guard let file = imageFile else { return nil }
        let img = UIImage(contentsOfFile: file.path)
        if img == nil { WidgetDebug.log("decode fail \(file.lastPathComponent)", throttle: true) }
        return img
    }
}

enum WidgetFamilies {
    /// 功能小组件：主屏幕全部尺寸（含 iOS 27 的 iPhone 整页）+ 锁定屏幕三种
    static var status: [WidgetFamily] {
        var f: [WidgetFamily] = [.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge,
                                 .accessoryCircular, .accessoryRectangular, .accessoryInline]
        if #available(iOS 27.0, *) { f.append(.systemExtraLargePortrait) }
        return f
    }

    /// 壁纸小组件：只做主屏幕（用户觉得锁屏那个没必要，v0.3.147 起去掉）
    static var photo: [WidgetFamily] {
        var f: [WidgetFamily] = [.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge]
        if #available(iOS 27.0, *) { f.append(.systemExtraLargePortrait) }
        return f
    }
}

extension WidgetFamily {
    var isAccessory: Bool {
        switch self {
        case .accessoryCircular, .accessoryRectangular, .accessoryInline: true
        default: false
        }
    }

    /// 大号：大、超大、iPhone 整页
    var isBig: Bool {
        switch self {
        case .systemLarge, .systemExtraLarge: return true
        default:
            if #available(iOS 27.0, *), self == .systemExtraLargePortrait { return true }
            return false
        }
    }
}

private let accent = Color(red: 0.894, green: 0.361, blue: 0) // 和 App 的强调色一样（#E45C00）

/// 背景：壁纸铺满；功能小组件上下压一层渐暗，白字才看得清。没有图时用橙色日落渐变（和图标一个色调）。
/// 锁定屏幕上不画背景（系统也不让画）。
struct WidgetBackdrop: View {
    let entry: Entry
    var dim = true
    var familyOverride: WidgetFamily?
    @Environment(\.widgetFamily) private var envFamily

    var body: some View {
        if (familyOverride ?? envFamily).isAccessory {
            Color.clear
        } else {
            ZStack {
                if let image = entry.image {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    LinearGradient(colors: [Color(red: 0.98, green: 0.62, blue: 0.27), Color(red: 0.55, green: 0.17, blue: 0.24)],
                                   startPoint: .top, endPoint: .bottom)
                }
                if dim {
                    LinearGradient(stops: [.init(color: .black.opacity(0.35), location: 0),
                                           .init(color: .clear, location: 0.3),
                                           .init(color: .clear, location: 0.45),
                                           .init(color: .black.opacity(0.65), location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                }
            }
        }
    }
}

// MARK: - 功能小组件

struct StatusView: View {
    let entry: Entry
    /// App 里的演示页用：环境里的 widgetFamily 只有小组件进程才有
    var familyOverride: WidgetFamily?
    @Environment(\.widgetFamily) private var envFamily
    private var family: WidgetFamily { familyOverride ?? envFamily }

    private var big: Bool { family.isBig }
    private var padding: CGFloat { family == .systemSmall ? 14 : 16 }

    var body: some View {
        switch family {
        case .accessoryInline: inline
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        default: home
        }
    }

    // MARK: 主屏幕

    private var home: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            Spacer(minLength: 0)
            if let s = entry.state {
                content(s)
            } else {
                Text(entry.problem ?? "正在读取…").font(.footnote.weight(.medium))
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
        .padding(padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: entry.offlineSince == nil ? "photo.on.rectangle.angled" : "wifi.slash")
            Text(entry.mac ?? "拾景").lineLimit(1)
            Spacer(minLength: 0)
            if let since = entry.offlineSince {
                // 离线：用的是缓存的状态
                Text("离线 · \(since.formatted(.dateTime.hour().minute()))").opacity(0.85)
            } else if big, let name = entry.wallName {
                Text(name).lineLimit(1).truncationMode(.middle).opacity(0.8)
                    .frame(maxWidth: 220, alignment: .trailing)
            }
        }
        .font(.caption.weight(.semibold))
    }

    @ViewBuilder
    private func content(_ s: RemoteState) -> some View {
        switch family {
        case .systemSmall:
            Text(s.running ? (s.label ?? "正在换壁纸…") : "\(s.wallpapers) 张壁纸")
                .font(.headline).lineLimit(2).minimumScaleFactor(0.8)
            if s.running, s.fraction >= 0 {
                ProgressView(value: s.fraction).tint(.white)
            } else if !s.running {
                subtitle(s).font(.caption2).opacity(0.85).lineLimit(1)
            }
            action(s).padding(.top, 4)
        case .systemMedium:
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) { details(s, titleFont: .headline) }
                    .frame(maxWidth: .infinity, alignment: .leading)
                action(s).frame(width: 108)
            }
        default:
            VStack(alignment: .leading, spacing: 4) {
                details(s, titleFont: family == .systemLarge ? .title2.bold() : .largeTitle.bold())
            }
            HStack(spacing: 10) {
                action(s)
            }
            .frame(maxWidth: 320)
            .padding(.top, 8)
        }
    }

    /// 标题、上次运行 / 进度、下次自动换。
    @ViewBuilder
    private func details(_ s: RemoteState, titleFont: Font) -> some View {
        Text(s.title).font(titleFont).lineLimit(2).minimumScaleFactor(0.8)
        if s.running {
            if s.fraction >= 0 {
                ProgressView(value: s.fraction).tint(.white)
            }
            Text(s.label ?? "").font(.caption).opacity(0.9).lineLimit(1)
        } else {
            subtitle(s).font(big ? .subheadline : .caption).opacity(0.9).lineLimit(1)
            if let next = s.nextAutoDate, next > Date() {
                Text("下次自动换 \(next.formatted(.dateTime.month().day().hour().minute()))")
                    .font(big ? .subheadline : .caption).opacity(0.9).lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private func subtitle(_ s: RemoteState) -> some View {
        if let l = s.last {
            Text("上次 \(l.date.formatted(.relative(presentation: .named)))\(l.brief.map { " · " + $0 } ?? "")")
        } else {
            Text("还没换过")
        }
    }

    /// 换一批 / 停止。电脑上开了「删除不合格原图」时，从小组件换一批只模拟筛选（删原图要在 App 里确认）。
    /// 离线时按钮点了也连不上，灰掉。
    @ViewBuilder
    private func action(_ s: RemoteState) -> some View {
        Group {
            if s.running {
                Button(intent: StopWallpaperIntent()) {
                    Label(s.stopping ? "正在停止" : "停止", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .tint(.red)
                .disabled(s.stopping || entry.offlineSince != nil)
            } else {
                Button(intent: RunWallpaperIntent(deleteOriginals: false)) {
                    Label("换一批", systemImage: "shuffle")
                        .frame(maxWidth: .infinity)
                }
                .tint(accent)
                .disabled(s.blocked != nil || entry.offlineSince != nil)
            }
        }
        .font((big ? Font.subheadline : .caption).bold())
        .buttonStyle(.borderedProminent)
        .shadow(radius: 0)
    }

    // MARK: 锁定屏幕

    private var inline: some View {
        Group {
            if let s = entry.state {
                if s.running {
                    Label("换壁纸 \(s.fraction >= 0 ? Int(s.fraction * 100) : 0)%", systemImage: "shuffle")
                } else {
                    Label("拾景 \(s.wallpapers) 张壁纸", systemImage: "photo.on.rectangle.angled")
                }
            } else {
                Label("拾景", systemImage: "photo.on.rectangle.angled")
            }
        }
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            if let s = entry.state, s.running, s.fraction >= 0 {
                Gauge(value: s.fraction) {
                    Image(systemName: "shuffle")
                }
                .gaugeStyle(.accessoryCircularCapacity)
            } else {
                VStack(spacing: 1) {
                    Image(systemName: entry.offlineSince == nil ? "photo.on.rectangle.angled" : "wifi.slash")
                        .font(.caption)
                    Text(entry.state.map { "\($0.wallpapers)" } ?? "—")
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .minimumScaleFactor(0.6)
                }
            }
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            Label(entry.mac ?? "拾景", systemImage: entry.offlineSince == nil ? "photo.on.rectangle.angled" : "wifi.slash")
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
            if let s = entry.state {
                Text(s.running ? (s.label ?? "正在换壁纸…") : "\(s.wallpapers) 张壁纸")
                    .font(.headline).lineLimit(1).minimumScaleFactor(0.8)
                if s.running, s.fraction >= 0 {
                    ProgressView(value: s.fraction)
                } else if let l = s.last {
                    Text("上次 \(l.date.formatted(.relative(presentation: .named)))").font(.caption2).lineLimit(1)
                }
            } else {
                Text(entry.problem ?? "正在读取…").font(.caption2).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 壁纸小组件

/// 只有图（图在 containerBackground 里铺满），需要时左下角标文件名；没有图时说明原因。
struct PhotoView: View {
    let entry: Entry
    var familyOverride: WidgetFamily?
    @Environment(\.widgetFamily) private var envFamily
    private var family: WidgetFamily { familyOverride ?? envFamily }

    /// 没有图时的一句话：离线（还没缓存）和「壁纸文件夹是空的」要说清楚，别让人以为壁纸被删了。
    private var emptyText: String {
        if let problem = entry.problem { return problem }
        // 壁纸小组件的时间线上只有第一条带状态，其余条目靠有没有挑到图来判断
        if let name = entry.wallName, !name.isEmpty {
            return entry.offlineSince != nil ? "离线 · 这张还没缓存" : "这张还没载入，稍后刷新"
        }
        if entry.state == nil { return "正在读取…" }
        if entry.offlineSince != nil { return "离线 · 这张还没缓存" }
        return "壁纸文件夹是空的"
    }

    /// 有没有图只看文件在不在，不解码：背景那一次已经解过了，小组件进程内存小，不重复解
    private var hasImage: Bool {
        guard let file = entry.imageFile else {
            WidgetDebug.log("photoView: imageFile nil", throttle: true)
            return false
        }
        let ok = FileManager.default.fileExists(atPath: file.path)
        WidgetDebug.log("photoView: hasImage=\(ok) \(file.lastPathComponent)", throttle: true)
        return ok
    }

    var body: some View {
        if family == .accessoryRectangular {
            // 锁定屏幕：图本身就是内容（系统渲染成单色）
            if let image = entry.image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Label("拾景壁纸", systemImage: "photo").font(.caption)
            }
        } else {
            // 根视图自己撑满容器：靠 Color.clear 撑尺寸在某些尺寸下会让内容被裁成 0
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 0)
                if !hasImage {
                    VStack(alignment: .leading, spacing: 4) {
                        Image(systemName: "photo.on.rectangle.angled").font(.title3)
                        Text(emptyText)
                            .font(.footnote.weight(.medium))
                    }
                    .foregroundStyle(.white)
                    .padding(14)
                } else if entry.showName, family != .systemSmall, let name = entry.wallName {
                    Text(name)
                        .font(.caption2.weight(.medium))
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.black.opacity(0.35), in: Capsule())
                        .padding(10)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }
}
