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
    /// 现在显示的状态是从磁盘快照来的（还没连上过）：界面上标「离线 · X 前同步」
    private(set) var snapshotAt: Date?

    private let store: MacStore
    private var task: Task<Void, Never>?
    /// 上次把快照写到磁盘的时间（运行中状态更新很密，最多 5 秒写一次）
    private var lastSnapshotSave = Date.distantPast
    /// 离线时点的「移出 / 不再选」，连上电脑后自动补上（存在 UserDefaults 里，按 Mac 分开）
    private(set) var queued: [OfflineAction] = []
    private var flushing = false

    init(mac: SavedMac, store: MacStore) {
        self.mac = mac
        macID = mac.id
        self.store = store
        // 上次连上时留下的快照：还没连上之前先用它，离线也能看上回那批壁纸
        if let snap = OfflineStore.shared.load(macID.uuidString) {
            state = snap.state
            walls = snap.walls
            wallsRev = snap.state.wallsRev
            heroName = snap.hero
            snapshotAt = snap.at
        }
        queued = Self.loadQueue(macID.uuidString)
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
                    let wasLive = connection == .live
                    RunNotifier.observe(old: state, new: s, mac: mac.name)
                    if state?.running == true, !s.running { WidgetReload.all() }
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
    private(set) var saving: String?
    /// 要打开大图的那张（从小组件点进来），概览页看到就打开
    var openRequest: String?
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
            remember(wallsChanged: true)
            ImageStore.groom(keepRev: list.rev) // 上一批的图片缓存整个删掉
            ImageStore.shared.prefetchAll(self) // 这一批的缩略图和预览图存到磁盘，离线也能看
        } catch {
            // 列表拉不到不影响别的，下次状态推送再试
        }
    }

    /// 把当前状态和壁纸列表写到磁盘（离线时显示的上次样子）。运行中状态推得很密，最多 5 秒写一次；
    /// 壁纸列表变了（wallsChanged）时立刻写。
    private func remember(wallsChanged: Bool = false) {
        #if DEBUG
        if Self.demoMode != nil { return }
        #endif
        guard let state else { return }
        let now = Date()
        if !wallsChanged, now.timeIntervalSince(lastSnapshotSave) < 5 { return }
        lastSnapshotSave = now
        OfflineStore.shared.save(macID.uuidString, .init(state: state, walls: walls, hero: heroName, at: now))
    }

    /// 移出壁纸文件夹；exclude 时以后的采样也跳过这张原图。成功返回 true。
    @discardableResult
    func removeWallpaper(_ w: Wallpaper, exclude: Bool) async -> Bool {
        await wallAct(w, kind: exclude ? .exclude : .remove) { try await $0.removeWallpaper(w.name, exclude: exclude) }
    }

    /// 删除图库里的原图（界面上已经二次确认过）。离线时不能排队（不可撤销，等连上再做），
    /// 手机误触一下、电脑半夜连上网就把 NAS 上的原图删了，后果太重。
    @discardableResult
    func deleteOriginal(_ w: Wallpaper) async -> Bool {
        guard connection == .live else {
            actionError = "连不上电脑时不能删除原图（不可撤销）。可以先移出或者「不再选它」，连上电脑后自动补上。"
            return false
        }
        return await wallAct(w, kind: .remove) { try await $0.deleteOriginal(w.name) }
    }

    private func wallAct(_ w: Wallpaper, kind: OfflineAction.Kind, _ op: (APIClient) async throws -> RemoteState) async -> Bool {
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
            await refreshWalls()
            return true
        } catch APIError.unauthorized(let msg) {
            connection = .unpaired(msg)
        } catch {
            actionError = Self.describe(error)
        }
        return false
    }

    // MARK: 离线时记下的整理（连上后补上）

    /// 离线时点的一张整理操作：只记「移出」「不再选」，删除原图离线时不让做。
    /// `wall` / `index` 用来在取消「移出」时把那张放回列表原来的位置（旧版本记下的没有，只能取消、放不回去）。
    struct OfflineAction: Codable, Identifiable, Equatable {
        enum Kind: String, Codable { case remove, exclude }
        var id = UUID()
        var kind: Kind
        var name: String
        var source: String?
        var at = Date()
        var wall: Wallpaper?
        var index: Int?
    }

    var offline: Bool { connection != .live }

    /// 撤销按钮显示的名字：在线时是电脑上最近一次移出；离线时是手机上最近一条还没补上的「移出」。
    var undoName: String? {
        if offline { return queued.last { $0.kind == .remove }?.name }
        return state?.undoName
    }

    #if DEBUG
    /// 截图用（-demo -demoOffline）：塞两条离线操作，看提示和「待补操作」是什么样
    func seedQueuedForDemo() {
        guard walls.count > 5 else { return }
        let r = walls[2]
        walls.remove(at: 2)
        let e = walls[3]
        queued = [
            OfflineAction(kind: .remove, name: r.name, source: r.source, wall: r, index: 2),
            OfflineAction(kind: .exclude, name: e.name, source: e.source, wall: e, index: 3),
        ]
    }
    #endif

    private static func queueKey(_ id: String) -> String { "offlineActions." + id }

    private static func loadQueue(_ id: String) -> [OfflineAction] {
        guard let data = UserDefaults.standard.data(forKey: queueKey(id)) else { return [] }
        return (try? JSONDecoder().decode([OfflineAction].self, from: data)) ?? []
    }

    private func saveQueue() {
        if queued.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.queueKey(macID.uuidString))
        } else if let data = try? JSONEncoder().encode(queued) {
            UserDefaults.standard.set(data, forKey: Self.queueKey(macID.uuidString))
        }
    }

    private func enqueue(_ kind: OfflineAction.Kind, _ w: Wallpaper) {
        guard !queued.contains(where: { $0.name == w.name && $0.kind == kind }) else { return }
        let index = walls.firstIndex { $0.name == w.name }
        queued.append(OfflineAction(kind: kind, name: w.name, source: w.source, wall: w, index: index))
        saveQueue()
        // 本地先去掉，界面跟着变；连上电脑后再真的移出
        walls.removeAll { $0.name == w.name }
        remember(wallsChanged: true)
        notice = kind == .exclude ? "已记下：连上电脑后移出并不再选它" : "已记下：连上电脑后移出"
    }

    /// 取消一条还没补上的离线操作。「移出」的那张放回列表原来的位置。
    func cancelQueued(_ a: OfflineAction, announce: Bool = true) {
        guard queued.contains(where: { $0.id == a.id }) else { return }
        queued.removeAll { $0.id == a.id }
        saveQueue()
        if a.kind == .remove {
            restore(a)
            remember(wallsChanged: true)
        }
        if announce {
            notice = a.kind == .remove ? "已取消，放回列表：\(a.name)" : "已取消：\(a.name)"
        }
    }

    /// 全部取消：记下的「移出」都放回列表。
    func cancelAllQueued() {
        guard !queued.isEmpty else { return }
        let list = queued
        queued = []
        saveQueue()
        // 按原来的位置从小到大放回去，后面的下标才对得上
        for a in list.filter({ $0.kind == .remove }).sorted(by: { ($0.index ?? 0) < ($1.index ?? 0) }) {
            restore(a)
        }
        remember(wallsChanged: true)
        notice = "已取消 \(list.count) 项离线操作"
    }

    private func restore(_ a: OfflineAction) {
        guard let w = a.wall, !walls.contains(where: { $0.name == w.name }) else { return }
        walls.insert(w, at: min(max(a.index ?? walls.count, 0), walls.count))
    }

    /// 连上以后把离线时记下的操作补上：「不再选」直接加进名单（和那张壁纸还在不在这一批无关），
    /// 「移出」的那张如果这一批已经换掉了就算过期。网络又断了的话剩下的留着下次。
    private func flushOfflineActions() async {
        guard !flushing, !queued.isEmpty, connection == .live else { return }
        flushing = true
        defer { flushing = false }
        var rest: [OfflineAction] = []
        var applied = 0
        var expired = 0
        let list = queued
        for (i, act) in list.enumerated() {
            do {
                switch act.kind {
                case .exclude:
                    guard let src = act.source, !src.isEmpty else { expired += 1; continue }
                    _ = try await client().addExcluded([src])
                    applied += 1
                case .remove:
                    guard walls.contains(where: { $0.name == act.name }) else { expired += 1; continue }
                    _ = try await client().removeWallpaper(act.name, exclude: false)
                    applied += 1
                }
            } catch APIError.server(let status, _) where status == 404 || status == 409 {
                expired += 1
            } catch APIError.unauthorized(let msg) {
                connection = .unpaired(msg)
                rest.append(contentsOf: list[i...])
                break
            } catch {
                rest.append(contentsOf: list[i...]) // 又断了：留着下次
                break
            }
        }
        queued = rest
        saveQueue()
        if applied > 0 {
            await refreshWalls()
            notice = expired > 0 ? "已补上 \(applied) 项离线操作，\(expired) 项已经过期" : "已补上 \(applied) 项离线操作"
        }
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
        s.heroName = s.walls.first?.name // 和真的桌面一样给一张横幅图
        // 截图用：-demo -demoOffline 显示「离线，显示的是上次同步的壁纸」的样子
        if ProcessInfo.processInfo.arguments.contains("-demoOffline") {
            s.connection = .offline("连不上这台 Mac：确认它没有睡眠、拾景开着并打开了「允许手机遥控」，手机和电脑在同一个网络里。")
            s.snapshotAt = Date().addingTimeInterval(-3 * 3600 - 2400)
            // 顺便把演示图写进磁盘缓存，让「离线也能看图」这条路径真的走一遍（读的是磁盘，不是内存里的演示图）
            ImageStore.shared.seedDiskCache(rev: "demo", names: s.walls.prefix(24).map(\.name), hero: s.heroName)
            s.seedQueuedForDemo()
        } else {
            ImageStore.shared.demo = true
        }
        return s
    }
}
#endif
