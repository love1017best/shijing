import Foundation

// 离线时记下的整理（「移出」「不再选」）：队列、取消、连上电脑以后逐条补上。
// 和会话本身放一起太长，单独一个扩展；队列存在 UserDefaults 里，按 Mac 分开。
extension RemoteSession {
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
        let e = walls[4]
        walls.remove(at: 4) // 和真的离线操作一样：两种都会从列表里去掉
        walls.remove(at: 2)
        queued = [
            OfflineAction(kind: .remove, name: r.name, source: r.source, wall: r, index: 2),
            OfflineAction(kind: .exclude, name: e.name, source: e.source, wall: e, index: 4),
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
        // 本地先去掉，界面跟着变；连上电脑后再真的移出
        walls.removeAll { $0.name == w.name }
        remember(wallsChanged: true)
        notice = kind == .exclude ? "已记下：连上电脑后移出并不再选它" : "已记下：连上电脑后移出"
    }

    /// 取消一条还没补上的离线操作，那张放回列表原来的位置。
    /// 「不再选」在电脑上也会把那张从壁纸文件夹移出，所以离线时两种都先从列表里去掉了，取消后都要放回去。
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

    /// 连上以后把离线时记下的操作补上。
    ///
    /// 注意不能拿手机上的列表判断「那张还在不在这一批」：离线记下时已经把它从本地列表去掉了，
    /// 所以先强制拉一份电脑上现在的列表——还在这一批的「不再选」照在线的做法走移出 + 加名单，
    /// 已经换掉的就只按原图路径加进名单。「移出」直接调接口，电脑返回 409（已经不在这批）才算过期。
    func flushOfflineActions() async {
        guard !flushing, !queued.isEmpty, connection == .live else { return }
        flushing = true
        defer { flushing = false }
        await refreshWalls(force: true)
        var applied = 0
        var expired = 0
        // 一条一条消费：补之前先从队列里摘掉（设置页的「待补操作」跟着变），补不成再放回队首。
        // 不能开头拍一份快照、结束时整体写回——这一路都在 await，用户可能正在点「取消」，
        // 那样被取消的条目会被写回队列，或者本地放回了电脑上已经移出的图。
        while let act = queued.first {
            queued.removeFirst()
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
                        _ = try await client().addExcluded([src])
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
                }
            } catch APIError.server(_, let msg) where msg.contains("正在换壁纸") {
                // 电脑在忙，不是过期：放回队首，换完一批时再补
                queued.insert(act, at: 0)
                saveQueue()
                break
            } catch APIError.server(let status, _) where status == 404 || status == 409 {
                expired += 1
            } catch APIError.unauthorized(let msg) {
                connection = .unpaired(msg)
                queued.insert(act, at: 0)
                saveQueue()
                break
            } catch {
                // 又断了：放回队首，留着下次
                queued.insert(act, at: 0)
                saveQueue()
                break
            }
        }
        if applied > 0 {
            remember(wallsChanged: true)
            Task { await refreshRecordsCache() } // 「不再选」的名单变了
        }
        if applied == 0, expired > 0 {
            notice = "\(expired) 项离线操作已经过期（那一批壁纸换掉了）"
        } else if applied > 0 {
            notice = expired > 0 ? "已补上 \(applied) 项离线操作，\(expired) 项已经过期" : "已补上 \(applied) 项离线操作"
        }
    }
}
