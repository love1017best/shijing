import Foundation
import Observation
import Photos
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
    private(set) var mac: SavedMac
    private(set) var connection: Connection = .connecting
    private(set) var state: RemoteState?
    /// 正在等「换一批」「停止」的响应
    private(set) var busy = false
    /// 上一次操作失败的原因（界面上弹提示）
    var actionError: String?
    /// 壁纸文件夹里的图（和桌面同样的顺序）；walls_rev 变了就重新拉
    private(set) var walls: [Wallpaper] = []
    private(set) var wallsRev: String?
    /// 横幅图的文件名（桌面概览顶部那张）；旧版桌面端没给时用第一张
    private(set) var heroName: String?
    var hero: Wallpaper? { walls.first { $0.name == heroName } ?? walls.first }
    /// 正在移出 / 删除的那张
    private(set) var acting: String?

    private let store: MacStore
    private var task: Task<Void, Never>?

    init(mac: SavedMac, store: MacStore) {
        self.mac = mac
        macID = mac.id
        self.store = store
    }

    func client() throws -> APIClient {
        try APIClient(address: mac.address, token: store.token(for: macID))
    }

    /// 开始（或重新开始）保持连接。App 回到前台时调用。
    func start() {
        task?.cancel()
        task = Task { await loop() }
    }

    /// App 进入后台时断开，回前台再连。
    func pause() {
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
                for try await s in try client().events() {
                    RunNotifier.observe(old: state, new: s, mac: mac.name)
                    if state?.running == true, !s.running { WidgetReload.all() }
                    state = s
                    #if os(iOS)
                    // 在后台等的这次换完了：通知已经发了，断开
                    if !s.running, bgTask != .invalid { endBackground(disconnect: true); return }
                    #endif
                    connection = .live
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
    private(set) var savingSettings = false

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
        } catch APIError.unauthorized(let msg) {
            connection = .unpaired(msg)
        } catch {
            actionError = Self.describe(error)
        }
    }

    /// 撤销最近一次移出：放回壁纸文件夹原来的位置。成功时返回放回去的那张的文件名。
    @discardableResult
    func undoRemove() async -> String? {
        guard let name = state?.undoName else { return nil }
        acting = name
        defer { acting = nil }
        do {
            state = try await client().undo()
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
    private(set) var saving: String?
    /// 一闪而过的提示（「已存到相册」），界面上显示两秒
    var notice: String?

    /// 从电脑下载原文件，原样存进相册（不重新编码，保留原分辨率和 EXIF）。
    func saveOriginal(_ w: Wallpaper) async {
        saving = w.name
        defer { saving = nil }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            actionError = "没有存照片的权限：到「设置 › 隐私与安全性 › 照片 › 拾景」里允许「仅添加照片」。"
            return
        }
        do {
            let file = try await client().downloadOriginal(w.name)
            defer { try? FileManager.default.removeItem(at: file) }
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

    /// 重新拉壁纸列表（状态里的 walls_rev 变了时自动调）。
    func refreshWalls() async {
        guard let rev = state?.wallsRev, rev != wallsRev else { return }
        do {
            let list = try await client().wallpapers()
            walls = list.items
            wallsRev = list.rev
            heroName = list.hero
        } catch {
            // 列表拉不到不影响别的，下次状态推送再试
        }
    }

    /// 移出壁纸文件夹；exclude 时以后的采样也跳过这张原图。成功返回 true。
    @discardableResult
    func removeWallpaper(_ w: Wallpaper, exclude: Bool) async -> Bool {
        await wallAct(w) { try await $0.removeWallpaper(w.name, exclude: exclude) }
    }

    /// 删除图库里的原图（界面上已经二次确认过）。
    @discardableResult
    func deleteOriginal(_ w: Wallpaper) async -> Bool {
        await wallAct(w) { try await $0.deleteOriginal(w.name) }
    }

    private func wallAct(_ w: Wallpaper, _ op: (APIClient) async throws -> RemoteState) async -> Bool {
        acting = w.name
        defer { acting = nil }
        #if DEBUG
        if Self.demoMode != nil { // 演示模式：只在本地去掉
            walls.removeAll { $0.name == w.name }
            return true
        }
        #endif
        do {
            state = try await op(client())
            // 先在本地去掉，不用等重新拉列表
            walls.removeAll { $0.name == w.name }
            await refreshWalls()
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
        } catch APIError.unauthorized(let msg) {
            connection = .unpaired(msg)
        } catch {
            actionError = Self.describe(error)
        }
    }
}

#if DEBUG
// MARK: - 演示模式（只在 Debug 构建里）：启动参数带 -demo / -demoRunning 时不连真的 Mac，
// 直接显示一份假状态，用来在模拟器里截图检查布局。
extension RemoteSession {
    static var demoMode: String? {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-demoRunning") { return "running" }
        return args.contains("-demo") || args.contains("-demoPreview") ? "idle" : nil
    }

    static func demo(_ mode: String, store: MacStore) -> RemoteSession {
        let mac = SavedMac(name: "演示 Mac", serviceName: nil, host: "192.168.1.20", port: 52819)
        let s = RemoteSession(mac: mac, store: store)
        let running = mode == "running"
        let now = Date().timeIntervalSince1970
        s.state = RemoteState(
            version: "0.3.7", eyebrow: running ? "正在换壁纸" : "当前壁纸 · 11月11日 15:04 换上",
            title: running ? "正在拾一批新风景…" : "已换上 300 张新壁纸",
            running: running, stopping: false, steps: ["filter", "scan", "copy", "refresh"],
            stage: running ? "copy" : nil, done: running ? 128 : 0, total: running ? 300 : 0,
            fraction: running ? 128.0 / 300 : -1, label: running ? "复制 128 / 300 张 · 还剩约 1 分钟" : nil,
            lastLine: running ? "[风景/冰岛] ✅ 已复制: 风景-冰岛-0423.jpg" : nil,
            runDelete: true, rejected: 3, deleted: 3, deleteFailed: 0,
            blocked: nil, unmounted: 0, willDelete: true,
            deleteNote: "会先检查「筛选 + 采样」里的 2 个目录，把竖屏、正方形和低于 3840×2160 的图片从图库里直接删除，不可撤销。",
            last: running ? nil : LastRun(at: now - 3600, status: "ok", error: nil, selected: 300, copied: 300, failed: 0,
                                         elapsed: 73, brief: "重合 4% · 删 3 张",
                                         detail: "和上一轮相比：新换上 288 张，重复 12 张（重合率 4%）\n筛选删除 3 张\n覆盖 300 / 415 个文件夹"),
            nextAuto: now + 6 * 3600, wallpapers: 300, wallsRev: "demo", dest: "~/Pictures/Wallpapers0", sampleCount: 300, libraryDirs: 3)
        s.state?.settings = RemoteSettings(sampleCount: 300, autoRunHours: 6, autoOptions: [0, 6, 12, 24, 168],
                                           deleteDuringFilter: true, preferUnseen: true, refreshWallpaper: true)
        s.state?.undoName = running ? nil : "风景-京都-0012.jpg"
        s.state?.excluded = 12
        s.connection = .live
        let places = ["冰岛", "阿尔卑斯", "京都", "黄石", "新西兰", "巴塔哥尼亚", "挪威", "托斯卡纳", "大理", "落基山"]
        s.walls = (0..<300).map { i in
            Wallpaper(name: "风景-\(places[i % places.count])-\(String(format: "%04d", i)).jpg",
                      source: i % 7 == 6 ? nil : "/Volumes/Media0/风景/\(places[i % places.count])/\(String(format: "%04d", i)).jpg")
        }
        s.wallsRev = "demo"
        ImageStore.shared.demo = true
        return s
    }
}
#endif
