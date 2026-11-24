import Foundation
import Observation
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
    var mac: SavedMac
    var connection: Connection = .connecting
    var state: RemoteState?
    /// 正在等「换一批」「停止」的响应
    var busy = false
    /// 上一次操作失败的原因（界面上弹提示）
    var actionError: String?
    /// 壁纸文件夹里的图（和桌面同样的顺序）；walls_rev 变了就重新拉
    var walls: [Wallpaper] = []
    var wallsRev: String?
    /// 横幅图的文件名（桌面概览顶部那张）；旧版桌面端没给时用第一张
    var heroName: String?
    var hero: Wallpaper? { walls.first { $0.name == heroName } ?? walls.first }
    /// 正在移出 / 删除的那张
    var acting: String?
    /// 现在显示的状态是从磁盘快照来的（还没连上过）：界面上标「离线 · X 前同步」
    var snapshotAt: Date?

    private let store: MacStore
    private var task: Task<Void, Never>?
    /// 用户切到后台时 pause，回前台再 start：这期间网络变了也别自己重连
    var paused = false
    /// 手机自己的网络断了（飞行模式、关了 Wi‑Fi）：不用等事件流报错，立刻显示离线
    private let pathMonitor = NWPathMonitor()
    private var networkDown = false
    /// 手机现在只有蜂窝网络（没有 Wi‑Fi、有线）
    var cellularOnly = false
    /// 是否已经收到过一次 pathMonitor 回调（冷启动时等首帧，避免抢先发起蜂窝连接）
    private var pathReady = false
    /// start() 调用时 pathMonitor 首帧尚未到达，首帧到位后再按真实网络状态决定是否连接
    private var pendingStart = false
    /// 等待 pathMonitor 首帧的短超时兜底任务
    private var pathWaitTask: Task<Void, Never>?
    /// 离线模式变更通知观察者（deinit 时移除）
    @ObservationIgnored nonisolated(unsafe) private var offlineObserver: NSObjectProtocol?
    /// 因离线模式断开的（不是连不上）：退出离线模式时要重新连
    private var held = false
    /// 上次把快照写到磁盘的时间（运行中状态更新很密，最多 5 秒写一次）
    var lastSnapshotSave = Date.distantPast
    /// 正在进行的拉壁纸列表任务（合并并发调用，避免旧响应晚到覆写新列表）
    var refreshWallsTask: Task<Bool, Never>?
    var refreshWallsGen = 0
    /// 顶部提示气泡的自动隐藏延时任务（新提示到来时取消旧任务，防止被提前清掉）
    var noticeTask: Task<Void, Never>?
    /// 删除记录条件请求缓存（命中 304 时跳过全量传输、解码与落盘）
    var deletionsETag: String?
    var cachedDeletions: DeletionList?
    /// 正在保存的设置项（界面上对应那一行转圈）
    var savingSettings = false
    /// 正在下载 / 存到相册的那张
    var saving: String?
    /// 要打开大图的那张（从小组件点进来），概览页看到就打开
    var openRequest: String?
    /// 一闪而过的提示（「已存到相册」），界面上显示两秒
    var notice: String?
    /// 离线时点的「移出 / 不再选」，连上电脑后自动处理（存在 UserDefaults 里，按 Mac 分开）
    var queued: [OfflineAction] = []
    var flushing = false
    /// 上次发起 Bonjour 重定位的时间（限制频率，避免高频扫网）
    private var lastRelocateAt = Date.distantPast
    private var relocating = false
    private static let relocateCooldown: TimeInterval = 12
    /// 老用户已配对记录缺少 serverID / serviceName 时，首次连上后补齐一次
    private var identityChecked = false

    init(mac: SavedMac, store: MacStore) {
        self.mac = mac
        macID = mac.id
        self.store = store
        queued = Self.loadQueue(macID.uuidString)
        #if DEBUG
        if Self.demoMode != nil { return }
        #endif
        // 上次连上时留下的快照：还没连上之前先用它，离线也能看上回那批壁纸。
        // 一整份壁纸列表在后台读、解码，别卡住首帧。
        Task { @MainActor [weak self] in
            guard let self,
                  let snap = await OfflineStore.shared.loadAsync(self.macID.uuidString) else { return }
            self.restore(snap)
        }
        // 系统网络状态变了立刻反映到连接状态：飞行模式、关掉 Wi‑Fi 时事件流可能要等很久才报错
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let ok = path.status == .satisfied
            let cellular = OfflinePrefs.cellularOnly(path)
            Task { @MainActor [weak self] in self?.networkChanged(ok, cellular: cellular) }
        }
        pathMonitor.start(queue: .global(qos: .utility))
        offlineObserver = NotificationCenter.default.addObserver(forName: OfflineMode.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyHold() }
        }
    }

    /// 现在为什么不连接电脑：手动打开了离线模式，或者只有蜂窝网络且打开了「使用蜂窝网络时离线」。
    var hold: OfflineHold? {
        let prefs = OfflineMode.shared.prefs
        if prefs.manual { return .manual }
        if prefs.onCellular, cellularOnly { return .cellular }
        return nil
    }

    /// 离线模式开关、网络类型变了：该离线就停掉事件流和后台缓存；不再需要离线时重新连。
    private func applyHold() {
        guard !isUnpaired else { return }
        if let hold {
            pendingStart = false
            pathWaitTask?.cancel()
            pathWaitTask = nil
            task?.cancel()
            task = nil
            if !held { ImageStore.shared.cancelPrefetch() }
            held = true
            connection = .offline(hold.message)
        } else if held {
            held = false
            if paused || networkDown { return }
            connection = .connecting
            start()
        }
    }

    /// 用磁盘上的快照先顶着一屏；已经连上、拿到实时状态了就不再覆盖。
    private func restore(_ snap: OfflineStore.Snapshot) {
        guard state == nil else { return }
        state = snap.state
        walls = snap.walls
        wallsRev = snap.wallsRev ?? snap.state.wallsRev
        heroName = snap.hero
        snapshotAt = snap.at
    }

    deinit {
        pathMonitor.cancel()
        if let offlineObserver {
            NotificationCenter.default.removeObserver(offlineObserver)
        }
    }

    /// 手机的网络状态变了：断了就立刻显示离线并停掉卡住的事件流；恢复后重新连。
    private func networkChanged(_ ok: Bool, cellular: Bool) {
        pathReady = true
        pathWaitTask?.cancel()
        pathWaitTask = nil
        let prevCellular = cellularOnly
        let prevDown = networkDown
        cellularOnly = cellular
        if !ok {
            pendingStart = false
            networkDown = true
            guard !isUnpaired else { return }
            connection = .offline("手机未连接网络。")
            task?.cancel()
            task = nil
            return
        }
        networkDown = false
        if hold != nil {
            applyHold()
            return
        }
        if held {
            applyHold()
            return
        }
        // 冷启动等首帧就绪、断网恢复、或关闭蜂窝离线后从蜂窝切回 Wi‑Fi 时，立即唤醒退避等待重连
        let switchedToWiFi = prevCellular && !cellular && connection != .live
        if pendingStart || prevDown || switchedToWiFi {
            pendingStart = false
            if paused { return } // 后台时不主动连，回前台再 start
            guard !isUnpaired else { return }
            connection = .connecting
            start()
        }
    }

    private var isUnpaired: Bool {
        if case .unpaired = connection { return true }
        return false
    }

    /// 会话内部和图片缓存用的底层客户端。视图里发请求别直接拿它，走 `request`。
    func client() throws -> APIClient {
        if hold != nil { throw OfflineHoldError() }
        return try APIClient(address: mac.address, token: store.token(for: macID))
    }

    /// 视图层发请求统一走这里：网络层失败立刻转离线、令牌失效转未配对（`handleRequestError` 不弹提示的那半），
    /// 错误照样抛给调用方，由调用方决定显示在页面上还是弹 `actionError`。
    /// 以前每个页面自己 `client()` 再 catch，要靠人记得补上连接状态的处理，漏过（恢复「不再选」）。
    func request<T>(_ body: (APIClient) async throws -> T) async throws -> T {
        do {
            return try await body(client())
        } catch {
            handleRequestError(error, showMessage: false)
            throw error
        }
    }

    /// 开始（或重新开始）保持连接。App 回到前台时调用。
    func start() {
        paused = false
        if hold != nil { applyHold(); return }
        // 开了「使用蜂窝网络时离线」且 pathMonitor 尚未给出首帧：短暂等待首帧，避免冷启动先发起一次蜂窝连接
        if !pathReady, OfflineMode.shared.prefs.onCellular {
            #if DEBUG
            if Self.demoMode != nil { return }
            #endif
            pendingStart = true
            if connection == .live { connection = .connecting }
            pathWaitTask?.cancel()
            pathWaitTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard let self, !Task.isCancelled, self.pendingStart, !self.paused else { return }
                self.pathReady = true
                self.pendingStart = false
                self.start()
            }
            return
        }
        pendingStart = false
        pathWaitTask?.cancel()
        pathWaitTask = nil
        held = false
        // 回到前台、点了「重试」：事件流连上、收到第一份状态之前都按「正在连接」算。
        // 以前这里不动连接状态，手机在后台时 Mac 走了、回前台后还显示着「已连接」，
        // 这期间点「下载原图 / 分享原图」会对着一个连不上的地址干等到超时。
        if connection == .live { connection = .connecting }
        task?.cancel()
        task = Task { await loop() }
    }

    /// 发请求时发现连不上电脑了（不是电脑返回的错误）：立刻当成断开，
    /// 别等事件流那边超时——那之前界面还以为连着，图片、原图都会去连一个连不上的地址干等。
    /// 判断错误类型见 `isNetworkFailure`。
    func noteNetworkFailure(_ error: Error) {
        guard connection == .live, !paused, !isUnpaired else { return }
        guard Self.isNetworkFailure(error) else { return }
        connection = .offline(Self.describe(error))
        task?.cancel()
        task = Task { await loop() } // 马上重连，不用等事件流那边退出
    }

    /// 网络层的失败（连不上、超时、断了）。服务端返回 4xx/5xx 不算。
    /// `nonisolated`：图片缓存那些后台任务也要用它判断。
    nonisolated static func isNetworkFailure(_ error: Error) -> Bool {
        guard let e = error as? URLError else { return false }
        switch e.code {
        case .timedOut, .cannotConnectToHost, .networkConnectionLost, .cannotFindHost,
             .notConnectedToInternet, .dnsLookupFailed:
            return true
        case .cancelled:
            return false // 自己取消的（换一批、关预览时取消下载），不是连不上
        default:
            return false
        }
    }

    /// App 进入后台时断开，回前台再连。
    func pause() {
        paused = true
        pendingStart = false
        pathWaitTask?.cancel()
        pathWaitTask = nil
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

    /// 外部（小组件回写或用户手动修改地址）更新了这台 Mac 的地址/名称时同步到当前会话。
    func syncMac(_ updated: SavedMac) {
        guard updated.id == macID else { return }
        let addrChanged = updated.address != mac.address
        mac = updated
        if addrChanged {
            lastRelocateAt = .distantPast
            if !paused, hold == nil, !networkDown, !isUnpaired {
                connection = .connecting
                start()
            }
        }
    }

    private func loop() async {
        var delay: Double = 1
        var failures = 0
        while !Task.isCancelled {
            if state == nil { connection = .connecting }
            // 旧 IP 无人占用时 TCP SYN 超时较长：超过 3 秒仍未收到 SSE 首帧时，在后台并行按 Bonjour 检查新地址
            var fastProbe: Task<Void, Never>?
            if !networkDown, !cellularOnly, hold == nil, mac.serverID != nil || mac.serviceName != nil {
                fastProbe = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled, let self else { return }
                    if await self.tryRelocate() {
                        if !self.paused, !self.isUnpaired, self.hold == nil {
                            self.start()
                        }
                    }
                }
            }
            defer { fastProbe?.cancel() }
            do {
                var firstEvent = true
                for try await s in try client().events() {
                    fastProbe?.cancel()
                    fastProbe = nil
                    let wasLive = connection == .live
                    let wasRunning = state?.running == true
                    let isFirst = firstEvent
                    firstEvent = false
                    RunNotifier.observe(new: s, mac: mac.name, macKey: macID.uuidString)
                    if wasRunning, !s.running {
                        WidgetReload.all()
                    }
                    state = s
                    snapshotAt = nil
                    remember()
                    #if os(iOS)
                    // 在后台等的这次换完了：通知已发、快照已保存，直接断开；
                    // 离线队列重放和记录缓存留到回到前台后处理，避免刚派发就被系统挂起截断。
                    if !s.running, bgTask != .invalid { endBackground(disconnect: true); return }
                    #endif
                    connection = .live
                    if (isFirst || !wasLive || (wasRunning && !s.running)), !queued.isEmpty {
                        Task { await flushOfflineActions() }
                    }
                    if wasRunning, !s.running {
                        // 换完一批：日志、删除记录都变了，更新手机上存的记录
                        Task { await refreshRecordsCache() }
                    }
                    if !wasLive {
                        if !identityChecked, mac.serverID == nil || mac.serviceName == nil {
                            Task { await backfillIdentityIfNeeded() }
                        }
                        Task {
                            if s.wallsRev != wallsRev {
                                // 换了一批：refreshWalls 里先收拾缓存，再按新的列表补齐
                                await refreshWalls()
                            } else if !ImageStore.shared.prefetching, !ImageStore.shared.prefetchPaused {
                                // 还是同一批：上一次没缓存完的接着补（已经存下的会跳过）。
                                // 用户自己点了「暂停」的就不动，等用户再点「补齐」
                                ImageStore.shared.prefetch(self)
                            }
                        }
                        // 记录页的三份数据也存一份，下次断了还能看
                        if !(wasRunning && !s.running) {
                            Task { await refreshRecordsCache() }
                        }
                    } else if s.wallsRev != wallsRev {
                        Task { await refreshWalls() }
                    }
                    delay = 1
                    failures = 0
                }
                // 服务端正常关闭（遥控被关掉、应用退出）：当作断开，稍后重连
                throw URLError(.networkConnectionLost)
            } catch APIError.unauthorized(let msg) {
                fastProbe?.cancel()
                // 旧 IP 被另一台 Mac 占用时也会返回 401：先尝试按 Bonjour 重定位，确认地址没变再取消配对
                if await tryRelocate() {
                    delay = 1
                    failures = 0
                    connection = .connecting
                    continue
                }
                markUnpaired(msg)
                return
            } catch {
                fastProbe?.cancel()
                if Task.isCancelled { return }
                failures += 1
                connection = .offline(Self.describe(error))
                // 连不上且在局域网内时，按 serverID / serviceName 通过 Bonjour 查找新地址（带冷却控制）
                if MacRelocator.isNetworkFailure(error), await tryRelocate() {
                    delay = 1
                    failures = 0
                    connection = .connecting
                    continue
                }
            }
            try? await Task.sleep(for: .seconds(delay))
            // 前几次 15 秒内重试（Mac 刚醒、拾景刚打开时很快能连上）；连续失败 8 次以上（约 2 分钟）
            // 多半是不在同一个网络，改成 1 分钟一次，少耗电
            delay = min(delay * 2, failures >= 8 ? 60 : 15)
        }
    }

    /// 首次连上旧版遗留记录（缺少 serverID 或 serviceName）时，顺带查一次 /api/info 回填身份。
    private func backfillIdentityIfNeeded() async {
        guard !identityChecked else { return }
        identityChecked = true
        guard let info = try? await client().info(timeout: 5), info.app == "拾景" else { return }
        let sid = info.serverId ?? mac.serverID
        let svc = mac.serviceName ?? info.name
        if let updated = store.update(macID, name: info.name, serverID: sid, serviceName: svc) {
            mac = updated
        }
    }

    /// 通过 Bonjour 重新查找 Mac 地址并经 /api/info 核对身份；命中后原地更新地址与名称，地址有变化时返回 true。
    private func tryRelocate() async -> Bool {
        guard !relocating, !networkDown, !cellularOnly, hold == nil, !isUnpaired else { return false }
        guard mac.serverID != nil || mac.serviceName != nil else { return false }
        guard Date().timeIntervalSince(lastRelocateAt) >= Self.relocateCooldown else { return false }

        relocating = true
        lastRelocateAt = Date()
        defer { relocating = false }

        let targetServerID = mac.serverID
        let targetServiceName = mac.serviceName
        guard let resolved = await MacRelocator.locate(
            serverID: targetServerID,
            serviceName: targetServiceName,
            timeout: 3.5
        ) else {
            return false
        }
        guard !Task.isCancelled, !paused, !isUnpaired, hold == nil else { return false }

        let addrChanged = resolved.address != mac.address
        if let updated = store.update(
            macID,
            address: resolved.address,
            name: resolved.name,
            serverID: resolved.serverID,
            serviceName: resolved.serviceName
        ) {
            mac = updated
        } else {
            mac.host = resolved.address.host
            mac.port = resolved.address.port
            mac.name = resolved.name
            mac.serviceName = resolved.serviceName
            if let sid = resolved.serverID { mac.serverID = sid }
        }
        return addrChanged
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? URLError {
            switch e.code {
            case .timedOut, .cannotConnectToHost, .networkConnectionLost, .cannotFindHost:
                return "无法连接到这台 Mac：确认 Mac 未休眠、拾景正在运行、设置中已打开「允许手机遥控」，手机与 Mac 处于同一网络。"
            case .notConnectedToInternet:
                return "手机未连接网络。"
            default:
                break
            }
        }
        return error.localizedDescription
    }

    /// 令牌失效（401）：切到未配对状态，并立刻停掉事件流和后台图片预取。
    func markUnpaired(_ msg: String) {
        connection = .unpaired(msg)
        task?.cancel()
        task = nil
        ImageStore.shared.cancelPrefetch()
    }

    /// 一次请求失败：令牌失效就转「未配对」；其余弹提示，网络层失败立刻转离线。
    /// 会话里每个请求、视图层自己发请求的地方都调它，别各抄一份。
    /// `showMessage` 为 false 时只改连接状态（页面自己有行内错误，或者后台刷新不想打扰用户）。
    func handleRequestError(_ error: Error, showMessage: Bool = true) {
        if case APIError.unauthorized(let msg) = error {
            markUnpaired(msg)
            return
        }
        if showMessage { actionError = Self.describe(error) }
        noteNetworkFailure(error)
    }

}
