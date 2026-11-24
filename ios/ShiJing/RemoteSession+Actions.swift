import Foundation
import Photos

// MARK: - 遥控操作、设置更新、相册保存与壁纸管理

extension RemoteSession {
    func run(deleteOriginals: Bool) async {
        Notifications.requestOnce()
        await act { try await $0.run(deleteOriginals: deleteOriginals) }
        WidgetReload.all()
    }

    func stop() async {
        await act { try await $0.stop() }
    }

    // MARK: 设置、撤销

    /// 改常用设置：只传要改的字段。失败时弹提示，界面回到电脑上的值。
    func updateSettings(_ changes: [String: Any]) async {
        #if DEBUG
        if Self.demoMode != nil, var set = state?.settings { // 演示模式：只改本地
            if let n = changes["sample_count"] as? Int { set.sampleCount = n; state?.sampleCount = n }
            if let h = changes["auto_run_hours"] as? Int { set.autoRunHours = h }
            if let v = changes["delete_during_filter"] as? Bool { set.deleteDuringFilter = v }
            if let v = changes["prefer_unseen"] as? Bool { set.preferUnseen = v }
            if let v = changes["refresh_wallpaper"] as? Bool { set.refreshWallpaper = v }
            if let v = changes["balance_first"] as? Bool { set.balanceFirst = v }
            if let v = changes["incremental"] as? Bool { set.incremental = v }
            if let v = changes["mode"] as? String { set.mode = v }
            if let v = changes["min_width"] as? Int { set.minWidth = v }
            if let v = changes["min_height"] as? Int { set.minHeight = v }
            if let v = changes["archive_enabled"] as? Bool { set.archiveEnabled = v }
            state?.settings = set
            return
        }
        #endif
        savingSettings = true
        defer { savingSettings = false }
        do {
            state = try await client().updateSettings(changes)
            remember()
        } catch {
            handleRequestError(error)
        }
    }

    // MARK: 待删除队列、挂载检查

    /// 取消电脑上排队的一项删除原图（图库没连上时排的队，电脑连上后会自己执行）。
    func cancelPending(_ item: PendingItem) async {
        guard await pendingAct({ try await $0.cancelPending(item.path) }) else { return }
        showNotice("已取消排队删除：\(item.name)")
    }

    /// 一次取消所有排队的删除原图。
    func cancelAllPending() async {
        guard await pendingAct({ try await $0.cancelPending(nil) }) else { return }
        showNotice("已取消所有排队删除")
    }

    private func pendingAct(_ op: (APIClient) async throws -> RemoteState) async -> Bool {
        guard connection == .live else {
            actionError = "无法连接到电脑，排队的删除只能在电脑上取消。"
            return false
        }
        do {
            state = try await op(client())
            remember(wallsChanged: true)
            return true
        } catch {
            handleRequestError(error)
        }
        return false
    }

    /// 让电脑重新检查每个图库目录能不能访问（结果会随状态推过来）。
    func checkMounts() async {
        guard connection == .live else { return }
        do {
            state = try await client().checkMounts()
            remember()
        } catch {
            handleRequestError(error)
        }
    }

    /// 撤销最近一次移出：放回壁纸文件夹原来的位置。成功时返回放回去的那张的文件名。
    @discardableResult
    func undoRemove() async -> String? {
        // 离线时撤销的是手机上还没补上的「移出」：直接从队列里拿掉、放回列表，不用连电脑
        if offline {
            guard let last = queued.last(where: { $0.kind == .remove }) else { return nil }
            cancelQueued(last, announce: false)
            showNotice("已撤销移出：\(last.name)")
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
        } catch {
            handleRequestError(error)
        }
        return nil
    }

    // MARK: 存原图到相册

    /// 从电脑下载原文件，原样存进相册（不重新编码，保留原分辨率和 EXIF）。
    /// 离线时用手机上存着的那份原图（设置 › 离线 › 保存原图），没存过就只能等连上电脑。
    func saveOriginal(_ w: Wallpaper) async {
        let live = connection == .live
        let cached = ImageStore.cachedOriginal(macID: macID.uuidString, name: w.name)
        guard live || cached != nil else {
            switch connection {
            case .connecting:
                actionError = "正在连接电脑，连接后再试一次。"
            case .offline:
                actionError = "无法连接到电脑，这张原图也没有保存在手机上。可以在「设置 › 离线」中打开「保存原图」并补齐，或连接电脑后再保存。"
            case .unpaired(let msg):
                actionError = msg
            case .live:
                break
            }
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
            // 优先复用手机上已经缓存的原图；没有缓存时在线下载到临时子目录、用完删掉
            var temp: URL?
            let file: URL
            if let cached {
                file = cached
            } else {
                file = try await client().downloadOriginal(w.name)
                temp = file
            }
            defer { if let temp { try? FileManager.default.removeItem(at: temp.deletingLastPathComponent()) } }
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
            noteNetworkFailure(e)
        } catch {
            actionError = "存不进相册：\(error.localizedDescription)"
        }
    }

    func showNotice(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            self.notice = nil
            self.noticeTask = nil
        }
    }

    // MARK: 壁纸与记录缓存

    /// 重新拉壁纸列表（状态里的 walls_rev 变了时自动调；force 时不管变没变都拉，
    /// 补离线操作之前要看电脑上现在有哪些）。返回是否拿到了最新的列表（没变化也算）。
    @discardableResult
    func refreshWalls(force: Bool = false) async -> Bool {
        guard let rev = state?.wallsRev else { return false }
        if !force {
            if let existing = refreshWallsTask { return await existing.value }
            if rev == wallsRev { return true }
        } else {
            // force 需要拿到此刻之后的最新列表：先等上一条在途请求落地，避免并发响应乱序覆写
            while let existing = refreshWallsTask {
                _ = await existing.value
            }
        }
        refreshWallsGen += 1
        let gen = refreshWallsGen
        let t = Task { @MainActor [weak self] () -> Bool in
            guard let self else { return false }
            defer { if self.refreshWallsGen == gen { self.refreshWallsTask = nil } }
            do {
                let list = try await self.client().wallpapers()
                let changed = list.rev != self.wallsRev
                self.walls = list.items
                self.wallsRev = list.rev
                self.heroName = list.hero
                self.remember(wallsChanged: true)
                if changed {
                    // 换了一批：下载中的先停掉，别让属于上一批的图写进来
                    ImageStore.shared.stopForNewBatch()
                }
                // 删掉这台 Mac 目录里不在这批里的缓存，也顺手清掉升级前的根目录旧文件。
                // 要等删完再开始补齐：补齐按总磁盘占用算上限。
                let names = list.items.map(\.name)
                let macID = self.macID.uuidString
                await Task.detached(priority: .utility) { ImageStore.keepOnly(macID: macID, names: names) }.value
                if changed, !self.paused {
                    ImageStore.shared.prefetch(self) // 这一批存到磁盘，离线也能看
                }
                return true
            } catch {
                // 列表拉不到不影响别的，但网络失败或 401 未配对需要同步连接状态
                self.handleRequestError(error, showMessage: false)
                return false
            }
        }
        refreshWallsTask = t
        return await t.value
    }

    /// 连上电脑时把记录页的三份数据（运行日志、删除记录、不再选）各存一份到手机，
    /// 断线时记录页显示的就是这一份，标出是什么时候同步的。
    func refreshRecordsCache() async {
        // 离线时发出去只会干等超时（三路各 30 秒），等连上再说
        guard connection == .live, let client = try? client() else { return }
        let id = macID.uuidString
        let etag = deletionsETag
        async let log: [String]? = try? client.log()
        async let deletions: (list: DeletionList, etag: String?)?? = try? client.deletions(ifNoneMatch: etag)
        async let excluded: [ExcludedItem]? = try? client.excluded()
        if let v = await log { OfflineStore.shared.saveRecord(id, .log, v) }
        if let res = await deletions, let (v, newETag) = res {
            deletionsETag = newETag
            cachedDeletions = v
            OfflineStore.shared.saveRecord(id, .deletions, v)
        }
        if let v = await excluded { OfflineStore.shared.saveRecord(id, .excluded, v) }
    }

    /// 拉取删除记录：命中服务端 ETag（304）时直接复用本地缓存，避免重复传整份日志。
    func fetchDeletions(_ client: APIClient) async throws -> DeletionList {
        if let res = try await client.deletions(ifNoneMatch: deletionsETag) {
            deletionsETag = res.etag
            cachedDeletions = res.list
            OfflineStore.shared.saveRecord(macID.uuidString, .deletions, res.list)
            return res.list
        }
        if let cached = cachedDeletions {
            return cached
        }
        if let disk: OfflineStore.Cached<DeletionList> = await OfflineStore.shared.loadRecord(macID.uuidString, .deletions) {
            cachedDeletions = disk.value
            return disk.value
        }
        // ETag 命中但本地副本已不在，清掉 ETag 全量重拉一次
        deletionsETag = nil
        if let res = try await client.deletions(ifNoneMatch: nil) {
            deletionsETag = res.etag
            cachedDeletions = res.list
            OfflineStore.shared.saveRecord(macID.uuidString, .deletions, res.list)
            return res.list
        }
        return try await client.deletions()
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
    /// refresh 为 false 时先不在本地重新拉列表（多选批量整理时最后只拉一次）；
    /// records 也是这样：批量整理时每张都刷一遍记录缓存，几十张就是几十次三个请求。
    @discardableResult
    func removeWallpaper(_ w: Wallpaper, exclude: Bool, refresh: Bool = true, records: Bool = true) async -> Bool {
        await wallAct(w, kind: exclude ? .exclude : .remove, refresh: refresh, records: records) { try await $0.removeWallpaper(w.name, exclude: exclude) }
    }

    /// 一次整理多张（「全部壁纸」页多选）：在线时逐张调接口、最后拉一次列表；
    /// 离线时合并入队并只写一次盘和快照。返回成功处理或登记的张数。
    @discardableResult
    func removeWallpapers(_ items: [Wallpaper], exclude: Bool) async -> Int {
        guard !items.isEmpty else { return 0 }
        #if DEBUG
        if Self.demoMode != nil {
            let names = Set(items.map(\.name))
            walls.removeAll { names.contains($0.name) }
            return items.count
        }
        #endif
        if offline {
            return enqueueBatch(exclude ? .exclude : .remove, items)
        }
        var done = 0
        for w in items {
            if Task.isCancelled { break }
            guard await removeWallpaper(w, exclude: exclude, refresh: false, records: false) else { break }
            done += 1
        }
        if !offline { await refreshWalls() }
        if done > 0 { Task { await refreshRecordsCache() } }
        return done
    }

    /// 删除图库里的原图（界面上已经二次确认过）。离线时只登记「想删」，
    /// 连上电脑后还要在「设置 › 待处理操作」里再确认一次才真的删——不可撤销，
    /// 不能像「移出」「不再选」那样自动处理。
    @discardableResult
    func deleteOriginal(_ w: Wallpaper) async -> Bool {
        guard w.canDeleteOriginal else { return false }
        guard connection == .live else {
            enqueue(.delete, w)
            return true
        }
        let before = state?.pending ?? 0
        let ok = await wallAct(w, kind: .remove) { try await $0.deleteOriginal(w.name) }
        // 图库没连上：电脑把这次删除排队了，别让手机上看起来像已经删掉
        if ok, (state?.pending ?? 0) > before {
            showNotice("图库未连接，本次删除已排队")
        }
        return ok
    }

    private func wallAct(_ w: Wallpaper, kind: OfflineAction.Kind, refresh: Bool = true, records: Bool = true, _ op: (APIClient) async throws -> RemoteState) async -> Bool {
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
            if records { Task { await refreshRecordsCache() } }
            return true
        } catch {
            handleRequestError(error)
        }
        return false
    }

    private func act(_ op: (APIClient) async throws -> RemoteState) async {
        busy = true
        defer { busy = false }
        do {
            state = try await op(client())
            remember(wallsChanged: true)
        } catch {
            handleRequestError(error)
        }
    }
}
