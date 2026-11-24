import Foundation
import Network
#if canImport(UIKit)
import UIKit
#endif

/// 管理与单台 Mac 的连接状态机：`NWPathMonitor`、离线模式保持、后台任务、SSE 事件流与 Bonjour 重定位。
@MainActor
final class RemoteConnection {
    struct Hooks {
        var currentMac: () -> SavedMac
        var hasState: () -> Bool
        var isRunning: () -> Bool
        var currentConnection: () -> RemoteSession.Connection
        var makeClient: () throws -> APIClient
        var onConnectionChange: (RemoteSession.Connection) -> Void
        var onCellularChange: (Bool) -> Void
        var onEvent: (RemoteState, Bool) -> Void
        var onUnpaired: (String) -> Void
        var onRelocated: (MacRelocator.ResolvedMac) -> Bool
    }

    private let hooks: Hooks
    private var task: Task<Void, Never>?
    /// 用户切到后台时 pause，回前台再 start：这期间网络变了也别自己重连
    private(set) var paused = false
    /// 手机自己的网络断了（飞行模式、关了 Wi‑Fi）：不用等事件流报错，立刻显示离线
    private let pathMonitor = NWPathMonitor()
    private var networkDown = false
    /// 手机现在只有蜂窝网络（没有 Wi‑Fi、有线）
    private(set) var cellularOnly = false
    /// 是否已经收到过一次 pathMonitor 回调（冷启动时等首帧，避免抢先发起蜂窝连接）
    private var pathReady = false
    /// start() 调用时 pathMonitor 首帧尚未到达，首帧到位后再按真实网络状态决定是否连接
    private var pendingStart = false
    /// 等待 pathMonitor 首帧的短超时兜底任务
    private var pathWaitTask: Task<Void, Never>?
    /// 离线模式变更通知观察者（deinit 时移除）
    nonisolated(unsafe) private var offlineObserver: NSObjectProtocol?
    /// 因离线模式断开的（不是连不上）：退出离线模式时要重新连
    private var held = false
    /// 上次发起 Bonjour 重定位的时间（限制频率，避免高频扫网）
    private var lastRelocateAt = Date.distantPast
    private var relocating = false
    private static let relocateCooldown: TimeInterval = 12

    #if os(iOS)
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    #endif

    init(demoMode: Bool = false, hooks: Hooks) {
        self.hooks = hooks
        if demoMode { return }
        // 系统网络状态变了立刻反映到连接状态：飞行模式、关掉 Wi‑Fi 时事件流可能要等很久才报错
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let ok = path.status == .satisfied
            let cellular = OfflinePrefs.cellularOnly(path)
            Task { @MainActor [weak self] in self?.networkChanged(ok, cellular: cellular) }
        }
        pathMonitor.start(queue: .global(qos: .utility))
        offlineObserver = NotificationCenter.default.addObserver(
            forName: OfflineMode.changed,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyHold() }
        }
    }

    deinit {
        pathMonitor.cancel()
        if let offlineObserver {
            NotificationCenter.default.removeObserver(offlineObserver)
        }
    }

    /// 现在为什么不连接电脑：手动打开了离线模式，或者只有蜂窝网络且打开了「使用蜂窝网络时离线」。
    var hold: OfflineHold? {
        let prefs = OfflineMode.shared.prefs
        if prefs.manual { return .manual }
        if prefs.onCellular, cellularOnly { return .cellular }
        return nil
    }

    private var isUnpaired: Bool {
        if case .unpaired = hooks.currentConnection() { return true }
        return false
    }

    /// 离线模式开关、网络类型变了：该离线就停掉事件流和后台缓存；不再需要离线时重新连。
    func applyHold() {
        guard !isUnpaired else { return }
        if let hold {
            pendingStart = false
            pathWaitTask?.cancel()
            pathWaitTask = nil
            task?.cancel()
            task = nil
            if !held { ImageStore.shared.cancelPrefetch() }
            held = true
            hooks.onConnectionChange(.offline(hold.message))
        } else if held {
            held = false
            if paused || networkDown { return }
            hooks.onConnectionChange(.connecting)
            start()
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
        hooks.onCellularChange(cellular)
        if !ok {
            pendingStart = false
            networkDown = true
            guard !isUnpaired else { return }
            hooks.onConnectionChange(.offline("手机未连接网络。"))
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
        let switchedToWiFi = prevCellular && !cellular && hooks.currentConnection() != .live
        if pendingStart || prevDown || switchedToWiFi {
            pendingStart = false
            if paused { return } // 后台时不主动连，回前台再 start
            guard !isUnpaired else { return }
            hooks.onConnectionChange(.connecting)
            start()
        }
    }

    /// 开始（或重新开始）保持连接。App 回到前台时调用。
    func start(demoMode: Bool = false) {
        paused = false
        if hold != nil { applyHold(); return }
        // 开了「使用蜂窝网络时离线」且 pathMonitor 尚未给出首帧：短暂等待首帧，避免冷启动先发起一次蜂窝连接
        if !pathReady, OfflineMode.shared.prefs.onCellular {
            if demoMode { return }
            pendingStart = true
            if hooks.currentConnection() == .live { hooks.onConnectionChange(.connecting) }
            pathWaitTask?.cancel()
            pathWaitTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard let self, !Task.isCancelled, self.pendingStart, !self.paused else { return }
                self.pathReady = true
                self.pendingStart = false
                self.start(demoMode: demoMode)
            }
            return
        }
        pendingStart = false
        pathWaitTask?.cancel()
        pathWaitTask = nil
        held = false
        // 回到前台、点了「重试」：事件流连上、收到第一份状态之前都按「正在连接」算。
        if hooks.currentConnection() == .live { hooks.onConnectionChange(.connecting) }
        task?.cancel()
        task = Task { await loop() }
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

    /// 停止事件流（如 401 取消配对时调用）。
    func stopStream() {
        task?.cancel()
        task = nil
    }

    /// 进了后台：正在换壁纸的话向系统多要一会儿后台时间，继续连着，换完能发通知；没在换就直接断开。
    func enterBackground() {
        #if os(iOS)
        guard hooks.isRunning(), bgTask == .invalid else {
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

    /// 是否正在后台保活等待本次换壁纸结束。
    var hasActiveBackgroundTask: Bool {
        #if os(iOS)
        return bgTask != .invalid
        #else
        return false
        #endif
    }

    /// 外部更新了 Mac 地址时重置重定位冷却并按当前状态立即重连。
    func syncAddressChanged() {
        lastRelocateAt = .distantPast
        if !paused, hold == nil, !networkDown, !isUnpaired {
            hooks.onConnectionChange(.connecting)
            start()
        }
    }

    /// 发请求时发现连不上电脑了（不是电脑返回的错误）：立刻当成断开并重连。
    func noteNetworkFailure(_ error: Error) {
        guard hooks.currentConnection() == .live, !paused, !isUnpaired else { return }
        guard Self.isNetworkFailure(error) else { return }
        hooks.onConnectionChange(.offline(Self.describe(error)))
        task?.cancel()
        task = Task { await loop() }
    }

    /// 网络层的失败（连不上、超时、断了）。服务端返回 4xx/5xx 不算。
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

    private func loop() async {
        var delay: Double = 1
        var failures = 0
        while !Task.isCancelled {
            if !hooks.hasState() { hooks.onConnectionChange(.connecting) }
            // 旧 IP 无人占用时 TCP SYN 超时较长：超过 3 秒仍未收到 SSE 首帧时，在后台并行按 Bonjour 检查新地址
            var fastProbe: Task<Void, Never>?
            let mac = hooks.currentMac()
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
                for try await s in try hooks.makeClient().events() {
                    fastProbe?.cancel()
                    fastProbe = nil
                    let isFirst = firstEvent
                    firstEvent = false
                    hooks.onEvent(s, isFirst)
                    if !s.running, hasActiveBackgroundTask {
                        endBackground(disconnect: true)
                        return
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
                    hooks.onConnectionChange(.connecting)
                    continue
                }
                hooks.onUnpaired(msg)
                return
            } catch {
                fastProbe?.cancel()
                if Task.isCancelled { return }
                failures += 1
                hooks.onConnectionChange(.offline(Self.describe(error)))
                // 连不上且在局域网内时，按 serverID / serviceName 通过 Bonjour 查找新地址（带冷却控制）
                if MacRelocator.isNetworkFailure(error), await tryRelocate() {
                    delay = 1
                    failures = 0
                    hooks.onConnectionChange(.connecting)
                    continue
                }
            }
            try? await Task.sleep(for: .seconds(delay))
            delay = ReconnectBackoff.nextDelay(current: delay, failures: failures)
        }
    }

    /// 通过 Bonjour 重新查找 Mac 地址并经 /api/info 核对身份；命中后回调会话更新，地址有变化时返回 true。
    private func tryRelocate() async -> Bool {
        guard !relocating, !networkDown, !cellularOnly, hold == nil, !isUnpaired else { return false }
        let mac = hooks.currentMac()
        guard mac.serverID != nil || mac.serviceName != nil else { return false }
        guard Date().timeIntervalSince(lastRelocateAt) >= Self.relocateCooldown else { return false }

        relocating = true
        lastRelocateAt = Date()
        defer { relocating = false }

        guard let resolved = await MacRelocator.locate(
            serverID: mac.serverID,
            serviceName: mac.serviceName,
            timeout: 3.5
        ) else {
            return false
        }
        guard !Task.isCancelled, !paused, !isUnpaired, hold == nil else { return false }
        return hooks.onRelocated(resolved)
    }
}
