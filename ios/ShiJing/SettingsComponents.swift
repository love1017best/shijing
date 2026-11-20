import SwiftUI
import UIKit

/// 这台设备（iPhone / iPad）：设置页的分类名和「关于」里用它，平板上别写成「手机」。
enum ThisDevice {
    static var label: String { "这台 " + UIDevice.current.localizedModel }
}

/// 标题旁的问号：标题连问号整行都能点，点一下弹出说明。功能说明都收在这里，列表里只留标题和设置项
/// （和电脑端设置页的小问号一致，v0.4.6 起）。动态的状态（监听端口、下次运行、版本不一致提醒）仍然直接显示。
/// 分组标题和单个设置项共用这一个组件，字号跟随所在位置。
struct HelpLabel: View {
    let title: String
    let help: String
    @State private var open: Bool

    /// 截图用：启动参数 `-demoHelp <标题>` 让那一项说明直接展开（模拟器里点按钮不可靠）
    init(_ title: String, _ help: String) {
        self.title = title
        self.help = help
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-demoHelp"), i + 1 < args.count, args[i + 1] == title {
            _open = State(initialValue: true)
        } else {
            _open = State(initialValue: false)
        }
        #else
        _open = State(initialValue: false)
        #endif
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            HelpIcon()
        }
        // 整行都能点：问号只有十几 pt，单点图标不好按中
        .contentShape(Rectangle())
        .onTapGesture { open = true }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)，点按查看说明")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open = true }
        .helpPopover(isPresented: $open, text: help)
    }
}

/// 分组标题旁的问号：和设置项用的是同一个组件。
typealias HelpHeader = HelpLabel

/// 小问号图标：跟随分组标题的次要颜色，别用按钮的橙色。
struct HelpIcon: View {
    var body: some View {
        Image(systemName: "questionmark.circle")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}

extension View {
    /// 说明气泡：宽固定 280，文字按行数撑高（只给 maxWidth 会被截成两行）。
    /// 不指定 arrowEdge，让系统自己找放得下的方向：长说明从屏幕下方的行打开时往上展开。
    func helpPopover(isPresented: Binding<Bool>, text: String) -> some View {
        popover(isPresented: isPresented) {
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .padding(16)
                .frame(width: 280, alignment: .leading)
                .presentationCompactAdaptation(.popover)
        }
    }
}

/// 概览里的「状态」：只读，和电脑概览顶部的摘要条对应（壁纸文件夹、张数、图库、下次自动换）。改设置去「设置」页。
struct StatusSection: View {
    let state: RemoteState

    var body: some View {
        Section {
            LabeledContent("壁纸文件夹", value: state.dest)
            LabeledContent("现在有", value: "\(state.wallpapers) 张")
            LabeledContent("每次换", value: "\(state.settings?.sampleCount ?? state.sampleCount) 张")
            LabeledContent("图库目录", value: "\(state.libraryDirs) 个")
            if let next = state.nextAutoDate {
                LabeledContent("下次自动换") {
                    Text(next, format: .dateTime.month().day().hour().minute())
                }
            }
        } header: {
            Text("状态")
        }
    }
}

/// 「图库目录」二级页面：只读列表（类型、路径、挂载状态、上次扫描到的张数），可以重新检查挂载。
/// 信息来自电脑推的状态快照；离线时显示的是上次同步的那一份，挂载状态可能已经变了。
struct LibraryDirsView: View {
    let session: RemoteSession

    var body: some View {
        Group {
            if let dirs = session.state?.dirs {
                List {
                    if session.offline {
                        Section {
                            NoticeRow(icon: "wifi.slash", title: "现在无法连接电脑，下面是上次同步的信息",
                                      detail: "挂载状态和张数可能已经变化，连接电脑后可以重新检查。")
                        }
                    }
                    Section {
                        ForEach(dirs) { d in
                            row(d)
                        }
                        Button {
                            Task { await session.checkMounts() }
                        } label: {
                            Label("重新检查挂载", systemImage: "arrow.clockwise")
                        }
                        .disabled(session.offline)
                    } header: {
                        HelpHeader("目录", "挂载状态由电脑检查。点「重新检查挂载」后，电脑会重新检查这些目录，再把结果发回来。目录只能在电脑上的「图库」页增删。")
                    }
                }
                .contentWidthCap(max: 680)
            } else {
                ContentUnavailableView("没有目录信息", systemImage: "externaldrive",
                                       description: Text("电脑上的拾景版本较旧，升级后会显示图库目录。"))
            }
        }
        .navigationTitle("图库目录")
        .connectionToolbar(session)
    }

    private func row(_ d: LibraryDir) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: d.filter ? "scissors" : "heart")
                .foregroundStyle(d.filter ? Color.orange : Color.accentColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(d.name).font(.subheadline.bold()).lineLimit(1).truncationMode(.middle)
                Text(d.path).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Text(detail(d)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            mountBadge(d)
        }
    }

    private func detail(_ d: LibraryDir) -> String {
        var s = d.filter ? "筛选 + 采样" : "仅采样"
        if d.images > 0 || d.folders > 0 {
            s += " · \(d.images) 张 · \(d.folders) 个文件夹"
        }
        if let n = d.deleted, n > 0 { s += " · 删过 \(n) 张" }
        return s
    }

    private func mountBadge(_ d: LibraryDir) -> some View {
        Text(d.mountText)
            .font(.caption2.bold())
            .foregroundStyle(mountColor(d.mount))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(mountColor(d.mount).opacity(0.12), in: Capsule())
            .fixedSize()
    }

    private func mountColor(_ mount: String) -> Color {
        switch mount {
        case "ok": .green
        case "missing": .red
        case "slow": .orange
        default: .secondary
        }
    }
}

/// 这台手机上拾景的版本号（和电脑端同一套，见 project.yml 的 MARKETING_VERSION）。
enum AppVersion {
    static let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    static var text: String { short.isEmpty ? "开发版" : "v" + short }
}

/// 系统分组列表自带的内容留白（窄屏时不额外加，保持原样）。
private let baseInset: CGFloat = 20

extension View {
    /// 内容最宽 `cap`、居中；比 `cap` 窄时铺满，系统列表自带的留白照旧。
    /// **收窄的是内容，不是列表本身**：列表保持全宽，滚动条才落在列表右边（和系统设置一样）。
    /// 用 `contentMargins` 而不是给列表加 padding / frame——那两样会把滚动条一起挪到内容边上。
    /// 窄屏也得给足系统默认的留白（`baseInset`），设成 0 会把列表自带的留白顶掉、卡片贴着屏幕边（v0.3.156 踩过）。
    /// 宽度用 `GeometryReader` 现量，不依赖页面级的 `@State`：分页 TabView 里没显示过的页
    /// 不会因为外层宽度变化就重建，状态量到的是 0（v0.3.157 踩过）。
    func contentWidthCap(max cap: CGFloat) -> some View {
        GeometryReader { g in
            let pad = max(baseInset, (g.size.width - cap) / 2)
            self
                .contentMargins(.leading, pad, for: .scrollContent)
                .contentMargins(.trailing, pad, for: .scrollContent)
        }
    }
}
