import Foundation

// 离线时记下的整理（「移出」「不再选」）：队列、取消、连上电脑以后逐条补上。
// 和会话本身放一起太长，单独一个扩展；队列存在 UserDefaults 里，按 Mac 分开。
extension RemoteSession {
    // MARK: 离线时记下的整理（连上后补上）

    /// 离线时点的一张整理操作：「移出」「不再选」连上后自动补上；
    /// 「删除原图」不可撤销，连上后还要用户再确认一次才真的删。
    /// `wall` / `index` 用来在取消时把那张放回列表原来的位置（旧版本记下的没有，只能取消、放不回去）。
    struct OfflineAction: Codable, Identifiable, Equatable {
        enum Kind: String, Codable { case remove, exclude, delete }
        var id = UUID()
        var kind: Kind
        var name: String
        var source: String?
        var at = Date()
        var wall: Wallpaper?
        var index: Int?
    }

    var offline: Bool { connection != .live }

    /// 队列里等着用户确认的「删除原图」（连上电脑后才做，逐张或全部确认）。
    var queuedDeletes: [OfflineAction] { queued.filter { $0.kind == .delete } }

    /// 撤销按钮显示的名字：在线时是电脑上最近一次移出；离线时是手机上最近一条还没补上的「移出」。
    var undoName: String? {
        if offline { return queued.last { $0.kind == .remove }?.name }
        return state?.undoName
    }

    #if DEBUG
    /// 截图用（-demo -demoOffline）：塞三条离线操作，看提示、「待补操作」和待确认删除是什么样
    func seedQueuedForDemo() {
        guard queued.isEmpty, walls.count > 7 else { return }
        let r = walls[2]
        let e = walls[4]
        let d = walls[6]
        walls.remove(at: 6) // 和真的离线操作一样：三种都会从列表里去掉
        walls.remove(at: 4)
        walls.remove(at: 2)
        queued = [
            OfflineAction(kind: .remove, name: r.name, source: r.source, wall: r, index: 2),
            OfflineAction(kind: .exclude, name: e.name, source: e.source, wall: e, index: 4),
            OfflineAction(kind: .delete, name: d.name, source: d.source, wall: d, index: 6),
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
        guard !queued.contains(where: { $0.name == w.name && $0.kind == kind }) else { return }
        let index = walls.firstIndex { $0.name == w.name }
        queued.append(OfflineAction(kind: kind, name: w.name, source: w.source, wall: w, index: index))
        saveQueue()
        // 本地先去掉，界面跟着变；连上电脑后再真的移出 / 删除
        walls.removeAll { $0.name == w.name }
        remember(wallsChanged: true)
        switch kind {
        case .exclude: notice = "已记下：连上电脑后移出并不再选它"
        case .remove: notice = "已记下：连上电脑后移出"
        case .delete: notice = "已记下：连上电脑后确认再删除原图"
        }
    }

    /// 取消一条还没补上的离线操作，那张放回列表原来的位置。
    /// 「不再选」「删除原图」在电脑上也会把那张从壁纸文件夹移出，所以离线时三种都先从列表里去掉了，取消后都要放回去。
    func cancelQueued(_ a: OfflineAction, announce: Bool = true) {
        guard queued.contains(where: { $0.id == a.id }) else { return }
        queued.removeAll { $0.id == a.id }
        saveQueue()
        let back = restore(a)
        remember(wallsChanged: true)
        if announce {
            notice = back ? "已取消，放回列表：\(a.name)" : "已取消：\(a.name)"
        }
    }

    /// 全部取消：记下的操作都撤回，「移出 / 不再选」的那张放回列表。
    func cancelAllQueued() {
        guard !queued.isEmpty else { return }
        let list = queued
        queued = []
        saveQueue()
        // 按原来的位置从小到大放回去，后面的下标才对得上
        for a in list.sorted(by: { ($0.index ?? 0) < ($1.index ?? 0) }) {
            restore(a)
        }
        remember(wallsChanged: true)
        notice = "已取消 \(list.count) 项离线操作"
    }

    @discardableResult
    private func restore(_ a: OfflineAction) -> Bool {
        guard let w = a.wall, !walls.contains(where: { $0.name == w.name }) else { return false }
        walls.insert(w, at: min(max(a.index ?? walls.count, 0), walls.count))
        return true
    }

    /// 连上以后把离线时记下的「移出」「不再选」补上。
    ///
    /// 「删除原图」不在这里补：不可撤销，要等用户在「待补操作」里确认（confirmQueuedDelete）。
    /// 注意不能拿手机上的列表判断「那张还在不在这一批」：离线记下时已经把它从本地列表去掉了，
    /// 所以先强制拉一份电脑上现在的列表——还在这一批的「不再选」照在线的做法走移出 + 加名单，
    /// 已经换掉的就只按原图路径加进名单。「移出」直接调接口，电脑返回 409（已经不在这批）才算过期。
    func flushOfflineActions() async {
        guard !flushing, queued.contains(where: { $0.kind != .delete }), connection == .live else { return }
        flushing = true
        defer { flushing = false }
        await refreshWalls(force: true)
        var applied = 0
        var expired = 0
        // 一条一条消费：补之前先从队列里摘掉（设置页的「待补操作」跟着变），补不成再放回原处。
        // 不能开头拍一份快照、结束时整体写回——这一路都在 await，用户可能正在点「取消」，
        // 那样被取消的条目会被写回队列，或者本地放回了电脑上已经移出的图。
        while let i = queued.firstIndex(where: { $0.kind != .delete }) {
            let act = queued[i]
            queued.remove(at: i)
            saveQueue()
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
                        }
                        walls.removeAll { $0.name == act.name }
                    }
                    if !excluded, let src = act.source, !src.isEmpty {
                        // 这一批已经换掉了（或者刚才是只能移出）：至少把原图记进名单，和批次无关
                        let list = try await client().addExcluded([src])
                        state?.excluded = list.count // 概览上的名单张数别停在旧值
                        excluded = true
                    }
                    if moved || excluded {
                        applied += 1
                    } else {
                        expired += 1
                    }
                case .remove:
                    state = try await client().removeWallpaper(act.name, exclude: false)
                    walls.removeAll { $0.name == act.name }
                    applied += 1
                case .delete:
                    break // 上面 while 已经跳过了，这里是给编译器看全的
                }
            } catch APIError.server(_, let msg) where msg.contains("正在换壁纸") {
                // 电脑在忙，不是过期：放回原处，换完一批时再补
                queued.insert(act, at: min(i, queued.count))
                saveQueue()
                break
            } catch APIError.server(let status, _) where status == 404 || status == 409 {
                expired += 1
            } catch APIError.unauthorized(let msg) {
                connection = .unpaired(msg)
                queued.insert(act, at: min(i, queued.count))
                saveQueue()
                break
            } catch {
                // 又断了：放回原处，留着下次
                queued.insert(act, at: min(i, queued.count))
                saveQueue()
                break
            }
        }
        if applied > 0 {
            remember(wallsChanged: true)
            Task { await refreshRecordsCache() } // 「不再选」的名单变了
        }
        var msg = ""
        if applied == 0, expired > 0 {
            msg = "\(expired) 项离线操作已经过期（那一批壁纸换掉了）"
        } else if applied > 0 {
            msg = expired > 0 ? "已补上 \(applied) 项离线操作，\(expired) 项已经过期" : "已补上 \(applied) 项离线操作"
        }
        // 删除原图不自动补：提醒去「待补操作」里确认
        if !queuedDeletes.isEmpty {
            msg += (msg.isEmpty ? "" : "；") + "\(queuedDeletes.count) 张原图等你确认删除"
        }
        if !msg.isEmpty { notice = msg }
    }

    enum QueuedDeleteResult { case deleted, queued, expired, cancelled }

    /// 用户在「待补操作」里确认了离线时记下的「删除原图」：删之前会先拉一份电脑上现在的列表。
    /// 那张已经不在这一批里的：接口只能按壁纸名删，没法再删图库里的原图，只能告诉用户去电脑上删。
    /// `refresh` 为 false 时先不拉列表（批量确认时外面已经拉过一次）。
    @discardableResult
    func confirmQueuedDelete(_ a: OfflineAction, refresh: Bool = true) async -> QueuedDeleteResult {
        guard connection == .live, a.kind == .delete,
              queued.contains(where: { $0.id == a.id }) else { return .cancelled }
        guard state?.running != true else {
            actionError = "正在换壁纸，等换完再删"
            return .queued
        }
        // 离线记下时已经把那张从本地列表去掉了，要先拉一份电脑上现在的列表才知道它还在不在这一批
        if refresh, !(await refreshWalls(force: true)) {
            actionError = "连不上电脑，这张先留着，下次再确认"
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
                showNotice("图库没连上，这次删除已排队")
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
            connection = .unpaired(msg)
            return .queued
        } catch {
            actionError = Self.describe(error)
            return .queued
        }
    }

    /// 一次确认所有还没删的原图（界面上已经弹框确认过）。
    func confirmAllQueuedDeletes() async {
        guard connection == .live, state?.running != true else {
            if state?.running == true { actionError = "正在换壁纸，等换完再删" }
            return
        }
        let items = queuedDeletes
        guard !items.isEmpty else { return }
        guard await refreshWalls(force: true) else {
            actionError = "连不上电脑，先不删，下次再确认"
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
