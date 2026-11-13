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

    var body: some View {
        MacPage(session: session, title: "设置") { state in
            #if DEBUG
            // 截图用：-demoOfflineCache 只摆离线这一组（设置页太长，模拟器里不好滚到最下面）
            if ProcessInfo.processInfo.arguments.contains("-demoOfflineCache") {
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
    }

    @ViewBuilder
    private func settingsContent(_ state: RemoteState) -> some View {
        if session.connection != .live {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("现在连不上电脑，设置只能查看").font(.subheadline.bold())
                        Text("改设置、换一批都要等连上电脑。离线时记下的「移出」「不再选」连上后会自动补上。")
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
            Stepper(value: Binding(
                get: { draftCount ?? set.sampleCount },
                set: { setCount($0) }
            ), in: 1...9999, step: (draftCount ?? set.sampleCount) < 50 ? 5 : 10) {
                LabeledContent("每次张数", value: "\(draftCount ?? set.sampleCount) 张")
            }
            .disabled(disabled)
            toggle("优先选没换上过的", set.preferUnseen, key: "prefer_unseen", disabled: disabled)
        } header: {
            Text("采样")
        } footer: {
            Text("优先选没换上过的：这一轮里还没换上过的图片先选，都换上过一遍再从头开始。")
        }
        Section {
            toggle("删除不合格的原图", set.deleteDuringFilter, key: "delete_during_filter", tint: .red, disabled: disabled)
        } header: {
            Text("筛选")
        } footer: {
            Text("打开后，换一批时会删除图库里竖屏、分辨率不够的原图，不能撤销。从手机换一批时会先确认，也可以选这次只模拟。")
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
            Text("换完一批后重启 macOS 的壁纸服务，不然系统会继续轮换已经删掉的旧图。\n输出方式、画质要求、图库目录、归档等其他设置在电脑上改。")
        }
    }

    /// 离线时记下的整理：逐条看得到、可以取消，连上电脑后自动补上。
    private var offlineQueueSection: some View {
        Section {
            ForEach(session.queued) { a in
                HStack(spacing: 12) {
                    Image(systemName: a.kind == .remove ? "minus.circle" : "nosign")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.kind == .remove ? "移出" : "不再选它").font(.subheadline)
                        Text(a.name).font(.footnote).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        Text(a.at, format: .dateTime.month().day().hour().minute())
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button("取消") { session.cancelQueued(a) }
                        .buttonStyle(.borderless)
                }
            }
            if session.queued.count > 1 {
                Button("全部取消", role: .destructive) { session.cancelAllQueued() }
            }
        } header: {
            Text("待补操作（\(session.queued.count)）")
        } footer: {
            Text("离线时记下的整理，连上电脑后自动补上。「移出」取消后会把那张放回列表原来的位置。")
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
        Task {
            let (n, c) = await Task.detached(priority: .utility) {
                // 整个目录减去原图，就是缩略图 / 横幅 / 2732 大图占的（原图在下面单独一行）
                let originals = rev.isEmpty ? 0 : ImageStore.cachedSize(rev: rev, kind: .original)
                return (max(0, ImageStore.diskUsage() - originals),
                        rev.isEmpty ? 0 : ImageStore.cachedCount(rev: rev, kind: .image))
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
