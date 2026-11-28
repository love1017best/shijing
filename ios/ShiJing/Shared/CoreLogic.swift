import Foundation

/// 离线时记下的一条壁纸整理操作：「移出」「不再选」连上后自动补上；
/// 「删除原图」不可撤销，连上后仍需用户在界面上确认。
struct OfflineQueueAction: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case remove, exclude, delete }
    var id = UUID()
    var kind: Kind
    var name: String
    var source: String?
    var at = Date()
    var wall: Wallpaper?
    var index: Int?
    /// 记下时属于哪一批（缩略图 / 大图预览按这个 rev 找缓存；旧队列没有，退回当前批次）
    var rev: String?
}

/// 离线操作队列的纯状态演进逻辑（去重、批量合并、撤销放回原位）。
enum OfflineQueueLogic {
    /// 单条入队：同文件名同操作去重；未重复时记下原下标并从 `walls` 中移除。返回是否实际入队。
    @discardableResult
    static func enqueue(
        _ kind: OfflineQueueAction.Kind,
        wall: Wallpaper,
        walls: inout [Wallpaper],
        queued: inout [OfflineQueueAction],
        rev: String?
    ) -> Bool {
        guard !queued.contains(where: { $0.name == wall.name && $0.kind == kind }) else { return false }
        let index = walls.firstIndex { $0.name == wall.name }
        queued.append(OfflineQueueAction(
            kind: kind,
            name: wall.name,
            source: wall.source,
            wall: wall,
            index: index,
            rev: rev
        ))
        walls.removeAll { $0.name == wall.name }
        return true
    }

    /// 批量入队：一次性计算原下标、按 `(name, kind)` 去重并从 `walls` 移除。返回是否有新条目加入。
    @discardableResult
    static func enqueueBatch(
        _ kind: OfflineQueueAction.Kind,
        items: [Wallpaper],
        walls: inout [Wallpaper],
        queued: inout [OfflineQueueAction],
        rev: String?
    ) -> Bool {
        guard !items.isEmpty else { return false }
        var existing = Set(queued.filter { $0.kind == kind }.map(\.name))
        let indexByName = Dictionary(
            walls.enumerated().map { ($0.element.name, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        var removed = Set<String>()
        var added = false
        for w in items {
            removed.insert(w.name)
            guard existing.insert(w.name).inserted else { continue }
            queued.append(OfflineQueueAction(
                kind: kind,
                name: w.name,
                source: w.source,
                wall: w,
                index: indexByName[w.name],
                rev: rev
            ))
            added = true
        }
        walls.removeAll { removed.contains($0.name) }
        return added
    }

    /// 把单条离线操作对应的壁纸放回原下标位置（若已在列表中或缺少快照则返回 false）。
    @discardableResult
    static func restore(_ action: OfflineQueueAction, into walls: inout [Wallpaper]) -> Bool {
        guard let w = action.wall, !walls.contains(where: { $0.name == w.name }) else { return false }
        walls.insert(w, at: min(max(action.index ?? walls.count, 0), walls.count))
        return true
    }

    /// 取消单条离线操作并尝试放回列表。返回 `(removed, restored)`。
    static func cancel(
        id: OfflineQueueAction.ID,
        walls: inout [Wallpaper],
        queued: inout [OfflineQueueAction]
    ) -> (removed: OfflineQueueAction?, restored: Bool) {
        guard let idx = queued.firstIndex(where: { $0.id == id }) else { return (nil, false) }
        let act = queued.remove(at: idx)
        let restored = restore(act, into: &walls)
        return (act, restored)
    }

    /// 全部取消：按原下标从小到大放回列表，保证后续元素下标对齐。返回取消条数。
    @discardableResult
    static func cancelAll(
        walls: inout [Wallpaper],
        queued: inout [OfflineQueueAction]
    ) -> Int {
        guard !queued.isEmpty else { return 0 }
        let list = queued
        queued = []
        for a in list.sorted(by: { ($0.index ?? 0) < ($1.index ?? 0) }) {
            restore(a, into: &walls)
        }
        return list.count
    }
}

/// 离线图片缓存淘汰判断：找出不属于当前批次的旧缓存文件名。
enum ImageCachePruner {
    /// 从目录现有文件名列表 `fileNames` 中筛出需要删除的文件名。
    /// `prefixes` 为各档缓存前缀（如 `["thumb-", "image-", "orig-"]`），`keepSafeNames` 为本批已安全转义的文件名集合。
    static func staleFileNames(
        in fileNames: [String],
        prefixes: [String],
        keepSafeNames: Set<String>
    ) -> [String] {
        fileNames.filter { file in
            if let prefix = prefixes.first(where: { file.hasPrefix($0) }),
               keepSafeNames.contains(String(file.dropFirst(prefix.count))) {
                return false
            }
            return true
        }
    }
}

/// 小组件缓存池清理规则：按像素档位独立配额、过期时间与非法档位计算待删除文件。
enum WidgetCachePruner {
    struct Entry: Equatable {
        let name: String
        let mtime: Date
    }

    /// 返回应当删除的文件名集合（不含目录路径）。
    static func namesToRemove(
        entries: [Entry],
        keep: Int,
        activeStateName: String?,
        online: Bool,
        now: Date,
        minPx: Int,
        maxPx: Int,
        maxAge: TimeInterval = 7 * 86400
    ) -> [String] {
        var remove: [String] = []
        var byPx: [Int: [Entry]] = [:]
        for e in entries {
            let name = e.name
            if name.hasPrefix("state-"), name.hasSuffix(".json") {
                if online, name != activeStateName, now.timeIntervalSince(e.mtime) > maxAge {
                    remove.append(name)
                }
                continue
            }
            guard name.hasPrefix("img-") else { continue }
            let stem = (name as NSString).deletingPathExtension
            let px = Int(stem.split(separator: "-").last ?? "") ?? 0
            if px < minPx || px > maxPx {
                remove.append(name)
                continue
            }
            if online, now.timeIntervalSince(e.mtime) > maxAge {
                remove.append(name)
                continue
            }
            byPx[px, default: []].append(e)
        }
        let quota = max(0, keep)
        for group in byPx.values {
            for e in group.sorted(by: { $0.mtime > $1.mtime }).dropFirst(quota) {
                remove.append(e.name)
            }
        }
        return remove
    }
}

/// SSE 断线重连退避算法。
enum ReconnectBackoff {
    /// 前几次 15 秒内快速重试；连续失败 8 次以上放宽到 60 秒以省电。
    static func nextDelay(current: Double, failures: Int) -> Double {
        min(current * 2, failures >= 8 ? 60 : 15)
    }
}

/// 幻灯片模式的纯业务规则（切图顺序、循环步进候选、间隔轮换、填充方式与文案格式），
/// 独立于 SwiftUI 视图层，供 `SlideshowView` 与单元测试复用。
enum SlideshowLogic {
    static let intervals = [5, 10, 20, 30, 60]
    static let defaultInterval = 10

    /// 规范化切图间隔：不在预设列表时退回默认值 10 秒。
    static func normalizedInterval(_ sec: Int) -> Int {
        intervals.contains(sec) ? sec : defaultInterval
    }

    /// 按预设挡位循环切到下一个间隔；当前值不在列表里时回到第一档。
    static func nextInterval(after sec: Int) -> Int {
        guard let idx = intervals.firstIndex(of: sec) else { return intervals[0] }
        return intervals[(idx + 1) % intervals.count]
    }

    /// 间隔按钮的简短文案（如「10秒」「1分」）。
    static func intervalLabel(_ sec: Int) -> String {
        if sec >= 60 && sec % 60 == 0 { return "\(sec / 60)分" }
        return "\(sec)秒"
    }

    /// 填充方式判定：0 = 自动（横屏铺满、竖屏完整），1 = 始终铺满，2 = 始终完整。
    static func shouldFill(fitMode: Int, isLandscape: Bool) -> Bool {
        switch fitMode {
        case 1: return true
        case 2: return false
        default: return isLandscape
        }
    }

    /// 双击或点切换按钮时在「铺满(1)」与「完整(2)」之间翻转。
    static func toggledFitMode(currentlyFilled: Bool) -> Int {
        currentlyFilled ? 2 : 1
    }

    /// 生成随机播放顺序：关闭随机时返回空；开启时洗牌并把 `keeping` 换到第 0 位，保证切随机不跳图。
    static func buildOrder(
        all: [String],
        shuffle: Bool,
        keeping current: String,
        shuffler: ([String]) -> [String] = { $0.shuffled() }
    ) -> [String] {
        guard shuffle, !all.isEmpty else { return [] }
        var next = shuffler(all)
        if let i = next.firstIndex(of: current), i > 0 {
            next.swapAt(0, i)
        }
        return next
    }

    /// 当前生效的播放列表：顺序模式用 `all`，随机模式优先用已生成的 `order`。
    static func activeList(all: [String], shuffle: Bool, order: [String]) -> [String] {
        if !shuffle { return all }
        return order.isEmpty ? all : order
    }

    /// 计算沿 `delta`（+1 下一张 / -1 上一张）步进时依次尝试加载的候选文件名列表。
    /// 最多返回 `min(maxTries, list.count - 1)` 个，离线遇到未缓存图片时按序跳过。
    static func stepCandidates(
        in list: [String],
        current: String,
        delta: Int,
        maxTries: Int = 12
    ) -> [String] {
        let count = list.count
        guard count > 1, delta != 0, maxTries > 0 else { return [] }
        let start = list.firstIndex(of: current) ?? 0
        let limit = min(maxTries, count - 1)
        var out: [String] = []
        out.reserveCapacity(limit)
        for offset in 1...limit {
            let raw = (start + delta * offset) % count
            let idx = raw >= 0 ? raw : raw + count
            out.append(list[idx])
        }
        return out
    }

    /// 返回下一张待预取的文件名（列表不足 2 张或找不到当前项时返回 nil）。
    static func nextName(in list: [String], after current: String) -> String? {
        guard list.count > 1, let idx = list.firstIndex(of: current) else { return nil }
        return list[(idx + 1) % list.count]
    }

    /// 去掉文件扩展名用于信息卡展示；无扩展名或去完为空时保留原名。
    static func displayTitle(_ name: String) -> String {
        let stem = (name as NSString).deletingPathExtension
        return stem.isEmpty ? name : stem
    }

    /// 中文月日与星期格式（如「11月28日 周六」）。
    static func dateText(_ date: Date, calendar: Calendar = .current) -> String {
        let m = calendar.component(.month, from: date)
        let d = calendar.component(.day, from: date)
        let wd = calendar.component(.weekday, from: date)
        let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        let w = (1...7).contains(wd) ? names[wd - 1] : ""
        return "\(m)月\(d)日 \(w)"
    }
}
