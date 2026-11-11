import AppIntents
import SwiftUI
import WidgetKit

// 小组件的界面。App 的 Debug 构建也编译这个文件（启动参数 -demoWidgets 显示四种尺寸），方便在模拟器里看排版。

struct Entry: TimelineEntry {
    var date = Date()
    var mac: String?
    var state: RemoteState?
    /// 连不上 / 没配对的说明
    var problem: String?
    /// 背景图（已经按小组件尺寸缩好）
    var image: UIImage?
    var wallName: String?

    static let sample = Entry(mac: "我的 Mac")
}

private let accent = Color(red: 0.894, green: 0.361, blue: 0) // 和 App 的强调色一样（#E45C00）

/// 背景：壁纸铺满，底下压一层渐暗，白字才看得清；没有图时用橙色日落渐变（和图标一个色调）。
struct Backdrop: View {
    let image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [Color(red: 0.98, green: 0.62, blue: 0.27), Color(red: 0.55, green: 0.17, blue: 0.24)],
                               startPoint: .top, endPoint: .bottom)
            }
            LinearGradient(stops: [.init(color: .black.opacity(0.35), location: 0),
                                   .init(color: .clear, location: 0.3),
                                   .init(color: .clear, location: 0.45),
                                   .init(color: .black.opacity(0.65), location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
    }
}

struct StatusView: View {
    let entry: Entry
    /// App 里的演示页用：环境里的 widgetFamily 只有小组件进程才有
    var familyOverride: WidgetFamily?
    @Environment(\.widgetFamily) private var envFamily
    private var family: WidgetFamily { familyOverride ?? envFamily }

    private var big: Bool { family == .systemLarge || family == .systemExtraLarge }
    private var padding: CGFloat { family == .systemSmall ? 14 : 16 }

    var body: some View {
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
            Image(systemName: "photo.on.rectangle.angled")
            Text(entry.mac ?? "拾景").lineLimit(1)
            Spacer(minLength: 0)
            if big, let name = entry.wallName {
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
                details(s, titleFont: family == .systemExtraLarge ? .largeTitle.bold() : .title2.bold())
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
            if let next = s.nextAutoDate {
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
    @ViewBuilder
    private func action(_ s: RemoteState) -> some View {
        Group {
            if s.running {
                Button(intent: StopWallpaperIntent()) {
                    Label(s.stopping ? "正在停止" : "停止", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .tint(.red)
                .disabled(s.stopping)
            } else {
                Button(intent: RunWallpaperIntent(deleteOriginals: false)) {
                    Label("换一批", systemImage: "shuffle")
                        .frame(maxWidth: .infinity)
                }
                .tint(accent)
                .disabled(s.blocked != nil)
            }
        }
        .font((big ? Font.subheadline : .caption).bold())
        .buttonStyle(.borderedProminent)
        .shadow(radius: 0)
    }
}
