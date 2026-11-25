import SwiftUI

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
    @State private var confirmCancelAllPending = false
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
        .onDisappear {
            flushPendingEdits()
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
            page(builtGroups.contains(SettingsGroup.mac.rawValue)) { macContent(state) }
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
        offlineModeSection
        offlineSection
    }

    /// 离线模式：打开后停止连接电脑（事件流、后台缓存、小组件刷新都不发请求），只看手机上的缓存。
    private var offlineModeSection: some View {
        @Bindable var mode = OfflineMode.shared
        return Section {
            Toggle("离线模式", isOn: $mode.manual)
            Toggle("使用蜂窝网络时离线", isOn: $mode.onCellular)
            if let hold = session.hold {
                Text(hold.message).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            HelpHeader("离线模式", "打开后拾景和小组件停止连接电脑，只显示手机上缓存的状态和图片，不发网络请求。这期间的「移出」「不再选」「删除原图」会记下来，退出离线模式、连接电脑后处理。「使用蜂窝网络时离线」：手机只有蜂窝网络时自动进入离线模式，连接 Wi‑Fi 后自动连接电脑。")
        }
    }

    /// 电脑上的拾景：一个列表（和系统设置一样），内容最宽 680、居中。
    /// 不做左右两栏：并排两个 List 各有各的滚动条，左栏那条落在屏幕中间、贴着右栏内容，
    /// 而原生列表没法让滚动条跑到整页最右边——宽屏统一成单栏，滚动条才和系统设置一样在右边。
    /// 顺序：离线提示 → 输出 / 采样 / 画质 / 归档 → 筛选 / 自动换 / 系统 → 图库入口 → 待删除。
    @ViewBuilder
    private func macContent(_ state: RemoteState) -> some View {
        let disabled = state.running || session.offline
        macNoticeSection
        ProfilesSection(session: session, state: state, showHelpHeader: true)
        if let set = state.settings {
            outputSection(set, state, disabled)
            samplingSection(set, disabled)
            if set.minPresets != nil, set.minWidth != nil, set.minHeight != nil {
                resolutionSection(set, disabled: disabled)
            }
            if set.archiveEnabled != nil {
                archiveSection(set, disabled: disabled)
            }
            filterSection(set, disabled)
            autoSection(set, state, disabled)
            systemSection(set, disabled)
        } else {
            Section {
                LabeledContent("每次换", value: "\(state.sampleCount) 张")
            } footer: {
                Text("电脑上的拾景版本较旧，要改设置请在电脑上改。")
            }
        }
        if state.dirs != nil {
            libraryLink(state)
        }
        pendingQueueSection
    }

    /// 连不上电脑时最上面那条提醒。
    @ViewBuilder
    private var macNoticeSection: some View {
        if session.offline {
            Section {
                NoticeRow(icon: "wifi.slash", title: "现在无法连接电脑，设置仅可查看",
                          detail: "改设置、更换壁纸都需要连接电脑。离线时记录的「移出」「不再选」连接后自动处理；「删除原图」连接后还需要再确认一次。")
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
                            .disabled(session.offline)
                    }
                }
                if items.count > 1 {
                    Button("全部取消", role: .destructive) { confirmCancelAllPending = true }
                        .disabled(session.offline)
                }
            } header: {
                HelpHeader("待删除（\(items.count)）", "图库未连接时，需要删除的原图会先排在电脑上，图库连接后自动删除。取消后这张原图保留；壁纸文件夹中的那一份已在手机上移出。")
            }
            .confirmationDialog("取消全部 \(items.count) 项排队删除？", isPresented: $confirmCancelAllPending, titleVisibility: .visible) {
                Button("全部取消", role: .destructive) { Task { await session.cancelAllPending() } }
                Button("返回", role: .cancel) {}
            } message: {
                Text("取消后这些原图都会保留在图库里，不再等待删除。")
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
            countTask = nil
            await session.updateSettings(["sample_count": n])
            if draftCount == n { draftCount = nil }
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
            resTask = nil
            await session.updateSettings(["min_width": w, "min_height": h])
            if draftW == w, draftH == h {
                draftW = nil
                draftH = nil
            }
        }
    }

    /// 离开设置页时把仍在防抖等待中的张数或分辨率草稿立即发出，避免切页静默丢弃修改。
    private func flushPendingEdits() {
        var patch: [String: Any] = [:]
        if countTask != nil, let n = draftCount {
            patch["sample_count"] = n
        }
        countTask?.cancel()
        countTask = nil
        draftCount = nil

        if resTask != nil, let w = draftW, let h = draftH {
            patch["min_width"] = w
            patch["min_height"] = h
        }
        resTask?.cancel()
        resTask = nil
        draftW = nil
        draftH = nil

        guard !patch.isEmpty else { return }
        let s = session
        Task { await s.updateSettings(patch) }
    }
}

/// 设置页的三栏：电脑上的拾景（遥控改的）/ 这台手机（离线缓存等）/ 关于（版本、签名）。
enum SettingsGroup: String {
    case mac, phone, about
}

