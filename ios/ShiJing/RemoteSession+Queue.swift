import Foundation

// 离线时记下的整理（「移出」「不再选」）：队列、取消、连上电脑以后逐条补上。
// 和会话本身放一起太长，单独一个扩展；队列存在 UserDefaults 里，按 Mac 分开。
extension RemoteSession {
    // MARK: 离线时记下的整理（连上后补上）

    /// 离线时点的一张整理操作：「移出」「不再选」连上后自动处理；
    /// 「删除原图」不可撤销，连上后还要用户再确认一次才真的删。
    /// `wall` / `index` 用来在取消时把那张放回列表原来的位置（旧版本记下的没有，只能取消、放不回去）。
    typealias OfflineAction = OfflineQueueAction

    var offline: Bool { connection != .live }

    /// 队列里等着用户确认的「删除原图」（连上电脑后才做，逐张或全部确认）。
    var queuedDeletes: [OfflineAction] { queued.filter { $0.kind == .delete } }

    /// 撤销按钮显示的名字：在线时是电脑上最近一次移出；离线时是手机上最近一条还没补上的「移出」。
    var undoName: String? {
        if offline { return queued.last { $0.kind == .remove }?.name }
        return state?.undoName
    }

    #if DEBUG
    /// 截图用（-demo -demoOffline）：塞三条离线操作，看提示、「待处理操作」和待确认删除是什么样
    func seedQueuedForDemo() {
        guard queued.isEmpty, walls.count > 7 else { return }
        let r = walls[2]
        let e = walls[4]
        let d = walls[6]
        walls.remove(at: 6) // 和真的离线操作一样：三种都会从列表里去掉
        walls.remove(at: 4)
        walls.remove(at: 2)
        queued = [
            OfflineAction(kind: .remove, name: r.name, source: r.source, wall: r, index: 2, rev: "demo"),
            OfflineAction(kind: .exclude, name: e.name, source: e.source, wall: e, index: 4, rev: "demo"),
            OfflineAction(kind: .delete, name: d.name, source: d.source, wall: d, index: 6, rev: "demo"),
        ]
    }
    #endif

    nonisolated static func queueKey(_ id: String) -> String { "offlineActions." + id }

    /// 删掉这台 Mac 还没补上的离线操作（在 MacStore 里移除它时调用）。
    nonisolated static func clearQueue(_ id: SavedMac.ID) {
        UserDefaults.standard.removeObject(forKey: queueKey(id.uuidString))
    }

    static func loadQueue(_ id: String) -> [OfflineAction] {
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

    func enqueue(_ kind: OfflineAction.Kind, _ w: Wallpaper) {
        guard OfflineQueueLogic.enqueue(kind, wall: w, walls: &walls, queued: &queued, rev: wallsRev) else { return }
        saveQueue()
        remember(wallsChanged: true)
        switch kind {
        case .exclude: showNotice("已记录，连接电脑后移出并不再选它。")
        case .remove: showNotice("已记录，连接电脑后移出。")
        case .delete: showNotice("已记录，连接电脑后确认再删除原图。")
        }
    }

    /// 批量记下多张离线整理：一次入队、一次写盘和快照（避免多选几十张时反复编码整个队列与壁纸列表）。
    @discardableResult
    func enqueueBatch(_ kind: OfflineAction.Kind, _ items: [Wallpaper]) -> Int {
        guard !items.isEmpty else { return 0 }
        let added = OfflineQueueLogic.enqueueBatch(kind, items: items, walls: &walls, queued: &queued, rev: wallsRev)
        if added { saveQueue() }
        remember(wallsChanged: true)
        return items.count
    }

    /// 取消一条还没补上的离线操作，那张放回列表原来的位置。
    /// 「不再选」「删除原图」在电脑上也会把那张从壁纸文件夹移出，所以离线时三种都先从列表里去掉了，取消后都要放回去。
    func cancelQueued(_ a: OfflineAction, announce: Bool = true) {
        let res = OfflineQueueLogic.cancel(id: a.id, walls: &walls, queued: &queued)
        guard res.removed != nil else { return }
        saveQueue()
        remember(wallsChanged: true)
        if announce {
            showNotice(res.restored ? "已取消，放回列表：\(a.name)" : "已取消：\(a.name)")
        }
    }

    /// 全部取消：记下的操作都撤回，「移出 / 不再选」的那张放回列表。
    func cancelAllQueued() {
        let count = OfflineQueueLogic.cancelAll(walls: &walls, queued: &queued)
        guard count > 0 else { return }
        saveQueue()
        remember(wallsChanged: true)
        showNotice("已取消 \(count) 项离线操作")
    }

    /// 连上以后把离线时记下的「移出」「不再选」补上。
    ///
    /// 「删除原图」不在这里补：不可撤销，要等用户在「待处理操作」里确认（confirmQueuedDelete）。
    /// 注意不能拿手机上的列表判断「那张还在不在这一批」：离线记下时已经把它从本地列表去掉了，
    /// 所以先强制拉一份电脑上现在的列表——还在这一批的「不再选」照在线的做法走移出 + 加名单，
    /// 已经换掉的就只按原图路径加进名单。「移出」直接调接口，电脑返回 409（已经不在这批）才算过期。
    func flushOfflineActions() async {
        guard !flushing, queued.contains(where: { $0.kind != .delete }), connection == .live else { return }
        flushing = true
        defer { flushing = false }
        // 先拉一份电脑上现在的列表，拉不到（这一下连不上）就整轮都不动，等下次
        guard await refreshWalls(force: true) else { return }
        var applied = 0
        var expired = 0
        // 一条一条消费：发请求期间保留持久化记录，服务端确认处理或返回过期后再从队列移除。
        // 这样重放途中进程被挂起、强杀或断网时，未确认的条目仍在磁盘上不会丢失；
        // 若等待期间用户手动取消了某条，removeQueued(act.id) 幂等跳过。
        while let act = queued.first(where: { $0.kind != .delete }) {
            do {
                switch act.kind {
                case .exclude:
                    var moved = false
                    var excluded = false
                    if walls.contains(where: { $0.name == act.name }) {
                        do {
                            // 和在线时一样：从壁纸文件夹移出，并加进不再选
                            state = try await client().removeWallpaper(act.name, exclude: true)
                            moved = true
                            excluded = true
                        } catch APIError.server(_, let msg) where msg.contains("找不到原图") {
                            // 旧版本换上的没有原图记录：只能移出，名单按手机记下的原图路径补
                            state = try await client().removeWallpaper(act.name, exclude: false)
                            moved = true
                        } catch APIError.server(let status, let msg)
                            where (status == 404 || status == 409) && !msg.contains("正在换壁纸") {
                            // 刚拉完列表电脑上又没了（或者已经换了一批）：移出这一步不用做了，
                            // 但「不再选」和批次无关，下面照样按原图路径补进名单
                        }
                        // 「正在换壁纸」上面不接，交给外层保留队列、换完一批再补
                        walls.removeAll { $0.name == act.name }
                    }
                    if !excluded, let src = act.source, !src.isEmpty {
                        // 这一批已经换掉了（或者刚才是只能移出）：至少把原图记进名单，和批次无关
                        let list = try await client().addExcluded([src])
                        state?.excluded = list.count // 概览上的名单张数别停在旧值
                        excluded = true
                    }
                    removeQueued(act.id)
                    if moved || excluded {
                        applied += 1
                    } else {
                        expired += 1
                    }
                case .remove:
                    state = try await client().removeWallpaper(act.name, exclude: false)
                    walls.removeAll { $0.name == act.name }
                    removeQueued(act.id)
                    applied += 1
                case .delete:
                    break // 上面 while 已经跳过了，这里是给编译器看全的
                }
            } catch APIError.server(_, let msg) where msg.contains("正在换壁纸") {
                // 电脑在忙，不是过期：保留在队列里，换完一批时再补
                break
            } catch APIError.server(let status, _) where status == 404 || status == 409 {
                removeQueued(act.id)
                expired += 1
            } catch APIError.unauthorized(let msg) {
                markUnpaired(msg)
                break
            } catch {
                // 又断了：保留在队列里，留着下次
                noteNetworkFailure(error)
                break
            }
        }
        if applied > 0 {
            remember(wallsChanged: true)
            Task { await refreshRecordsCache() } // 「不再选」的名单变了
        }
        var msg = ""
        if applied == 0, expired > 0 {
            msg = "\(expired) 项离线操作已经失效，那一批壁纸换掉了"
        } else if applied > 0 {
            msg = expired > 0 ? "已处理 \(applied) 项离线操作，\(expired) 项已经失效" : "已处理 \(applied) 项离线操作"
        }
        // 删除原图不自动补：提醒去「待处理操作」里确认
        if !queuedDeletes.isEmpty {
            msg += (msg.isEmpty ? "" : "；") + "有 \(queuedDeletes.count) 张原图等你确认删除"
        }
        if !msg.isEmpty { showNotice(msg) }
    }

    enum QueuedDeleteResult { case deleted, queued, expired, cancelled }

    /// 电脑正在换壁纸时不能删原图。拦下时顺手写好提示。
    private func blockedByRun() -> Bool {
        guard state?.running == true else { return false }
        actionError = "正在更换壁纸，等更换完成后再删除"
        return true
    }

    /// 用户在「待处理操作」里确认了离线时记下的「删除原图」：删之前会先拉一份电脑上现在的列表。
    /// 那张已经不在这一批里的：接口只能按壁纸名删，没法再删图库里的原图，只能告诉用户去电脑上删。
    /// `refresh` 为 false 时先不拉列表（批量确认时外面已经拉过一次）。
    @discardableResult
    func confirmQueuedDelete(_ a: OfflineAction, refresh: Bool = true) async -> QueuedDeleteResult {
        guard connection == .live, a.kind == .delete,
              queued.contains(where: { $0.id == a.id }) else { return .cancelled }
        guard !blockedByRun() else { return .queued }
        // 离线记下时已经把那张从本地列表去掉了，要先拉一份电脑上现在的列表才知道它还在不在这一批
        if refresh, !(await refreshWalls(force: true)) {
            actionError = "无法连接到电脑，这张先保留，下次再确认"
            return .queued
        }
        guard queued.contains(where: { $0.id == a.id }) else { return .cancelled } // 拉列表期间被取消
        guard walls.contains(where: { $0.name == a.name }) else {
            removeQueued(a.id)
            actionError = "「\(a.name)」已经不在这一批壁纸里，原图没有删除。需要的话在电脑上删。"
            return .expired
        }
        let before = state?.pending ?? 0
        do {
            let s = try await client().deleteOriginal(a.name)
            state = s
            removeQueued(a.id)
            walls.removeAll { $0.name == a.name }
            remember(wallsChanged: true)
            if (s.pending ?? 0) > before {
                showNotice("图库未连接，本次删除已排队")
            } else {
                showNotice("已删除原图：\(a.name)")
            }
            Task { await refreshRecordsCache() }
            if refresh { await refreshWalls() }
            return .deleted
        } catch APIError.server(_, let msg) where msg.contains("正在换壁纸") {
            actionError = msg
            return .queued
        } catch APIError.server(let status, let msg) where status == 404 || status == 409 {
            removeQueued(a.id)
            actionError = msg
            return .expired
        } catch APIError.unauthorized(let msg) {
            markUnpaired(msg)
            return .queued
        } catch {
            actionError = Self.describe(error)
            noteNetworkFailure(error)
            return .queued
        }
    }

    /// 一次确认所有还没删的原图（界面上已经弹框确认过）。
    func confirmAllQueuedDeletes() async {
        guard connection == .live else { return }
        guard !blockedByRun() else { return }
        let items = queuedDeletes
        guard !items.isEmpty else { return }
        guard await refreshWalls(force: true) else {
            actionError = "无法连接到电脑，先不删除，下次再确认"
            return
        }
        var deleted = 0, expired = 0, left = 0
        for a in items {
            switch await confirmQueuedDelete(a, refresh: false) {
            case .deleted: deleted += 1
            case .expired: expired += 1
            case .queued: left += 1
            case .cancelled: break
            }
            if connection != .live { break } // 断了就停，剩下的留着
        }
        guard deleted > 0 || expired > 0 else { return }
        await refreshWalls() // 批量删完把列表、walls_rev 和电脑对齐
        var msg = "已删除 \(deleted) 张原图"
        if expired > 0 { msg += "，\(expired) 张已不在这一批，跳过" }
        if left > 0 { msg += "，\(left) 张先留着" }
        showNotice(msg)
        Task { await refreshRecordsCache() }
    }

    private func removeQueued(_ id: UUID) {
        queued.removeAll { $0.id == id }
        saveQueue()
    }
}
