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

/// 「设置」页：分两类——「电脑上的拾景」（改的是电脑，改完电脑上的设置页同步变、自动保存）
/// 和「这台手机」（离线缓存、待处理操作这些手机自己的东西）。顶部用分段控件切换，选过哪一类会记住。
/// 旧版桌面端不推 settings，电脑那一类就只读显示。
struct SettingsPage: View {
    let session: RemoteSession
    /// 每次张数的草稿：步进器连点时先改这里，停手 0.8 秒再发给电脑
    @State private var draftCount: Int?
    @State private var countTask: Task<Void, Never>?
    /// 自定义分辨率的草稿：同上，攒一会儿再发
    @State private var draftW: Int?
    @State private var draftH: Int?
    @State private var resTask: Task<Void, Never>?
    /// 设置分三类：mac = 电脑上的拾景（遥控改的），phone = 这台手机（离线缓存等），about = 版本和签名
    @AppStorage("settingsGroup") private var groupRaw = "mac"
    /// 显示过的栏：没显示过的不构建内容（电脑状态每秒推一次，三页 List 不必一起重建）
    @State private var seenGroups: Set<String> = []
    var body: some View {
        Group {
            if let state = session.state {
                #if DEBUG
                // 截图用：-demoOfflineCache 只摆离线这一组（设置页太长，模拟器里不好滚到最下面）；
                // -demoQueue 只摆「待处理操作」这一组（点进去是专门的页面）；
                // -demoLibrary 只摆「图库 / 待删除」两组（配 -demoPending 看电脑上排队的删除）
                if let demo = demoPage(state) {
                    demo
                } else {
                    pager(state)
                }
                #else
                pager(state)
                #endif
            } else {
                ConnectionFallback(session: session)
            }
        }
        .frame(width: demoWidth, height: demoHeight)
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            #if DEBUG
            // 截图用：-demoAbout 直接切到「关于」这一栏，-demoMacGroup 切回「电脑上的拾景」
            if ProcessInfo.processInfo.arguments.contains("-demoAbout") { groupRaw = SettingsGroup.about.rawValue }
            if ProcessInfo.processInfo.arguments.contains("-demoMacGroup") { groupRaw = SettingsGroup.mac.rawValue }
            if ProcessInfo.processInfo.arguments.contains("-demoPhoneGroup") { groupRaw = SettingsGroup.phone.rawValue }
            #endif
        }
        // 三栏切换放在导航栏下面、一条整宽的栏里：导航栏中间只剩两百多 pt（右边还有连接徽标），
        // 三个中文标签放不下，窄屏上会被挤成「电脑上的…」。放这里滚到哪儿都看得到，还能左右滑。
        .safeAreaInset(edge: .top, spacing: 0) {
            if showsPager { groupPicker }
        }
        .toolbar {
            if session.savingSettings {
                ToolbarItem(placement: .automatic) { ProgressView() } // 正在把改动发给电脑
            }
        }
        .connectionToolbar(session)
    }

    /// 截图用：-demoWidth 951 -demoHeight 560 按指定尺寸排版（模拟器里没法把 Duo 展开，
    /// 借大屏模拟器按内屏的尺寸看排版；内屏是 951×669，扣掉状态栏、导航栏和切换栏约 560 高）。
    private var demoWidth: CGFloat? { demoSize("-demoWidth") }
    private var demoHeight: CGFloat? { demoSize("-demoHeight") }

    private func demoSize(_ name: String) -> CGFloat? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: name), i + 1 < args.count { return CGFloat(Double(args[i + 1]) ?? 0) }
        #endif
        return nil
    }

    /// 三栏切换：整宽一条，内容最宽 680 居中，和下面列表的内容对齐。
    private var groupPicker: some View {
        Picker("设置分类", selection: $groupRaw) {
            Text("电脑上的拾景").tag(SettingsGroup.mac.rawValue)
            Text(ThisDevice.label).tag(SettingsGroup.phone.rawValue)
            Text("关于").tag(SettingsGroup.about.rawValue)
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 680)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    /// 三栏分页才要切换控件；截图用的单页（-demoOfflineCache 这些）不显示。
    private var showsPager: Bool {
        guard session.state != nil else { return false }
        #if DEBUG
        if let state = session.state, demoPage(state) != nil { return false }
        #endif
        return true
    }

    /// 三栏并排，左右滑也能切换（分段控件和翻页用同一个 selection）。
    private func pager(_ state: RemoteState) -> some View {
        TabView(selection: $groupRaw) {
            macPage(state, built: builtGroups.contains(SettingsGroup.mac.rawValue))
                .tag(SettingsGroup.mac.rawValue)
            page(builtGroups.contains(SettingsGroup.phone.rawValue)) { phoneContent(state) }
                .tag(SettingsGroup.phone.rawValue)
            page(builtGroups.contains(SettingsGroup.about.rawValue)) { aboutContent(state) }
                .tag(SettingsGroup.about.rawValue)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .onChange(of: groupRaw) { _, new in seenGroups.insert(new) }
    }

    /// 当前栏和左右邻居先构建好（滑过去不会空一帧），更远、也从没显示过的先留空。
    private var builtGroups: Set<String> {
        let order = [SettingsGroup.mac.rawValue, SettingsGroup.phone.rawValue, SettingsGroup.about.rawValue]
        var s = seenGroups
        if let i = order.firstIndex(of: groupRaw) {
            s.insert(order[i])
            if i > 0 { s.insert(order[i - 1]) }
            if i + 1 < order.count { s.insert(order[i + 1]) }
        }
        return s
    }

    private func page<Content: View>(_ built: Bool, @ViewBuilder content: () -> Content) -> some View {
        List {
            if built { content() }
        }
        .contentWidthCap(max: 680)
    }

    #if DEBUG
    /// 截图用的单页（不是三栏）。
    private func demoPage(_ state: RemoteState) -> AnyView? {
        let args = ProcessInfo.processInfo.arguments
        let content: AnyView?
        if args.contains("-demoQueue") {
            content = session.queued.isEmpty ? nil : AnyView(offlineQueueLink)
        } else if args.contains("-demoLibrary") {
            content = AnyView(Group {
                if state.dirs != nil { libraryLink(state) }
                pendingQueueSection
            })
        } else if args.contains("-demoOfflineCache") {
            content = AnyView(Group {
                offlineSection
                if !session.queued.isEmpty { offlineQueueLink }
            })
        } else {
            content = nil
        }
        guard let content else { return nil }
        return AnyView(List { content }
            .contentWidthCap(max: 680))
    }
    #endif

    /// 关于：两边各是什么版本、这台设备上的签名什么时候到期。
    /// 不和「这台手机」的设置混在一起（v0.3.132 一度独立成页、入口在概览，用户觉得首页放它奇怪，改回设置里的第三栏）。
    @ViewBuilder
    private func aboutContent(_ state: RemoteState) -> some View {
        Section {
            LabeledContent("电脑上的拾景", value: macVersion(state))
            LabeledContent(ThisDevice.label, value: AppVersion.text)
        } header: {
            Text("版本")
        } footer: {
            if !state.version.isEmpty, state.version != AppVersion.short {
                Text("两边版本不一致，有的功能可能用不了，建议两边都升级到最新版本。")
            }
        }
        if let expiry = SigningExpiry.text {
            Section {
                LabeledContent("签名", value: expiry)
            } header: {
                HelpHeader(ThisDevice.label, "免费签名 7 天到期，到期后拾景无法启动。在电脑上重新安装一次就能续上，设置和配对都会保留。")
            }
        }
    }

    private func macVersion(_ state: RemoteState) -> String {
        state.version.isEmpty ? "尚未连接" : "v" + state.version
    }

    /// 这台手机：离线缓存、离线时记下的待处理操作，还有两边的版本。
    @ViewBuilder
    private func phoneContent(_ state: RemoteState) -> some View {
        if !session.queued.isEmpty { offlineQueueLink }
        offlineSection
    }

    /// 电脑上的拾景：一个列表（和系统设置一样），内容最宽 680、居中。
    /// 不做左右两栏：并排两个 List 各有各的滚动条，左栏那条落在屏幕中间、贴着右栏内容，
    /// 而原生列表没法让滚动条跑到整页最右边——宽屏统一成单栏，滚动条才和系统设置一样在右边。
    @ViewBuilder
    private func macPage(_ state: RemoteState, built: Bool) -> some View {
        List {
            if built { macContent(state) }
        }
        .contentWidthCap(max: 680)
    }

    /// 单栏时的顺序：离线提示 → 输出 / 采样 / 画质 / 归档 → 筛选 / 自动换 / 系统 → 图库入口 → 待删除。
    @ViewBuilder
    private func macContent(_ state: RemoteState) -> some View {
        macNoticeSection(state)
        macLeftSections(state)
        macRightSections(state)
    }

    /// 左栏：输出和采样这一路（改的是怎么选图、怎么存）。
    @ViewBuilder
    private func macLeftSections(_ state: RemoteState) -> some View {
        let disabled = state.running || session.connection != .live
        if let set = state.settings {
            outputSection(set, state, disabled)
            samplingSection(set, disabled)
            if set.minPresets != nil, set.minWidth != nil, set.minHeight != nil {
                resolutionSection(set, disabled: disabled)
            }
            if set.archiveEnabled != nil {
                archiveSection(set, disabled: disabled)
            }
        } else {
            Section {
                LabeledContent("每次换", value: "\(state.sampleCount) 张")
            } footer: {
                Text("电脑上的拾景版本较旧，要改设置请在电脑上改。")
            }
        }
    }

    /// 右栏：筛选、自动换、系统，以及两个入口（图库目录、待删除）。
    @ViewBuilder
    private func macRightSections(_ state: RemoteState) -> some View {
        let disabled = state.running || session.connection != .live
        if let set = state.settings {
            filterSection(set, disabled)
            autoSection(set, state, disabled)
            systemSection(set, disabled)
        }
        if state.dirs != nil {
            libraryLink(state)
        }
        pendingQueueSection
    }

    /// 连不上电脑时最上面那条提醒。
    @ViewBuilder
    private func macNoticeSection(_ state: RemoteState) -> some View {
        if session.connection != .live {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("现在无法连接电脑，设置仅可查看").font(.subheadline.bold())
                        Text("改设置、更换壁纸都需要连接电脑。离线时记录的「移出」「不再选」连接后自动处理；「删除原图」连接后还需要再确认一次。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "wifi.slash").foregroundStyle(.orange)
                }
            }
        }
    }

    @ViewBuilder
    private func outputSection(_ set: RemoteSettings, _ state: RemoteState, _ disabled: Bool) -> some View {
        Section {
            LabeledContent("壁纸文件夹", value: state.dest)
            if set.mode != nil {
                Picker("存放方式", selection: Binding(
                    get: { set.mode ?? "copy" },
                    set: { v in Task { await session.updateSettings(["mode": v]) } }
                )) {
                    Text("复制").tag("copy")
                    Text("软链接").tag("symlink")
                }
                .disabled(disabled)
            }
        } header: {
            HelpHeader("输出", "复制：每张图在壁纸文件夹里存一份，占空间；图库未连接时仍可查看。\n软链接：只存指向原图的链接，省空间；图库未连接时这些图片无法显示。")
        }
    }

    @ViewBuilder
    private func samplingSection(_ set: RemoteSettings, _ disabled: Bool) -> some View {
        Section {
            Stepper(value: Binding(
                get: { draftCount ?? set.sampleCount },
                set: { setCount($0) }
            ), in: 1...9999, step: (draftCount ?? set.sampleCount) < 50 ? 5 : 10) {
                LabeledContent("每次张数", value: "\(draftCount ?? set.sampleCount) 张")
            }
            .disabled(disabled)
            if let balance = set.balanceFirst {
                toggle("平衡采样", balance, key: "balance_first", disabled: disabled)
            }
            toggle("优先选未更换过的", set.preferUnseen, key: "prefer_unseen", disabled: disabled)
        } header: {
            HelpHeader("采样", "平衡采样：优先让每个子文件夹至少入选一张，避免少数几个大文件夹占满名额。\n优先选未更换过的：本轮尚未更换过的图片优先入选，整个图库都更换过一遍后再从头开始。")
        }
    }

    @ViewBuilder
    private func filterSection(_ set: RemoteSettings, _ disabled: Bool) -> some View {
        Section {
            toggle("删除不合格的原图", set.deleteDuringFilter, key: "delete_during_filter", tint: .red, disabled: disabled)
            if let incremental = set.incremental {
                toggle("增量筛选", incremental, key: "incremental", disabled: disabled)
            }
        } header: {
            HelpHeader("筛选", "打开后，更换壁纸时会删除图库中竖屏、接近正方形、分辨率不够的原图，且不可撤销。从手机更换时会先确认，也可以选择本次仅模拟。\n增量筛选会跳过上次检查后没有变化的文件夹。")
        }
    }

    @ViewBuilder
    private func autoSection(_ set: RemoteSettings, _ state: RemoteState, _ disabled: Bool) -> some View {
        Section {
            Picker("间隔", selection: Binding(
                get: { set.autoRunHours },
                set: { h in Task { await session.updateSettings(["auto_run_hours": h]) } }
            )) {
                // 配置里是不在选项里的值（手动改过配置文件）时也显示出来，免得选中项为空
                ForEach(set.autoOptions.contains(set.autoRunHours) ? set.autoOptions : set.autoOptions + [set.autoRunHours], id: \.self) {
                    Text(RemoteSettings.autoLabel($0)).tag($0)
                }
            }
            .disabled(disabled)
            if let next = state.nextAutoDate {
                LabeledContent("下一次") {
                    Text(next, format: .dateTime.month().day().hour().minute())
                }
            }
        } header: {
            HelpHeader("自动换壁纸", "电脑上的拾景开着时按这个间隔自动换一批。自动运行不会删除原图。")
        }
    }

    @ViewBuilder
    private func systemSection(_ set: RemoteSettings, _ disabled: Bool) -> some View {
        Section {
            toggle("刷新系统壁纸", set.refreshWallpaper, key: "refresh_wallpaper", disabled: disabled)
        } header: {
            HelpHeader("系统", "更换一批后重启 macOS 的壁纸服务，否则系统会继续轮换已经删掉的旧图。图库目录的添加和移除、归档位置等在电脑上修改。")
        }
    }

    /// 画质要求：预设菜单 + 自定义时两个步进器（改动攒 0.6 秒再发给电脑）。
    @ViewBuilder
    private func resolutionSection(_ set: RemoteSettings, disabled: Bool) -> some View {
        let presets = set.minPresets ?? []
        Section {
            Picker("最低分辨率", selection: Binding(
                get: { set.presetIndex },
                set: { i in
                    guard i < presets.count else { return }
                    let p = presets[i]
                    Task { await session.updateSettings(["min_width": p.w, "min_height": p.h]) }
                }
            )) {
                ForEach(Array(presets.enumerated()), id: \.offset) { i, p in
                    // verbatim：普通插值会把数字按本地化格式加上千分位（3,840）
                    Text(verbatim: "\(p.label) · \(p.w)×\(p.h)").tag(i)
                }
                Text("自定义").tag(presets.count)
            }
            .disabled(disabled)
            if set.presetIndex == presets.count {
                Stepper(value: Binding(
                    get: { draftW ?? set.minWidth ?? 3840 },
                    set: { w in setResolution(w: w, h: draftH ?? set.minHeight ?? 2160) }
                ), in: 100...99999, step: 100) {
                    LabeledContent("宽", value: "\(draftW ?? set.minWidth ?? 0) 像素")
                }
                .disabled(disabled)
                Stepper(value: Binding(
                    get: { draftH ?? set.minHeight ?? 2160 },
                    set: { h in setResolution(w: draftW ?? set.minWidth ?? 3840, h: h) }
                ), in: 100...99999, step: 100) {
                    LabeledContent("高", value: "\(draftH ?? set.minHeight ?? 0) 像素")
                }
                .disabled(disabled)
            }
        } header: {
            HelpHeader("画质要求", "只选横图（宽高比大于 1.1），分辨率不低于这里设定的值。")
        }
    }

    /// 归档：手机上只给开关，位置和跨挂载点换算在电脑上设。
    @ViewBuilder
    private func archiveSection(_ set: RemoteSettings, disabled: Bool) -> some View {
        Section {
            toggle("启用归档", set.archiveEnabled ?? false, key: "archive_enabled", disabled: disabled)
            if set.archiveEnabled == true {
                LabeledContent("位置") {
                    Text(archivePath(set))
                        .font(.footnote)
                        .multilineTextAlignment(.trailing)
                }
            }
        } header: {
            HelpHeader("归档", "每次选中的图片会在图库旁边留一份链接，每次运行前清掉上一批。位置和文件夹名在电脑上改。")
        }
    }

    private func archivePath(_ set: RemoteSettings) -> String {
        if let dir = set.archiveDir, !dir.isEmpty { return dir }
        return "各图库目录的上级 / \(set.archiveSubdir ?? "_WallpaperArchive")"
    }

    /// 图库目录：设置页里只占一行，点开是二级页面（目录多的时候不再把设置页撑长）。
    private func libraryLink(_ state: RemoteState) -> some View {
        Section {
            NavigationLink {
                LibraryDirsView(session: session)
            } label: {
                LabeledContent("图库目录", value: "\(state.libraryDirs) 个")
            }
        } header: {
            HelpHeader("图库", "筛选 + 采样会先删掉不合格的原图；仅采样不动文件。目录只能在电脑上的「图库」页增删，手机上是只读的。")
        }
    }

    /// 电脑上排队的删除原图（图库没连上时排的队），可以逐条或全部取消。
    @ViewBuilder
    private var pendingQueueSection: some View {
        if let items = session.state?.pendingItems, !items.isEmpty {
            Section {
                ForEach(items) { it in
                    HStack(spacing: 12) {
                        Image(systemName: "clock").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(it.wall ?? it.name).font(.subheadline)
                            Text(it.display).font(.footnote).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                            Text(it.date, format: .dateTime.month().day().hour().minute())
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button("取消") { Task { await session.cancelPending(it) } }
                            .buttonStyle(.borderless)
                            .disabled(session.connection != .live)
                    }
                }
                if items.count > 1 {
                    Button("全部取消", role: .destructive) { Task { await session.cancelAllPending() } }
                        .disabled(session.connection != .live)
                }
            } header: {
                HelpHeader("待删除（\(items.count)）", "图库未连接时，需要删除的原图会先排在电脑上，图库连接后自动删除。取消后这张原图保留；壁纸文件夹中的那一份已在手机上移出。")
            }
        }
    }

    /// 离线时记下的整理：这里只放入口，点开是专门的页面（缩略图预览、逐张确认删除）。
    private var offlineQueueLink: some View {
        let n = session.queued.count
        let deletes = session.queuedDeletes.count
        return Section {
            NavigationLink {
                QueuedActionsView(session: session)
            } label: {
                LabeledContent {
                    Text(deletes > 0 ? "\(n) 项 · 其中 \(deletes) 张等确认删除" : "\(n) 项")
                } label: {
                    HStack(spacing: 8) {
                        if deletes > 0 {
                            Image(systemName: "trash").foregroundStyle(.red)
                        }
                        Text("查看")
                    }
                }
            }
        } header: {
            HelpHeader("待处理操作", "离线时记录的整理：「移出」「不再选」连接电脑后自动处理；「删除原图」不可撤销，连接后还要逐张（或全部）确认才会删除。")
        }
    }

    /// 离线：四档缓存各存了多少、共用哪个上限，可以暂停 / 继续 / 清除。和电脑上的设置无关，旧版桌面端也有。
    private var offlineSection: some View {
        OfflineCacheSection(session: session)
    }

    private func toggle(_ title: String, _ value: Bool, key: String, tint: Color? = nil, disabled: Bool) -> some View {
        Toggle(title, isOn: Binding(
            get: { value },
            set: { v in Task { await session.updateSettings([key: v]) } }
        ))
        .tint(tint)
        .disabled(disabled)
    }

    private func setCount(_ n: Int) {
        draftCount = n
        countTask?.cancel()
        countTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            await session.updateSettings(["sample_count": n])
            draftCount = nil
        }
    }

    /// 自定义分辨率：步进器连点时先改草稿，停手 0.6 秒再一起发给电脑。
    private func setResolution(w: Int, h: Int) {
        draftW = w
        draftH = h
        resTask?.cancel()
        resTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await session.updateSettings(["min_width": w, "min_height": h])
            draftW = nil
            draftH = nil
        }
    }
}

/// 设置页的三栏：电脑上的拾景（遥控改的）/ 这台手机（离线缓存等）/ 关于（版本、签名）。
enum SettingsGroup: String {
    case mac, phone, about
}

/// 「图库目录」二级页面：只读列表（类型、路径、挂载状态、上次扫描到的张数），可以重新检查挂载。
/// 信息来自电脑推的状态快照；离线时显示的是上次同步的那一份，挂载状态可能已经变了。
struct LibraryDirsView: View {
    let session: RemoteSession
    @State private var width: CGFloat = 0

    var body: some View {
        Group {
            if let dirs = session.state?.dirs {
                List {
                    if session.connection != .live {
                        Section {
                            Label {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("现在无法连接电脑，下面是上次同步的信息").font(.subheadline.bold())
                                    Text("挂载状态和张数可能已经变化，连接电脑后可以重新检查。")
                                        .font(.footnote).foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "wifi.slash").foregroundStyle(.orange)
                            }
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
                        .disabled(session.connection != .live)
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
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
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

/// 离线缓存：这一批壁纸（网格、大图，开了「保存原图」再加上图库里的原文件）存到手机上。
/// 一个队列、一个上限：超过「缓存上限」就不再往后存。这些都是手机本地的设置，不用连电脑也能改。
private struct OfflineCacheSection: View {
    let session: RemoteSession
    @State private var usage: ImageStore.Usage?
    @AppStorage(ImageStore.cacheLimitKey) private var limitGB = ImageStore.defaultCacheLimitGB
    @AppStorage(ImageStore.cacheOriginalsKey) private var keepOriginals = false

    private var store: ImageStore { .shared }
    private var total: Int { session.walls.count }
    /// 这一批里离线能看到大图的张数（有大图或原图都算）
    private var viewable: Int { usage?.viewable ?? 0 }
    /// 这一批还有没存到手机上的：大图（或能本地缩的原图）缺一档算一个，开了「保存原图」时原图另算一个。
    /// 只看 viewable 会把「大图都存好了、原图还没存完」当成存完了，这时候「补齐」是灰的、按不下去。
    private var missing: Bool {
        guard total > 0 else { return false }
        if viewable < total { return true }
        return keepOriginals && (usage?.data(.original).inBatch ?? 0) < total
    }

    var body: some View {
        Section {
            Group {
                // 四档缓存各一行：这一批里存了多少张 / 这一批共多少张 · 占多少
                cacheRow(.thumb, "缩略图缓存", "网格里每一格用的小图，宽 360 像素。")
                cacheRow(.hero, "横幅缓存", "概览顶部的横幅图，宽 1600 像素；每批只存一张。")
                cacheRow(.image, "大图缓存", "打开大图时用的那张，宽 2732 像素，铺满展开的 iPhone Duo 这类大屏；存了原图时也可以从原图在本地缩小，不再下载。")
                cacheRow(.original, "原图缓存", "图库里的原文件，和电脑上那份一样大；打开「保存原图」才会存，离线时可以存到相册、分享原图。")

                HStack {
                    if store.prefetching { ProgressView().controlSize(.small) }
                    Text(statusText).foregroundStyle(.secondary)
                    Spacer()
                    if store.prefetching {
                        Button("暂停") {
                            store.pausePrefetch()
                            refresh()
                        }
                    } else {
                        Button("补齐") {
                            store.prefetch(session)
                            refresh()
                        }
                        .disabled(session.offline || session.walls.isEmpty || (!missing && !store.prefetchHitLimit))
                    }
                }

                Toggle("保存原图", isOn: $keepOriginals)
                    .onChange(of: keepOriginals) { _, on in
                        guard on else {
                            // 关掉就不再往下存原图（已经存下的留着）。队列是在开始前排好的，
                            // 这里先暂停；再点「补齐」重排一遍就不带原图了
                            if store.prefetching { store.pausePrefetch() }
                            refresh()
                            return
                        }
                        guard !session.offline, !session.walls.isEmpty else { return }
                        store.prefetch(session) // 已经存下的会跳过，接着往下存原图
                        refresh()
                    }

                Stepper(value: $limitGB, in: 1...50) {
                    Text("缓存上限 \(limitGB) GB")
                }
                .onChange(of: limitGB) { _, _ in
                    guard !session.offline, !session.walls.isEmpty else { refresh(); return }
                    if !store.prefetching { store.prefetch(session) } // 上限调大了，接着往下存
                    refresh()
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("已用 \(bytes(usage?.used)) / \(limitGB) GB")
                        Spacer()
                        Button("清除") {
                            store.clear()
                            refresh()
                        }
                        .disabled((usage?.used ?? 0) == 0)
                    }
                    ProgressView(value: fraction)
                }
            }
            .task { refresh() }
            .onChange(of: store.prefetching) { _, running in if !running { refresh() } }
            .onChange(of: store.prefetchDone) { _, _ in
                // 存的过程中不用每张都数一遍文件，隔一阵更新一次
                if store.prefetchDone % 20 == 0 { refresh() }
            }
            .onChange(of: store.prefetchOriginalDone) { _, _ in
                if store.prefetchOriginalDone % 20 == 0 { refresh() }
            }
        } header: {
            HelpHeader("离线", "无法连接电脑时，概览和壁纸显示的是上次同步的内容；更换一批后，不在这批里的图片会删除。打开「保存原图」会把图库中的原文件也保存下来，离线时可以存到相册、分享原图，直到达到「缓存上限」。")
        }
    }

    /// 一档缓存一行：标签旁的问号说明这一档多大、做什么用。
    private func cacheRow(_ kind: ImageKind, _ title: String, _ help: String) -> some View {
        LabeledContent {
            Text(cacheDetail(kind)).foregroundStyle(.secondary)
        } label: {
            HelpLabel(title, help)
        }
    }

    private func cacheDetail(_ kind: ImageKind) -> String {
        guard let usage else { return "正在统计…" }
        let d = usage.data(kind)
        let size = bytes(d.bytes)
        // 横幅每批只有一张，写「1 / 1」反而怪
        if kind == .hero { return "\(d.count) 张 · \(size)" }
        guard total > 0 else { return "—" }
        return "\(d.inBatch) / \(total) 张 · \(size)"
    }

    private var statusText: String {
        if store.prefetching {
            // 大图存完再存原图，两段各按「这一批多少张」算，别把两个数加起来（400 张的批次写 800 会让人以为存多了）
            if store.prefetchDone < store.prefetchTotal {
                return "正在缓存大图 \(store.prefetchDone) / \(store.prefetchTotal) 张"
            }
            return "正在缓存原图 \(store.prefetchOriginalDone) / \(store.prefetchTotal) 张"
        }
        if store.prefetchHitLimit { return "已到上限，剩下的没存" }
        if store.prefetchPaused { return "已暂停" }
        if missing { return "尚未缓存完" }
        return "全部存好了"
    }

    private var fraction: Double {
        guard limitGB > 0, let used = usage?.used, used > 0 else { return 0 }
        return min(1, Double(used) / Double(limitGB * 1_000_000_000))
    }

    private func bytes(_ n: Int64?) -> String {
        guard let n else { return "…" }
        return n == 0 ? "没有" : ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    private func refresh() {
        let names = session.walls.map(\.name)
        Task {
            // 刚点过「清除」时等文件删完再数，不然显示的还是清之前的大小
            await store.waitForClear()
            // 一次量完：列一遍目录就有各档的张数和大小，不用一档列一遍
            usage = await Task.detached(priority: .utility) {
                ImageStore.usage(names: names)
            }.value
        }
    }
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
