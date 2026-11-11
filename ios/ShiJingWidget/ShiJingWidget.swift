import AppIntents
import SwiftUI
import WidgetKit

@main
struct ShiJingWidgets: WidgetBundle {
    var body: some Widget { StatusWidget() }
}

/// 主屏幕小组件：Mac 上拾景的状态，一个按钮换一批（运行中变成停止）。
/// 连的是 App 里选中的那台 Mac（共享钥匙串里的 CurrentMac）。
struct StatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "status", provider: Provider()) { entry in
            StatusView(entry: entry)
                .containerBackground(for: .widget) { Color(.systemBackground) }
        }
        .configurationDisplayName("拾景")
        .description("看 Mac 上的壁纸状态，一键换一批。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct Entry: TimelineEntry {
    var date = Date()
    var mac: String?
    var state: RemoteState?
    /// 连不上 / 没配对的说明
    var problem: String?

    static let sample = Entry(mac: "我的 Mac", state: nil, problem: nil)
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { .sample }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (Entry) -> Void) {
        Task { completion(context.isPreview ? .sample : await fetch()) }
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<Entry>) -> Void) {
        Task {
            let e = await fetch()
            // 运行中一分钟刷一次（系统会限流，实际可能更慢），平时一刻钟
            let next = e.state?.running == true ? 60.0 : 15 * 60
            completion(Timeline(entries: [e], policy: .after(Date().addingTimeInterval(next))))
        }
    }

    private func fetch() async -> Entry {
        guard let mac = CurrentMac.load() else {
            return Entry(problem: "打开拾景配对一台 Mac")
        }
        do {
            let s = try await mac.client().state()
            RunNotifier.observe(old: nil, new: s, mac: mac.name)
            return Entry(mac: mac.name, state: s)
        } catch APIError.unauthorized {
            return Entry(mac: mac.name, problem: "配对已失效，打开拾景重新配对")
        } catch {
            return Entry(mac: mac.name, problem: "连不上，Mac 可能睡着了")
        }
    }
}

private let accent = Color(red: 0.894, green: 0.361, blue: 0) // 和 App 的强调色一样（#E45C00）

struct StatusView: View {
    let entry: Entry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let s = entry.state {
            if family == .systemSmall { small(s) } else { medium(s) }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                header
                Spacer(minLength: 0)
                Text(entry.problem ?? "正在读取…")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "photo.on.rectangle.angled").foregroundStyle(accent)
            Text(entry.mac ?? "拾景").font(.caption.bold()).lineLimit(1)
        }
    }

    private func small(_ s: RemoteState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            Spacer(minLength: 0)
            Text(s.running ? (s.label ?? "正在换壁纸…") : "\(s.wallpapers) 张壁纸")
                .font(.headline).lineLimit(2).minimumScaleFactor(0.8)
            subtitle(s).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
            action(s)
        }
    }

    private func medium(_ s: RemoteState) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                header
                Spacer(minLength: 0)
                Text(s.title).font(.headline).lineLimit(2)
                if s.running {
                    if s.fraction >= 0 {
                        ProgressView(value: s.fraction).tint(accent)
                    }
                    Text(s.label ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    subtitle(s).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if let next = s.nextAutoDate {
                        Text("下次自动换 \(next.formatted(.dateTime.month().day().hour().minute()))")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            action(s).frame(width: 110)
                .frame(maxHeight: .infinity, alignment: .bottom)
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
        if s.running {
            Button(intent: StopWallpaperIntent()) {
                Label(s.stopping ? "正在停止" : "停止", systemImage: "stop.fill")
                    .font(.caption.bold()).frame(maxWidth: .infinity)
            }
            .tint(.red)
            .disabled(s.stopping)
        } else {
            Button(intent: RunWallpaperIntent(deleteOriginals: false)) {
                Label("换一批", systemImage: "shuffle")
                    .font(.caption.bold()).frame(maxWidth: .infinity)
            }
            .tint(accent)
            .disabled(s.blocked != nil)
        }
    }
}
