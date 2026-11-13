import SwiftUI

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

/// 「设置」页：电脑上常调的几项在手机上直接改（改完电脑上的设置页同步变，和在电脑上改一样自动保存）。
/// 分组和电脑上的设置页一致：采样、筛选、自动换壁纸、系统，最后是关于。旧版桌面端不推 settings，就只读显示。
struct SettingsPage: View {
    let session: RemoteSession
    /// 每次张数的草稿：步进器连点时先改这里，停手 0.8 秒再发给电脑
    @State private var draftCount: Int?
    @State private var countTask: Task<Void, Never>?
    /// 自定义分辨率的草稿：同上，攒一会儿再发
    @State private var draftW: Int?
    @State private var draftH: Int?
    @State private var resTask: Task<Void, Never>?
    /// 待补操作里正在确认的「删除原图」
    @State private var confirmDelete: RemoteSession.OfflineAction?
    @State private var confirmAllDeletes = false

    var body: some View {
        MacPage(session: session, title: "设置") { state in
            #if DEBUG
            // 截图用：-demoOfflineCache 只摆离线这一组（设置页太长，模拟器里不好滚到最下面）；
            // -demoQueue 只摆「待补操作」这一组（含待确认的删除原图）；
            // -demoLibrary 只摆「图库 / 待删除」两组（配 -demoPending 看电脑上排队的删除）
            if ProcessInfo.processInfo.arguments.contains("-demoQueue") {
                if !session.queued.isEmpty { offlineQueueSection }
                aboutSection(state)
            } else if ProcessInfo.processInfo.arguments.contains("-demoLibrary") {
                if state.dirs != nil { libraryLink(state) }
                pendingQueueSection
                aboutSection(state)
            } else if ProcessInfo.processInfo.arguments.contains("-demoOfflineCache") {
                offlineSection
                if !session.queued.isEmpty { offlineQueueSection }
                aboutSection(state)
            } else {
                settingsContent(state)
            }
            #else
            settingsContent(state)
            #endif
        }
        .toolbar {
            if session.savingSettings {
                ToolbarItem(placement: .automatic) { ProgressView() } // 正在把改动发给电脑
            }
        }
        .confirmationDialog(
            "删除这张原图？",
            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
            titleVisibility: .visible,
            presenting: confirmDelete
        ) { a in
            Button("删除原图", role: .destructive) { Task { await session.confirmQueuedDelete(a) } }
            Button("取消", role: .cancel) {}
        } message: { a in
            Text("会从图库里删除 \(a.source ?? a.name)，不可撤销，会记进电脑上的删除记录。")
        }
        .confirmationDialog(
            "确认删除 \(session.queuedDeletes.count) 张原图？",
            isPresented: $confirmAllDeletes,
            titleVisibility: .visible
        ) {
            Button("全部删除", role: .destructive) { Task { await session.confirmAllQueuedDeletes() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("逐张从图库里删除，不可撤销。已经不在这一批壁纸里的会跳过。")
        }
    }

    @ViewBuilder
    private func settingsContent(_ state: RemoteState) -> some View {
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
        offlineSection
        if !session.queued.isEmpty { offlineQueueSection }
        aboutSection(state)
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
            Text("复制占用磁盘空间但可以脱离图库使用；软链接省空间，但图库没挂载时壁纸会失效。")
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
            Text("打开后，换一批时会删除图库里竖屏、分辨率不够的原图，不能撤销。从手机换一批时会先确认，也可以选这次只模拟。\n增量筛选会跳过上次检查后没有变化的文件夹。")
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
        if state.dirs != nil {
            libraryLink(state)
        }
        pendingQueueSection
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
            Text("只有横屏（宽高比大于 1.1）且不低于这个分辨率的图片才会被选中。")
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
            Text("把每次选中的图片在图库旁边留一份链接（优先硬链接，不支持时用软链接），每次运行前清空上一批。位置、文件夹名、跨挂载点换算在电脑上改。")
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
            Text("筛选 + 采样会先删掉不合格的原图；仅采样不动文件。添加、移除目录在电脑上的「图库」页，手机上只读。")
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
                Text("图库（NAS）没连上时删的原图先排在电脑上，图库连上后自动删除。取消只是不删这张原图，壁纸文件夹里那张当时已经移出了。")
            }
        }
    }

    /// 离线时记下的整理：逐条看得到、可以取消。「移出」「不再选」连上电脑后自动补上；
    /// 「删除原图」不可撤销，连上后还要在这里逐张（或全部）确认才会删。
    private var offlineQueueSection: some View {
        let deletes = session.queuedDeletes.count
        return Section {
            ForEach(session.queued) { a in
                HStack(spacing: 12) {
                    Image(systemName: queueIcon(a.kind))
                        .foregroundStyle(a.kind == .delete ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(queueLabel(a.kind)).font(.subheadline)
                            .foregroundStyle(a.kind == .delete ? AnyShapeStyle(Color.red) : AnyShapeStyle(.primary))
                        Text(a.name).font(.footnote).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        Text(a.at, format: .dateTime.month().day().hour().minute())
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if a.kind == .delete {
                        if session.connection == .live {
                            Button("确认删除", role: .destructive) { confirmDelete = a }
                                .buttonStyle(.borderless)
                                .disabled(session.state?.running == true)
                        } else {
                            Text("连上后确认").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    Button("取消") { session.cancelQueued(a) }
                        .buttonStyle(.borderless)
                }
            }
            if deletes > 0, session.connection == .live {
                Button("全部确认删除（\(deletes) 张）", role: .destructive) { confirmAllDeletes = true }
                    .disabled(session.state?.running == true)
            }
            if session.queued.count > 1 {
                Button("全部取消", role: .destructive) { session.cancelAllQueued() }
            }
        } header: {
            Text("待补操作（\(session.queued.count)）")
        } footer: {
            Text("离线时记下的整理：「移出」「不再选」连上电脑后自动补上；「删除原图」不可撤销，连上后还要在这里逐张（或全部）确认才会删除。取消会把那张放回列表原来的位置。")
        }
    }

    private func queueLabel(_ kind: RemoteSession.OfflineAction.Kind) -> String {
        switch kind {
        case .remove: "移出"
        case .exclude: "不再选它"
        case .delete: "删除原图（待确认）"
        }
    }

    private func queueIcon(_ kind: RemoteSession.OfflineAction.Kind) -> String {
        switch kind {
        case .remove: "minus.circle"
        case .exclude: "nosign"
        case .delete: "trash"
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
            Text("连不上电脑时，概览和壁纸显示的是上次同步的内容：缩略图、横幅和整批 2732 宽的预览图会自动缓存在手机上，受上面的上限限制，换一批后上一批的自动删掉。打开「保存原图」还会把这一批的原文件也存下来（一张几十 MB，同样受上限限制），离线时能看原图、直接存相册或分享；关掉只是不再补齐，已经存下的可以点「清除」删掉。")
        }
    }

    /// 关于：两边的版本，版本不一样时提醒一下。
    private func aboutSection(_ state: RemoteState) -> some View {
        Section {
            LabeledContent("电脑上的拾景", value: state.version.isEmpty ? "开发版" : "v" + state.version)
            LabeledContent("这台手机上", value: AppVersion.text)
            if let exp = SigningExpiry.text {
                LabeledContent("签名", value: exp)
            }
            LabeledContent("壁纸文件夹", value: state.dest)
        } header: {
            Text("关于")
        } footer: {
            if !state.version.isEmpty, state.version != AppVersion.short {
                Text("两边版本不一样，有的功能可能用不了，建议都升到最新。")
            }
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
                                    Text("挂载状态和张数可能已经变了；连上电脑后才能重新检查。")
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
                        Text("挂载状态由电脑检查。点「重新检查挂载」会让电脑重新探一遍这些目录，结果再推回来。添加、移除目录在电脑上的「图库」页。")
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
