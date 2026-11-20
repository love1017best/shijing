import SwiftUI

/// 离线缓存：这一批壁纸（网格、大图，开了「保存原图」再加上图库里的原文件）存到手机上。
/// 一个队列、一个上限：超过「缓存上限」就不再往后存。这些都是手机本地的设置，不用连电脑也能改。
struct OfflineCacheSection: View {
    let session: RemoteSession
    @State private var usage: ImageStore.Usage?
    @State private var refreshTask: Task<Void, Never>?
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
        // 横幅图也按整批存（轮播用）；旧版桌面端没有横幅档，只看大图和原图
        if session.heroName != nil, (usage?.data(.hero).inBatch ?? 0) < total { return true }
        return keepOriginals && (usage?.data(.original).inBatch ?? 0) < total
    }

    var body: some View {
        Section {
            Group {
                // 四档缓存各一行：这一批里存了多少张 / 这一批共多少张 · 占多少
                cacheRow(.thumb, "缩略图缓存", "网格里每一格用的小图，宽 360 像素。")
                cacheRow(.hero, "横幅缓存", "概览顶部轮播的横幅图，宽 1600 像素；这一批每张存一份。")
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
                        Text("已用 \(bytes(usage?.totalUsed)) / \(limitGB) GB")
                        Spacer()
                        Button("清除") {
                            store.clear(macID: session.macID.uuidString)
                            refresh()
                        }
                        .disabled((usage?.used ?? 0) == 0)
                    }
                    ProgressView(value: fraction)
                    if let u = usage, u.totalUsed > u.used {
                        Text("其中这台 Mac 占 \(bytes(u.used))，其余为其他 Mac 缓存")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .task(id: session.macID) { refresh() }
            .onChange(of: session.wallsRev) { _, _ in refresh() }
            .onChange(of: store.prefetching) { _, running in if !running { refresh() } }
            .onChange(of: store.prefetchDone) { _, _ in
                // 存的过程中不用每张都数一遍文件，隔一阵更新一次
                if store.prefetchDone % 20 == 0 { refresh() }
            }
            .onChange(of: store.prefetchOriginalDone) { _, _ in
                if store.prefetchOriginalDone % 20 == 0 { refresh() }
            }
            .onDisappear {
                refreshTask?.cancel()
                refreshTask = nil
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
        guard limitGB > 0, let used = usage?.totalUsed, used > 0 else { return 0 }
        return min(1, Double(used) / Double(limitGB * 1_000_000_000))
    }

    private func bytes(_ n: Int64?) -> String {
        guard let n else { return "…" }
        return n == 0 ? "没有" : ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    private func refresh() {
        refreshTask?.cancel()
        let macID = session.macID.uuidString
        let names = session.walls.map(\.name)
        refreshTask = Task {
            // 刚点过「清除」时等文件删完再数，不然显示的还是清之前的大小
            await store.waitForClear()
            guard !Task.isCancelled else { return }
            // 一次量完：列一遍目录就有各档的张数和大小，不用一档列一遍
            let result = await Task.detached(priority: .utility) {
                ImageStore.usage(macID: macID, names: names)
            }.value
            guard !Task.isCancelled else { return }
            usage = result
        }
    }
}
