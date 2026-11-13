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
    @State private var width: CGFloat = 0

    var body: some View {
        Group {
            if let state = session.state {
                List { content(state) }
                    // 内屏、iPad 上别拉得太宽（和电脑上设置页的单栏最宽一样的思路）
                    .contentMargins(.horizontal, max(0, (width - 680) / 2), for: .scrollContent)
            } else {
                ConnectionFallback(session: session)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
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
    /// 设置分两类：mac = 电脑上的拾景（遥控改的），phone = 这台手机（离线缓存等）
    @AppStorage("settingsGroup") private var groupRaw = "mac"
    private var group: SettingsGroup { SettingsGroup(rawValue: groupRaw) ?? .mac }

    var body: some View {
        MacPage(session: session, title: "设置") { state in
            #if DEBUG
            // 截图用：-demoOfflineCache 只摆离线这一组（设置页太长，模拟器里不好滚到最下面）；
            // -demoQueue 只摆「待补操作」这一组（点进去是专门的页面）；
            // -demoLibrary 只摆「图库 / 待删除」两组（配 -demoPending 看电脑上排队的删除）
            if ProcessInfo.processInfo.arguments.contains("-demoQueue") {
                if !session.queued.isEmpty { offlineQueueLink }
            } else if ProcessInfo.processInfo.arguments.contains("-demoLibrary") {
                if state.dirs != nil { libraryLink(state) }
                pendingQueueSection
            } else if ProcessInfo.processInfo.arguments.contains("-demoOfflineCache") {
                offlineSection
                if !session.queued.isEmpty { offlineQueueLink }
            } else {
                switch group {
                case .mac: macContent(state)
                case .phone: phoneContent(state)
                case .about: aboutContent(state)
                }
            }
            #else
            switch group {
            case .mac: macContent(state)
            case .phone: phoneContent(state)
            case .about: aboutContent(state)
            }
            #endif
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            #if DEBUG
            // 截图用：-demoAbout 直接切到「关于」这一栏
            if ProcessInfo.processInfo.arguments.contains("-demoAbout") { groupRaw = SettingsGroup.about.rawValue }
            #endif
        }
        .toolbar {
            // 三栏切换固定在导航栏中间，滚到哪儿都看得到
            ToolbarItem(placement: .principal) {
                Picker("设置分类", selection: $groupRaw) {
                    Text("电脑上的拾景").tag(SettingsGroup.mac.rawValue)
                    Text(ThisDevice.label).tag(SettingsGroup.phone.rawValue)
                    Text("关于").tag(SettingsGroup.about.rawValue)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 340)
            }
            if session.savingSettings {
                ToolbarItem(placement: .automatic) { ProgressView() } // 正在把改动发给电脑
            }
        }
    }

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

    /// 电脑上的拾景：遥控改的都是电脑上的设置和状态。
    @ViewBuilder
    private func macContent(_ state: RemoteState) -> some View {
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
        if let set = state.settings {
            editable(set, state)
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

    /// 这台手机：离线缓存、离线时记下的待补操作，还有两边的版本。
    @ViewBuilder
    private func phoneContent(_ state: RemoteState) -> some View {
        if !session.queued.isEmpty { offlineQueueLink }
        offlineSection
    }

    @ViewBuilder
    private func editable(_ set: RemoteSettings, _ state: RemoteState) -> some View {
        let disabled = state.running || session.connection != .live
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
        if set.minPresets != nil, set.minWidth != nil, set.minHeight != nil {
            resolutionSection(set, disabled: disabled)
        }
        if set.archiveEnabled != nil {
            archiveSection(set, disabled: disabled)
        }
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
                    Text("\(p.label) · \(p.w)×\(p.h)").tag(i)
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

    /// 离线：图片缓存占了多少、上限多少，可以暂停 / 继续 / 清空。和电脑上的设置无关，旧版桌面端也有。
    private var offlineSection: some View {
        Section {
            OfflineCacheRow(session: session)
            OriginalCacheRow(session: session)
        } header: {
            Text("离线")
        } footer: {
            Text("连不上电脑时，概览和壁纸显示的是上次同步的内容。缩略图、横幅和大图会存到手机上，换一批后上一批的自动删掉。打开「保存原图」会把这一批的原文件也存下来，离线时能看原图、存到相册或分享；关掉后不再存新的，已经存下的可以点「清除」删掉。")
        }
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
                .contentMargins(.horizontal, max(0, (width - 680) / 2), for: .scrollContent)
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

/// 离线缓存的几行：占了多少、上限多少、整批缓存进度，可以暂停 / 继续 / 清除。
/// 这些都是手机本地的设置（UserDefaults），不用连电脑也能改。
private struct OfflineCacheRow: View {
    let session: RemoteSession
    @State private var size: Int64?
    @State private var cached = 0
    @AppStorage(ImageStore.cacheLimitKey) private var limitGB = ImageStore.defaultCacheLimitGB

    private var store: ImageStore { .shared }

    var body: some View {
        LabeledContent("预览图缓存") {
            HStack(spacing: 12) {
                if let size {
                    Text(size == 0 ? "没有" : ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
                Button("清除") {
                    store.clearPreviews(rev: session.wallsRev)
                    size = 0
                    cached = 0
                }
                .disabled(size == nil || size == 0)
            }
        }
        .task { refresh() }
        .onChange(of: store.prefetching) { _, running in
            if !running { refresh() }
        }
        .onChange(of: store.prefetchDone) { _, _ in
            // 存的过程中不用每张都数一遍文件，隔一阵更新一次
            if store.prefetchDone % 20 == 0 { refresh() }
        }
        Stepper(value: $limitGB, in: 1...50) {
            Text("缓存上限 \(limitGB) GB")
        }
        .onChange(of: limitGB) { _, _ in
            guard !session.offline, !session.walls.isEmpty else { return }
            store.prefetchAll(session)
            refresh()
        }
        HStack {
            status
            Spacer()
            Button(store.prefetching ? "暂停" : "补齐缓存") {
                if store.prefetching {
                    store.pausePrefetch()
                } else {
                    store.prefetchAll(session)
                }
                refresh()
            }
            .disabled(session.offline || session.walls.isEmpty)
        }
    }

    @ViewBuilder
    private var status: some View {
        if store.prefetching {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在缓存 \(store.prefetchDone) / \(store.prefetchTotal)")
            }
            .foregroundStyle(.secondary)
        } else if store.prefetchHitLimit {
            Text("已到上限，\(max(0, store.prefetchTotal - store.prefetchDone)) 张没缓存")
                .foregroundStyle(.secondary)
        } else if store.prefetchPaused {
            Text("已暂停").foregroundStyle(.secondary)
        } else {
            Text("已缓存 \(cached) / \(session.walls.count) 张").foregroundStyle(.secondary)
        }
    }

    private func refresh() {
        let rev = session.wallsRev ?? ""
        let names = session.walls.map(\.name)
        Task {
            let (n, c) = await Task.detached(priority: .utility) {
                // 整个目录减去原图，就是缩略图 / 横幅 / 2732 大图占的（原图在下面单独一行）
                let originals = rev.isEmpty ? 0 : ImageStore.cachedSize(rev: rev, kind: .original)
                return (max(0, ImageStore.diskUsage() - originals),
                        rev.isEmpty ? 0 : ImageStore.viewableCount(rev: rev, names: names))
            }.value
            size = n
            cached = c
        }
    }
}

/// 「保存原图」：把这一批的原文件（图库里那一份）也存到手机上，离线时能看原图、直接存相册或分享。
/// 只在打开开关 / 点「补齐原图」时下载，可以暂停；和上面的预览图缓存共用一个上限。
private struct OriginalCacheRow: View {
    let session: RemoteSession
    @State private var size: Int64?
    @State private var cached = 0
    @AppStorage(ImageStore.cacheOriginalsKey) private var enabled = false

    private var store: ImageStore { .shared }

    var body: some View {
        Toggle("保存原图", isOn: $enabled)
            .onChange(of: enabled) { _, on in
                guard on else {
                    store.pauseOriginals() // 关掉就不再往下补，已经存下的不动
                    return
                }
                guard !session.offline, !session.walls.isEmpty else { return }
                store.prefetchOriginals(session)
                refresh()
            }
        if enabled {
            HStack {
                status
                Spacer()
                Button(store.originaling ? "暂停" : "补齐原图") {
                    if store.originaling {
                        store.pauseOriginals()
                    } else {
                        store.prefetchOriginals(session)
                    }
                    refresh()
                }
                .disabled(session.offline || session.walls.isEmpty)
            }
        }
        LabeledContent("已存原图") {
            HStack(spacing: 12) {
                Text(detail).foregroundStyle(.secondary)
                Button("清除", role: .destructive) {
                    store.clearOriginals(rev: session.wallsRev)
                    size = 0
                    cached = 0
                }
                .disabled(cached == 0)
            }
        }
        .task { refresh() }
        .onChange(of: store.originaling) { _, running in if !running { refresh() } }
        .onChange(of: store.originalDone) { _, _ in
            if store.originalDone % 5 == 0 { refresh() }
        }
    }

    @ViewBuilder
    private var status: some View {
        if enabled {
            if store.originaling {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在存 \(store.originalDone) / \(store.originalTotal)")
                }
                .foregroundStyle(.secondary)
            } else if store.originalHitLimit {
                Text("已到上限，剩下的没存").foregroundStyle(.secondary)
            } else if store.originalPaused {
                Text("已暂停").foregroundStyle(.secondary)
            } else if cached > 0, cached >= session.walls.count {
                Text("全部存好了").foregroundStyle(.secondary)
            } else {
                Text("还没补齐").foregroundStyle(.secondary)
            }
        }
    }

    private var detail: String {
        let n = "\(cached) / \(session.walls.count) 张"
        guard let size, size > 0 else { return n }
        return n + " · " + ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    private func refresh() {
        let rev = session.wallsRev ?? ""
        Task {
            let (n, c) = await Task.detached(priority: .utility) {
                (rev.isEmpty ? 0 : ImageStore.cachedSize(rev: rev, kind: .original),
                 rev.isEmpty ? 0 : ImageStore.cachedCount(rev: rev, kind: .original))
            }.value
            size = n
            cached = c
        }
    }
}
