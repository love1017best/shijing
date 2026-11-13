import Foundation
import Observation
import Photos
import Network
#if canImport(UIKit)
import UIKit
#endif

/// 和一台 Mac 的连接：保持事件流、断了自动重连，提供「换一批」「停止」。
@Observable @MainActor
final class RemoteSession {
    enum Connection: Equatable {
        case connecting
        case live
        /// 连不上（Mac 睡眠、拾景没开、遥控被关掉、不在同一个网络…）
        case offline(String)
        /// 令牌失效：在电脑上取消了配对
        case unpaired(String)
    }

    let macID: SavedMac.ID
    internal(set) var mac: SavedMac
    internal(set) var connection: Connection = .connecting
    internal(set) var state: RemoteState?
    /// 正在等「换一批」「停止」的响应
    internal(set) var busy = false
    /// 上一次操作失败的原因（界面上弹提示）
    var actionError: String?
    /// 壁纸文件夹里的图（和桌面同样的顺序）；walls_rev 变了就重新拉
    internal(set) var walls: [Wallpaper] = []
    internal(set) var wallsRev: String?
    /// 横幅图的文件名（桌面概览顶部那张）；旧版桌面端没给时用第一张
    internal(set) var heroName: String?
    var hero: Wallpaper? { walls.first { $0.name == heroName } ?? walls.first }
    /// 正在移出 / 删除的那张
    internal(set) var acting: String?
    /// 现在显示的状态是从磁盘快照来的（还没连上过）：界面上标「离线 · X 前同步」
    internal(set) var snapshotAt: Date?

    private let store: MacStore
    private var task: Task<Void, Never>?
    /// 用户切到后台时 pause，回前台再 start：这期间网络变了也别自己重连
    private var paused = false
    /// 手机自己的网络断了（飞行模式、关了 Wi‑Fi）：不用等事件流报错，立刻显示离线
    private let pathMonitor = NWPathMonitor()
    private var networkDown = false
    /// 上次把快照写到磁盘的时间（运行中状态更新很密，最多 5 秒写一次）
    private var lastSnapshotSave = Date.distantPast
    /// 已经清理过磁盘缓存的批次（同一批只清一次，见 refreshWalls）
    private var groomedRev: String?
    /// 离线时点的「移出 / 不再选」，连上电脑后自动补上（存在 UserDefaults 里，按 Mac 分开）
    internal(set) var queued: [OfflineAction] = []
    var flushing = false

    init(mac: SavedMac, store: MacStore) {
        self.mac = mac
        macID = mac.id
        self.store = store
        // 上次连上时留下的快照：还没连上之前先用它，离线也能看上回那批壁纸
        if let snap = OfflineStore.shared.load(macID.uuidString) {
            state = snap.state
            walls = snap.walls
            wallsRev = snap.wallsRev ?? snap.state.wallsRev
            heroName = snap.hero
            snapshotAt = snap.at
        }
        queued = Self.loadQueue(macID.uuidString)
        #if DEBUG
        if Self.demoMode != nil { return }
        #endif
        // 系统网络状态变了立刻反映到连接状态：飞行模式、关掉 Wi‑Fi 时事件流可能要等很久才报错
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let ok = path.status == .satisfied
            Task { @MainActor [weak self] in self?.networkChanged(ok) }
        }
        pathMonitor.start(queue: .global(qos: .utility))
    }

    deinit {
        pathMonitor.cancel()
    }

    /// 手机的网络状态变了：断了就立刻显示离线并停掉卡住的事件流；恢复后重新连。
    private func networkChanged(_ ok: Bool) {
        if ok {
            guard networkDown else { return }
            networkDown = false
            if paused { return } // 后台时不主动连，回前台再 start
            guard !isUnpaired else { return }
            connection = .connecting
            start()
            return
        }
        networkDown = true
        guard !isUnpaired else { return }
        connection = .offline("手机没有连上网络。")
        task?.cancel()
        task = nil
    }

    private var isUnpaired: Bool {
        if case .unpaired = connection { return true }
        return false
    }

    func client() throws -> APIClient {
        try APIClient(address: mac.address, token: store.token(for: macID))
    }

    /// 开始（或重新开始）保持连接。App 回到前台时调用。
    func start() {
        paused = false
        task?.cancel()
        task = Task { await loop() }
    }

    /// App 进入后台时断开，回前台再连。
    func pause() {
        paused = true
        task?.cancel()
        task = nil
    }

    #if os(iOS)
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    #endif

    /// 进了后台：正在换壁纸的话向系统多要一会儿后台时间，继续连着，换完能发通知；没在换就直接断开。
    func enterBackground() {
        #if os(iOS)
        guard state?.running == true, bgTask == .invalid else {
            if bgTask == .invalid { pause() }
            return
        }
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "等这次换完") { [weak self] in
            MainActor.assumeIsolated { self?.endBackground(disconnect: true) }
        }
        #else
        pause()
        #endif
    }

    /// 回到前台（或者后台时间用完）。
    func endBackground(disconnect: Bool) {
        #if os(iOS)
        if disconnect { pause() }
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
        #endif
    }

    private func loop() async {
        var delay: Double = 1
        var failures = 0
        while !Task.isCancelled {
            if state == nil { connection = .connecting }
            do {
                var firstEvent = true
                for try await s in try client().events() {
                    let wasLive = connection == .live
                    if firstEvent {
                        firstEvent = false
                        // 事件流（重新）连上了：回前台之前可能有一次没补完的离线操作，先补上
                        // （只认第一帧：电脑在换壁纸时补不成的留着，等换完一批那一路再触发）
                        if !queued.isEmpty { Task { await flushOfflineActions() } }
                    }
                    RunNotifier.observe(new: s, mac: mac.name)
                    if state?.running == true, !s.running {
                        WidgetReload.all()
                        // 换完一批：日志、删除记录都变了，更新手机上存的记录
                        Task { await refreshRecordsCache() }
                        // 电脑忙的时候没补成的离线操作，这时候再补一次
                        if !queued.isEmpty { Task { await flushOfflineActions() } }
                    }
                    state = s
                    snapshotAt = nil
                    remember()
                    #if os(iOS)
                    // 在后台等的这次换完了：通知已经发了，断开
                    if !s.running, bgTask != .invalid { endBackground(disconnect: true); return }
                    #endif
                    connection = .live
                    if !wasLive {
                        if !queued.isEmpty { Task { await flushOfflineActions() } }
                        // 又连上了：上一次没缓存完的接着补（已经存下的会跳过）；换了一批时 refreshWalls 会另起一轮
                        ImageStore.shared.prefetchAll(self)
                        if ImageStore.originalsEnabled { ImageStore.shared.prefetchOriginals(self) }
                        // 记录页的三份数据也存一份，下次断了还能看
                        Task { await refreshRecordsCache() }
                    }
                    if s.wallsRev != wallsRev { Task { await refreshWalls() } }
                    delay = 1
                    failures = 0
                }
                // 服务端正常关闭（遥控被关掉、应用退出）：当作断开，稍后重连
                throw URLError(.networkConnectionLost)
            } catch APIError.unauthorized(let msg) {
                connection = .unpaired(msg)
                return
            } catch {
                if Task.isCancelled { return }
                failures += 1
                connection = .offline(Self.describe(error))
                // 连不上时试试按 Bonjour 服务名重新找：Mac 的 IP 可能变了
                if failures % 2 == 1, let name = mac.serviceName,
                   let addr = try? await Discovery.resolve(serviceName: name), addr != mac.address {
                    mac.host = addr.host
                    mac.port = addr.port
                    store.update(macID, address: addr)
                    continue
                }
            }
            try? await Task.sleep(for: .seconds(delay))
            delay = min(delay * 2, 15)
        }
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? URLError {
            switch e.code {
            case .timedOut, .cannotConnectToHost, .networkConnectionLost, .cannotFindHost:
                return "连不上这台 Mac：确认它没有睡眠、拾景开着并打开了「允许手机遥控」，手机和电脑在同一个网络里。"
            case .notConnectedToInternet:
                return "手机没有连上网络。"
            default:
                break
            }
        }
        return error.localizedDescription
    }

    func run(deleteOriginals: Bool) async {
        Notifications.requestOnce()
        await act { try await $0.run(deleteOriginals: deleteOriginals) }
        WidgetReload.all()
    }

    func stop() async {
        await act { try await $0.stop() }
    }

    // MARK: 设置、撤销（第 3 期）

    /// 正在保存的设置项（界面上对应那一行转圈）
    internal(set) var savingSettings = false

    /// 改常用设置：只传要改的字段。失败时弹提示，界面回到电脑上的值。
    func updateSettings(_ changes: [String: Any]) async {
        #if DEBUG
        if Self.demoMode != nil, var set = state?.settings { // 演示模式：只改本地
            if let n = changes["sample_count"] as? Int { set.sampleCount = n; state?.sampleCount = n }
            if let h = changes["auto_run_hours"] as? Int { set.autoRunHours = h }
            if let v = changes["delete_during_filter"] as? Bool { set.deleteDuringFilter = v }
            if let v = changes["prefer_unseen"] as? Bool { set.preferUnseen = v }
            if let v = changes["refresh_wallpaper"] as? Bool { set.refreshWallpaper = v }
            state?.settings = set
            return
        }
        #endif
        savingSettings = true
        defer { savingSettings = false }
        do {
            state = try await client().updateSettings(changes)
            remember()
        } catch APIError.unauthorized(let msg) {
            connection = .unpaired(msg)
        } catch {
            actionError = Self.describe(error)
        }
    }

    /// 撤销最近一次移出：放回壁纸文件夹原来的位置。成功时返回放回去的那张的文件名。
    @discardableResult
    func undoRemove() async -> String? {
        // 离线时撤销的是手机上还没补上的「移出」：直接从队列里拿掉、放回列表，不用连电脑
        if offline {
            guard let last = queued.last(where: { $0.kind == .remove }) else { return nil }
            cancelQueued(last, announce: false)
            notice = "已撤销移出：\(last.name)"
            return last.name
        }
        guard let name = state?.undoName else { return nil }
        acting = name
        defer { acting = nil }
        do {
            state = try await client().undo()
            remember(wallsChanged: true)
            await refreshWalls()
            return name
        } catch APIError.unauthorized(let msg) {
            connection = .unpaired(msg)
        } catch {
            actionError = Self.describe(error)
        }
        return nil
    }

    // MARK: 存原图到相册

    /// 正在下载 / 存到相册的那张
    internal(set) var saving: String?
    /// 要打开大图的那张（从小组件点进来），概览页看到就打开
    var openRequest: String?
    /// 一闪而过的提示（「已存到相册」），界面上显示两秒
    var notice: String?

    /// 从电脑下载原文件，原样存进相册（不重新编码，保留原分辨率和 EXIF）。
    /// 离线时用手机上存着的那份原图（设置 › 离线 › 保存原图），没存过就只能等连上电脑。
    func saveOriginal(_ w: Wallpaper) async {
        let live = connection == .live
        let cached = ImageStore.cachedOriginal(rev: wallsRev ?? "", name: w.name)
        guard live || cached != nil else {
            actionError = "连不上电脑，这张原图也没存到手机上。到「设置 › 离线」打开「保存原图」并补齐，或者等连上电脑再存。"
            return
        }
        saving = w.name
        defer { saving = nil }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            actionError = "没有存照片的权限：到「设置 › 隐私与安全性 › 照片 › 拾景」里允许「仅添加照片」。"
            return
        }
        do {
            // 在线时下载到临时目录、用完删掉；离线用的是缓存里的，不能删
            var temp: URL?
            let file: URL
            if live {
                file = try await client().downloadOriginal(w.name)
                temp = file
            } else {
                file = cached!
            }
            defer { if let temp { try? FileManager.default.removeItem(at: temp) } }
            try await PHPhotoLibrary.shared().performChanges {
                let opts = PHAssetResourceCreationOptions()
                opts.originalFilename = w.name
                PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: file, options: opts)
            }
            showNotice("已存到相册")
        } catch APIError.unauthorized(let msg) {
            connection = .unpaired(msg)
        } catch let e as APIError {
            actionError = e.localizedDescription
        } catch let e as URLError {
            actionError = Self.describe(e)
        } catch {
            actionError = "存不进相册：\(error.localizedDescription)"
        }
    }

    func showNotice(_ text: String) {
        notice = text
        Task {
            try? await Task.sleep(for: .seconds(2))
            if notice == text { notice = nil }
        }
    }

    // MARK: 壁纸

    /// 重新拉壁纸列表（状态里的 walls_rev 变了时自动调；force 时不管变没变都拉，
    /// 补离线操作之前要看电脑上现在有哪些）。
    func refreshWalls(force: Bool = false) async {
        guard let rev = state?.wallsRev else { return }
        if !force, rev == wallsRev { return }
        do {
            let list = try await client().wallpapers()
            let changed = list.rev != wallsRev
            walls = list.items
            wallsRev = list.rev
            heroName = list.hero
            remember(wallsChanged: true)
            if changed {
                // 换了一批：旧那批的缓存任务先停掉（下载中的不会再写回旧目录），
                // 上一批留在手机上的图（预览图和原图）由下面的 groom 整个删掉，要的话再按新批次补
                ImageStore.shared.stopForNewBatch()
            }
            // 不属于这一批的缓存目录删掉；同一批里换过前缀的旧文件（比如以前 2048 宽的大图）也一起清。
            // 每次连上都跑一遍（按批次记着，同一批只跑一次），升级后不用等下一次换批
            if groomedRev != list.rev {
                groomedRev = list.rev
                let rev = list.rev
                let names = list.items.map(\.name)
                // 删 / 搬文件，别在主线程做
                Task.detached(priority: .utility) { ImageStore.groom(keepRev: rev, names: names) }
            }
            if changed {
                ImageStore.shared.prefetchAll(self) // 这一批的缩略图和预览图存到磁盘，离线也能看
                if ImageStore.originalsEnabled { ImageStore.shared.prefetchOriginals(self) } // 开了「保存原图」的接着存原图
            }
        } catch {
            // 列表拉不到不影响别的，下次状态推送再试
        }
    }

    /// 连上电脑时把记录页的三份数据（运行日志、删除记录、不再选）各存一份到手机，
    /// 断线时记录页显示的就是这一份，标出是什么时候同步的。
    func refreshRecordsCache() async {
        guard let client = try? client() else { return }
        let id = macID.uuidString
        async let log: [String]? = try? client.log()
        async let deletions: DeletionList? = try? client.deletions()
        async let excluded: [ExcludedItem]? = try? client.excluded()
        if let v = await log { OfflineStore.shared.saveRecord(id, .log, v) }
        if let v = await deletions { OfflineStore.shared.saveRecord(id, .deletions, v) }
        if let v = await excluded { OfflineStore.shared.saveRecord(id, .excluded, v) }
    }

    /// 把当前状态和壁纸列表写到磁盘（离线时显示的上次样子）。运行中状态推得很密，最多 5 秒写一次；
    /// 壁纸列表变了（wallsChanged）时立刻写。
    func remember(wallsChanged: Bool = false) {
        #if DEBUG
        if Self.demoMode != nil { return }
        #endif
        guard let state else { return }
        let now = Date()
        if !wallsChanged, now.timeIntervalSince(lastSnapshotSave) < 5 { return }
        lastSnapshotSave = now
        OfflineStore.shared.save(macID.uuidString, .init(state: state, walls: walls, hero: heroName, wallsRev: wallsRev, at: now))
    }

    /// 移出壁纸文件夹；exclude 时以后的采样也跳过这张原图。成功返回 true。
    /// refresh 为 false 时先不在本地重新拉列表（多选批量整理时最后只拉一次）。
    @discardableResult
    func removeWallpaper(_ w: Wallpaper, exclude: Bool, refresh: Bool = true) async -> Bool {
        await wallAct(w, kind: exclude ? .exclude : .remove, refresh: refresh) { try await $0.removeWallpaper(w.name, exclude: exclude) }
    }

    /// 一次整理多张（「全部壁纸」页多选）：逐张调接口，失败就停（错误已经弹出来了），最后只重新拉一次列表。
    /// 成功返回处理了几张。
    @discardableResult
    func removeWallpapers(_ items: [Wallpaper], exclude: Bool) async -> Int {
        guard !items.isEmpty else { return 0 }
        var done = 0
        for w in items {
            if Task.isCancelled { break }
            guard await removeWallpaper(w, exclude: exclude, refresh: false) else { break }
            done += 1
        }
        // 离线时记的都是队列里的操作，不用（也拉不到）列表
        if !offline { await refreshWalls() }
        if done > 0 { Task { await refreshRecordsCache() } }
        return done
    }

    /// 删除图库里的原图（界面上已经二次确认过）。离线时不能排队（不可撤销，等连上再做），
    /// 手机误触一下、电脑半夜连上网就把 NAS 上的原图删了，后果太重。
    @discardableResult
    func deleteOriginal(_ w: Wallpaper) async -> Bool {
        guard connection == .live else {
            actionError = "连不上电脑时不能删除原图（不可撤销）。可以先移出或者「不再选它」，连上电脑后自动补上。"
            return false
        }
        let before = state?.pending ?? 0
        let ok = await wallAct(w, kind: .remove) { try await $0.deleteOriginal(w.name) }
        // 图库没连上：电脑把这次删除排队了，别让手机上看起来像已经删掉
        if ok, (state?.pending ?? 0) > before {
            showNotice("图库没连上，这次删除已排队")
        }
        return ok
    }

    private func wallAct(_ w: Wallpaper, kind: OfflineAction.Kind, refresh: Bool = true, _ op: (APIClient) async throws -> RemoteState) async -> Bool {
        acting = w.name
        defer { acting = nil }
        #if DEBUG
        if Self.demoMode != nil { // 演示模式：只在本地去掉
            walls.removeAll { $0.name == w.name }
            return true
        }
        #endif
        if connection != .live {
            enqueue(kind, w)
            return true
        }
        do {
            state = try await op(client())
            // 先在本地去掉，不用等重新拉列表
            walls.removeAll { $0.name == w.name }
            remember(wallsChanged: true)
            if refresh { await refreshWalls() }
            // 删除记录 / 不再选名单变了：顺手更新手机上存的那份，断了也能看
            Task { await refreshRecordsCache() }
            return true
        } catch APIError.unauthorized(let msg) {
            connection = .unpaired(msg)
        } catch {
            actionError = Self.describe(error)
        }
        return false
    }

    private func act(_ op: (APIClient) async throws -> RemoteState) async {
        busy = true
        defer { busy = false }
        do {
            state = try await op(client())
            remember(wallsChanged: true)
        } catch APIError.unauthorized(let msg) {
            connection = .unpaired(msg)
        } catch {
            actionError = Self.describe(error)
        }
    }
}
