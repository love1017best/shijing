import Foundation
import Observation

/// 和一台 Mac 的连接：保存实时与离线状态、壁纸列表和待处理队列，连接状态机由 `RemoteConnection` 驱动。
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
    /// 手机现在只有蜂窝网络（没有 Wi‑Fi、有线）
    var cellularOnly = false

    private let store: MacStore
    @ObservationIgnored private var conn: RemoteConnection!
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
    /// 老用户已配对记录缺少 serverID / serviceName 时，首次连上后补齐一次
    private var identityChecked = false

    init(mac: SavedMac, store: MacStore) {
        self.mac = mac
        macID = mac.id
        self.store = store
        queued = Self.loadQueue(macID.uuidString)

        var isDemo = false
        #if DEBUG
        if Self.demoMode != nil { isDemo = true }
        #endif

        conn = RemoteConnection(demoMode: isDemo, hooks: RemoteConnection.Hooks(
            currentMac: { [weak self] in self?.mac ?? mac },
            hasState: { [weak self] in self?.state != nil },
            isRunning: { [weak self] in self?.state?.running == true },
            currentConnection: { [weak self] in self?.connection ?? .offline("") },
            makeClient: { [weak self] in
                guard let self else { throw OfflineHoldError() }
                return try self.client()
            },
            onConnectionChange: { [weak self] next in
                self?.connection = next
            },
            onCellularChange: { [weak self] cellular in
                self?.cellularOnly = cellular
            },
            onEvent: { [weak self] state, isFirst in
                self?.handleStreamEvent(state, isFirst: isFirst)
            },
            onUnpaired: { [weak self] msg in
                self?.markUnpaired(msg)
            },
            onRelocated: { [weak self] resolved in
                self?.applyRelocated(resolved) ?? false
            }
        ))

        if isDemo { return }
        // 上次连上时留下的快照：还没连上之前先用它，离线也能看上回那批壁纸。
        // 一整份壁纸列表在后台读、解码，别卡住首帧。
        Task { @MainActor [weak self] in
            guard let self,
                  let snap = await OfflineStore.shared.loadAsync(self.macID.uuidString) else { return }
            self.restore(snap)
        }
    }

    var paused: Bool { conn.paused }

    /// 现在为什么不连接电脑：手动打开了离线模式，或者只有蜂窝网络且打开了「使用蜂窝网络时离线」。
    var hold: OfflineHold? {
        let prefs = OfflineMode.shared.prefs
        if prefs.manual { return .manual }
        if prefs.onCellular, cellularOnly { return .cellular }
        return nil
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

    /// 会话内部和图片缓存用的底层客户端。视图里发请求别直接拿它，走 `request`。
    func client() throws -> APIClient {
        if hold != nil { throw OfflineHoldError() }
        return try APIClient(address: mac.address, token: store.token(for: macID))
    }

    /// 视图层发请求统一走这里：网络层失败立刻转离线、令牌失效转未配对（`handleRequestError` 不弹提示的那半），
    /// 错误照样抛给调用方，由调用方决定显示在页面上还是弹 `actionError`。
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
        var isDemo = false
        #if DEBUG
        if Self.demoMode != nil { isDemo = true }
        #endif
        conn.start(demoMode: isDemo)
    }

    /// App 进入后台时断开，回前台再连。
    func pause() {
        conn.pause()
    }

    /// 进了后台：正在换壁纸的话向系统多要一会儿后台时间，继续连着，换完能发通知；没在换就直接断开。
    func enterBackground() {
        conn.enterBackground()
    }

    /// 回到前台（或者后台时间用完）。
    func endBackground(disconnect: Bool) {
        conn.endBackground(disconnect: disconnect)
    }

    /// 外部（小组件回写或用户手动修改地址）更新了这台 Mac 的地址/名称时同步到当前会话。
    func syncMac(_ updated: SavedMac) {
        guard updated.id == macID else { return }
        let addrChanged = updated.address != mac.address
        mac = updated
        if addrChanged {
            conn.syncAddressChanged()
        }
    }

    /// 发请求时发现连不上电脑了（不是电脑返回的错误）：立刻当成断开并重连。
    func noteNetworkFailure(_ error: Error) {
        conn.noteNetworkFailure(error)
    }

    /// 网络层的失败（连不上、超时、断了）。服务端返回 4xx/5xx 不算。
    nonisolated static func isNetworkFailure(_ error: Error) -> Bool {
        RemoteConnection.isNetworkFailure(error)
    }

    static func describe(_ error: Error) -> String {
        RemoteConnection.describe(error)
    }

    /// 处理 SSE 推回的一帧状态快照，驱动本地快照、离线队列重放、壁纸刷新与记录缓存。
    private func handleStreamEvent(_ s: RemoteState, isFirst: Bool) {
        let wasLive = connection == .live
        let wasRunning = state?.running == true
        RunNotifier.observe(new: s, mac: mac.name, macKey: macID.uuidString)
        if wasRunning, !s.running {
            WidgetReload.all()
        }
        state = s
        snapshotAt = nil
        remember()
        // 在后台等的这次换完了：通知已发、快照已保存，由 RemoteConnection 立即断开；
        // 离线队列重放和记录缓存留到回到前台后处理，避免刚派发就被系统挂起截断。
        if !s.running, conn.hasActiveBackgroundTask { return }

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

    /// Bonjour 重定位命中后原地更新保存的 Mac 地址与名称，地址有变化时返回 true。
    private func applyRelocated(_ resolved: MacRelocator.ResolvedMac) -> Bool {
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

    /// 令牌失效（401）：切到未配对状态，并立刻停掉事件流和后台图片预取。
    func markUnpaired(_ msg: String) {
        connection = .unpaired(msg)
        conn.stopStream()
        ImageStore.shared.cancelPrefetch()
    }

    /// 一次请求失败：令牌失效就转「未配对」；其余弹提示，网络层失败立刻转离线。
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
