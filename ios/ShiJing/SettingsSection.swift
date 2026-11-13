import SwiftUI
import UIKit

/// 这台设备（iPhone / iPad）：设置页的分类名和「关于」里用它，平板上别写成「手机」。
enum ThisDevice {
    static var label: String { "这台 " + UIDevice.current.localizedModel }
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

/// 设置页和记录页共用的外壳：还没拿到状态时显示连接中 / 连不上，拿到了再显示内容（列表收窄到适合阅读的宽度）。
struct MacPage<Content: View>: View {
    let session: RemoteSession
    let title: String
    @ViewBuilder let content: (RemoteState) -> Content

    var body: some View {
        Group {
            if let state = session.state {
                List { content(state) }
                    // 内屏、iPad 上别拉得太宽（和电脑上设置页的单栏最宽一样的思路）
                    .contentWidthCap(max: 680)
            } else {
                ConnectionFallback(session: session)
            }
        }
        .navigationTitle(title)
        .connectionToolbar(session)
    }
}

/// 「设置」页：分两类——「电脑上的拾景」（改的是电脑，改完电脑上的设置页同步变、自动保存）
/// 和「这台手机」（离线缓存、待补操作这些手机自己的东西）。顶部用分段控件切换，选过哪一类会记住。
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
    /// 列表收窄到适合阅读的宽度（和电脑上的设置页一样），按上一帧量到的宽度算
    @State private var width: CGFloat = 0
    /// 高度：够高才分两栏（手机横放只有 400 出头，两栏会挤）
    @State private var height: CGFloat = 0
    /// 显示过的栏：没显示过的不构建内容（电脑状态每秒推一次，三页 List 不必一起重建）
    @State private var seenGroups: Set<String> = []

    var body: some View {
        Group {
            if let state = session.state {
                #if DEBUG
                // 截图用：-demoOfflineCache 只摆离线这一组（设置页太长，模拟器里不好滚到最下面）；
                // -demoQueue 只摆「待补操作」这一组（点进去是专门的页面）；
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
        // 量整页（含切换栏）：分不分两栏看的是整页有多大；量切换栏里面那块的话，
        // Duo 内屏只剩 500 出头，会被当成「太矮」
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            width = size.width
            height = size.height
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

    /// 三栏切换：整宽一条，内容区和下方的栏一样宽（宽屏两栏时跟着变宽）居中。
    private var groupPicker: some View {
        Picker("设置分类", selection: $groupRaw) {
            Text("电脑上的拾景").tag(SettingsGroup.mac.rawValue)
            Text(ThisDevice.label).tag(SettingsGroup.phone.rawValue)
            Text("关于").tag(SettingsGroup.about.rawValue)
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: twoColumn && groupRaw == SettingsGroup.mac.rawValue ? twoColMax : 680)
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

    /// 宽度够了才分左右两栏（iPad、Duo 内屏），和电脑上的设置页一致；单栏时最宽 680、居中。
    /// 高度也要够：Duo 内屏（整页 951×669）够，iPhone 横放只有 390 出头，两栏会挤成一团。
    /// 量的是整页高度（含切换栏），量切换栏里面那块的话内屏只剩 500 出头，会被当成太矮。
    private var twoColumn: Bool {
        #if DEBUG
        // 截图用：模拟器不好转成横屏，-demoTwoCol 直接按两栏排
        if ProcessInfo.processInfo.arguments.contains("-demoTwoCol") { return true }
        #endif
        return width >= twoColMin && height >= twoColMinHeight
    }
    private let twoColMin: CGFloat = 660
    private let twoColMinHeight: CGFloat = 500
    private let twoColMax: CGFloat = 1360

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
                Text("两边版本不一致，有的功能可能用不了，最好都升到最新。")
            }
        }
        if let expiry = SigningExpiry.text {
            Section {
                LabeledContent("签名", value: expiry)
            } header: {
                Text(ThisDevice.label)
            } footer: {
                Text("免费签名只有 7 天，到期后拾景就打不开了。连上电脑重新安装一次就能续上，设置和配对都会保留。")
            }
        }
    }

    private func macVersion(_ state: RemoteState) -> String {
        state.version.isEmpty ? "还没连上" : "v" + state.version
    }

    /// 这台手机：离线缓存、离线时记下的待补操作，还有两边的版本。
    @ViewBuilder
    private func phoneContent(_ state: RemoteState) -> some View {
        if !session.queued.isEmpty { offlineQueueLink }
        offlineSection
    }

    /// 电脑上的拾景：窄屏单栏（最宽 680 居中）；宽屏分左右两栏，和电脑上的设置页一个思路。
    @ViewBuilder
    private func macPage(_ state: RemoteState, built: Bool) -> some View {
        if twoColumn {
            HStack(alignment: .top, spacing: 24) { // 两栏中间留一点空，卡片别贴在一起
                List {
                    if built {
                        macNoticeSection(state)
                        macLeftSections(state)
                    }
                }
                .listStyle(.insetGrouped)
                List {
                    if built { macRightSections(state) }
                }
                .listStyle(.insetGrouped)
            }
            .padding(.horizontal, max(0, (width - twoColMax) / 2))
        } else {
            List {
                if built { macContent(state) }
            }
            .contentWidthCap(max: 680)
        }
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
                        Text("现在连不上电脑，设置只能查看").font(.subheadline.bold())
                        Text("改设置、换一批都要等连上电脑。离线时记下的「移出」「不再选」连上后会自动补上；「删除原图」连上后还要再确认一次。")
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
            Text("输出")
        } footer: {
            Text("复制：每张图在壁纸文件夹里存一份，占空间，但图库没连上也能看。\n软链接：只存指向原图的链接，省空间，图库没连上时打不开。")
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
            toggle("优先选没换上过的", set.preferUnseen, key: "prefer_unseen", disabled: disabled)
        } header: {
            Text("采样")
        } footer: {
            Text("平衡采样：优先让每个子文件夹至少入选一张，避免少数几个大文件夹占满名额。\n优先选没换上过的：这一轮里还没换上过的图片先选，都换上过一遍再从头开始。")
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
            Text("筛选")
        } footer: {
            Text("打开后，换一批时会删除图库里竖屏、接近正方形、分辨率不够的原图，不能撤销。从手机换一批时会先确认，也可以选这次只模拟。\n增量筛选会跳过上次检查后没有变化的文件夹。")
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
            Text("自动换壁纸")
        } footer: {
            Text("电脑上的拾景开着时按这个间隔自动换一批。自动运行不会删除原图。")
        }
    }

    @ViewBuilder
    private func systemSection(_ set: RemoteSettings, _ disabled: Bool) -> some View {
        Section {
            toggle("刷新系统壁纸", set.refreshWallpaper, key: "refresh_wallpaper", disabled: disabled)
        } header: {
            Text("系统")
        } footer: {
            Text("换完一批后重启 macOS 的壁纸服务，不然系统会继续轮换已经删掉的旧图。图库目录的添加和移除、归档位置等在电脑上改。")
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
            Text("画质要求")
        } footer: {
            Text("只选横图（宽高比大于 1.1），分辨率不低于这里设定的值。")
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
            Text("归档")
        } footer: {
            Text("每次选中的图片会在图库旁边留一份链接，每次运行前清掉上一批。位置和文件夹名在电脑上改。")
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
        } footer: {
            Text("筛选 + 采样会先删掉不合格的原图；仅采样不动文件。目录只能在电脑上的「图库」页增删，手机上是只读的。")
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
                Text("待删除（\(items.count)）")
            } footer: {
                Text("图库没连上时，要删的原图会先排在电脑上，图库连上后再自动删除。取消后这张原图保留；壁纸文件夹里的那一份在手机上已经移出了。")
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
                        Text("待补操作")
                    }
                }
            }
        } footer: {
            Text("离线时记下的整理：「移出」「不再选」连上电脑后自动补上；「删除原图」不可撤销，连上后还要逐张（或全部）确认才会删除。")
        }
    }

    /// 离线：预览图和原图各存了多少、共用哪个上限，可以暂停 / 继续 / 单独清除。和电脑上的设置无关，旧版桌面端也有。
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
                                    Text("现在连不上电脑，下面是上次同步的信息").font(.subheadline.bold())
                                    Text("挂载状态和张数可能已经变了，连上电脑后可以重新检查。")
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
                    } footer: {
                        Text("挂载状态由电脑检查。点「重新检查挂载」后，电脑会重新检查这些目录，结果再返回手机。目录只能在电脑上的「图库」页增删。")
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
    @State private var used: Int64?
    @State private var originalSize: Int64?
    @State private var originalCount = 0
    @State private var viewable = 0
    @AppStorage(ImageStore.cacheLimitKey) private var limitGB = ImageStore.defaultCacheLimitGB
    @AppStorage(ImageStore.cacheOriginalsKey) private var keepOriginals = false

    private var store: ImageStore { .shared }
    private var total: Int { session.walls.count }

    var body: some View {
        Section {
            Group {
                LabeledContent("离线可看") {
                    Text(total > 0 ? "\(viewable) / \(total) 张" : "—").foregroundStyle(.secondary)
                }

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
                        .disabled(session.offline || session.walls.isEmpty || (viewable >= total && !store.prefetchHitLimit))
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

                // 开关关掉后已经存下的原图还在手机上，也要能看见
                if keepOriginals || originalCount > 0 {
                    LabeledContent("原图") {
                        Text(detail(originalCount, originalSize)).foregroundStyle(.secondary)
                    }
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
                        Text("已用 \(bytes(used)) / \(limitGB) GB")
                        Spacer()
                        Button("清除") {
                            store.clear()
                            refresh()
                        }
                        .disabled((used ?? 0) == 0)
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
        } header: {
            Text("离线")
        } footer: {
            Text("连不上电脑时，概览和壁纸显示的是上次同步的内容，换一批后不在这批里的图会删掉。打开「保存原图」会把图库里的原文件也存下来，离线时能存到相册、分享原图。到了「缓存上限」就不再往后存。")
        }
    }

    private var statusText: String {
        if store.prefetching { return "正在缓存 \(store.prefetchDone) / \(store.prefetchTotal)" }
        if store.prefetchHitLimit { return "已到上限，剩下的没存" }
        if store.prefetchPaused { return "已暂停" }
        if viewable < total { return "还没存完" }
        return "全部存好了"
    }

    private var fraction: Double {
        guard limitGB > 0, let used, used > 0 else { return 0 }
        return min(1, Double(used) / Double(limitGB * 1_000_000_000))
    }

    private func detail(_ count: Int, _ size: Int64?) -> String {
        guard let size else { return "正在统计…" }
        return "\(count) / \(total) 张 · \(bytes(size))"
    }

    private func bytes(_ n: Int64?) -> String {
        guard let n else { return "…" }
        return n == 0 ? "没有" : ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    private func refresh() {
        let names = session.walls.map(\.name)
        Task {
            let (all, originals, views, origs) = await Task.detached(priority: .utility) {
                (ImageStore.diskUsage(),
                 ImageStore.cachedSize(kind: .original),
                 ImageStore.viewableCount(names: names),
                 ImageStore.cachedCount(kind: .original))
            }.value
            used = all
            originalSize = originals
            viewable = views
            originalCount = origs
        }
    }
}


extension View {
    /// 内容最宽 `cap`、居中；比 `cap` 窄时（手机）铺满，系统列表自带的留白照旧。
    /// 用 frame 收窄、不按量到的宽度算 `contentMargins`：分页 TabView 里没显示过的页
    /// 不会因为外层宽度变了就重建，量到的宽度还是 0 的话留白算出来就是 0——
    /// Duo 内屏上「这台 iPhone」「关于」两页因此比「电脑上的拾景」宽一大截。
    @ViewBuilder
    func contentWidthCap(max cap: CGFloat) -> some View {
        self
            .frame(maxWidth: cap)
            .frame(maxWidth: .infinity)
            .background(Color(uiColor: .systemGroupedBackground))
    }
}
