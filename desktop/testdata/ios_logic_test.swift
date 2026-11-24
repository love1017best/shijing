import Foundation

// iOS 端核心纯逻辑单元测试驱动（Models.swift / CoreLogic.swift）。
// 由 desktop/ios_logic_test.go 通过 swiftc 编译并执行，覆盖离线队列、图片缓存淘汰、小组件缓存池清理与重连退避。

private struct TestFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

private func expect(_ cond: @autoclosure () -> Bool, _ msg: String, file: StaticString = #file, line: UInt = #line) throws {
    if !cond() {
        throw TestFailure(message: "[\(file):\(line)] \(msg)")
    }
}

private func makeWall(_ name: String, source: String? = nil, sampleOnly: Bool? = nil) -> Wallpaper {
    Wallpaper(name: name, source: source ?? "/Volumes/Media0/\(name)", sampleOnly: sampleOnly)
}

private func testOfflineQueueSingleAndDedup() throws {
    var walls = [makeWall("a.jpg"), makeWall("b.jpg"), makeWall("c.jpg")]
    var queued: [OfflineQueueAction] = []

    let ok1 = OfflineQueueLogic.enqueue(.exclude, wall: walls[1], walls: &walls, queued: &queued, rev: "rev-1")
    try expect(ok1, "首次入队应返回 true")
    try expect(walls.map(\.name) == ["a.jpg", "c.jpg"], "入队后应从壁纸列表移除")
    try expect(queued.count == 1 && queued[0].index == 1 && queued[0].rev == "rev-1", "应记下原下标和批次号")

    // 同文件名同操作去重
    let dup = OfflineQueueLogic.enqueue(.exclude, wall: makeWall("b.jpg"), walls: &walls, queued: &queued, rev: "rev-1")
    try expect(!dup, "重复的 (name, kind) 应被去重")
    try expect(queued.count == 1, "去重后队列长度不变")

    // 同文件名不同操作允许入队
    let diffKind = OfflineQueueLogic.enqueue(.delete, wall: makeWall("b.jpg"), walls: &walls, queued: &queued, rev: "rev-1")
    try expect(diffKind, "同文件名不同操作允许入队")
    try expect(queued.count == 2, "队列应有 2 条")

    // 取消第一条，应放回下标 1
    let firstID = queued[0].id
    let cancelRes = OfflineQueueLogic.cancel(id: firstID, walls: &walls, queued: &queued)
    try expect(cancelRes.removed?.name == "b.jpg" && cancelRes.restored, "取消后应放回原位置")
    try expect(walls.map(\.name) == ["a.jpg", "b.jpg", "c.jpg"], "恢复后的列表顺序应与初始一致")

    // 再次取消同文件名的第二条：b.jpg 已在列表里，不应重复插入
    let secondID = queued[0].id
    let cancelRes2 = OfflineQueueLogic.cancel(id: secondID, walls: &walls, queued: &queued)
    try expect(cancelRes2.removed?.name == "b.jpg" && !cancelRes2.restored, "已在列表中时不应重复插入")
    try expect(walls.map(\.name) == ["a.jpg", "b.jpg", "c.jpg"], "列表不应出现重复项")
}

private func testOfflineQueueBatchAndCancelAll() throws {
    let w0 = makeWall("0.jpg")
    let w1 = makeWall("1.jpg")
    let w2 = makeWall("2.jpg")
    let w3 = makeWall("3.jpg")
    var walls = [w0, w1, w2, w3]
    var queued: [OfflineQueueAction] = []

    // 逆序批量入队，且带重复元素
    let added = OfflineQueueLogic.enqueueBatch(.remove, items: [w3, w1, w1], walls: &walls, queued: &queued, rev: "rev-2")
    try expect(added, "批量入队应返回 true")
    try expect(walls.map(\.name) == ["0.jpg", "2.jpg"], "应批量从列表中移除")
    try expect(queued.count == 2, "批内重复项应去重")
    try expect(queued[0].name == "3.jpg" && queued[0].index == 3, "w3 原下标应为 3")
    try expect(queued[1].name == "1.jpg" && queued[1].index == 1, "w1 原下标应为 1")

    // 全部取消：按原下标从小到大放回，最终顺序仍为 0, 1, 2, 3
    let cancelled = OfflineQueueLogic.cancelAll(walls: &walls, queued: &queued)
    try expect(cancelled == 2 && queued.isEmpty, "应取消 2 条并清空队列")
    try expect(walls.map(\.name) == ["0.jpg", "1.jpg", "2.jpg", "3.jpg"], "全部取消后应恢复完整原顺序")

    // 缺少 wall 快照或越界下标的容错
    var noSnap = OfflineQueueAction(kind: .remove, name: "ghost.jpg", source: nil, wall: nil, index: 99, rev: nil)
    try expect(!OfflineQueueLogic.restore(noSnap, into: &walls), "缺少 wall 快照时 restore 应返回 false")
    noSnap.wall = makeWall("ghost.jpg")
    try expect(OfflineQueueLogic.restore(noSnap, into: &walls), "越界下标应钳位到末尾插入")
    try expect(walls.last?.name == "ghost.jpg", "越界下标应插入到列表末尾")

    // JSON 编解码往返
    let encoded = try JSONEncoder().encode([noSnap])
    let decoded = try JSONDecoder().decode([OfflineQueueAction].self, from: encoded)
    try expect(decoded == [noSnap], "OfflineQueueAction JSON 编解码往返应完全一致")
}

private func testImageCachePruner() throws {
    let prefixes = ImageKind.allCases.map { $0.cachePrefix + "-" }
    let files = [
        "thumb-a.jpg",
        "hero-a.jpg",
        "image2732-a.jpg",
        "original-a.jpg",
        "thumb-old.jpg",
        "image1600-a.jpg", // 旧档位前缀
        "unrelated.tmp",
    ]
    let stale = Set(ImageCachePruner.staleFileNames(in: files, prefixes: prefixes, keepSafeNames: ["a.jpg"]))
    let expected: Set<String> = ["thumb-old.jpg", "image1600-a.jpg", "unrelated.tmp"]
    try expect(stale == expected, "缓存淘汰集合不符：actual=\(stale) expected=\(expected)")
}

private func testWidgetCachePruner() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let recent1 = now.addingTimeInterval(-60)
    let recent2 = now.addingTimeInterval(-120)
    let recent3 = now.addingTimeInterval(-180)
    let expired = now.addingTimeInterval(-(8 * 86400))

    let entries: [WidgetCachePruner.Entry] = [
        // 当前活跃状态文件：即使超过 7 天也不删
        .init(name: "state-active.json", mtime: expired),
        // 非活跃状态文件：超过 7 天在线时删
        .init(name: "state-old.json", mtime: expired),
        // 非活跃但未过期状态文件：保留
        .init(name: "state-recent.json", mtime: recent1),
        // 像素档 400：3 张，keep=2 时淘汰最旧的 c
        .init(name: "img-a-400.jpg", mtime: recent1),
        .init(name: "img-b-400.jpg", mtime: recent2),
        .init(name: "img-c-400.jpg", mtime: recent3),
        // 像素档 800：独立配额，不受 400 档影响
        .init(name: "img-d-800.jpg", mtime: recent1),
        .init(name: "img-e-800.jpg", mtime: recent2),
        // 过期图片：在线时删，离线时保留
        .init(name: "img-exp-800.jpg", mtime: expired),
        // 非法像素档（低于 minPx 或高于 maxPx）：在线离线都删
        .init(name: "img-tiny-100.jpg", mtime: recent1),
        .init(name: "img-legacy-1600.jpg", mtime: recent1),
    ]

    let onlineRemove = Set(WidgetCachePruner.namesToRemove(
        entries: entries,
        keep: 2,
        activeStateName: "state-active.json",
        online: true,
        now: now,
        minPx: 200,
        maxPx: 1200
    ))
    let expectedOnline: Set<String> = [
        "state-old.json",
        "img-c-400.jpg",
        "img-exp-800.jpg",
        "img-tiny-100.jpg",
        "img-legacy-1600.jpg",
    ]
    try expect(onlineRemove == expectedOnline, "在线清理结果不符：actual=\(onlineRemove) expected=\(expectedOnline)")

    let offlineRemove = Set(WidgetCachePruner.namesToRemove(
        entries: entries,
        keep: 2,
        activeStateName: "state-active.json",
        online: false,
        now: now,
        minPx: 200,
        maxPx: 1200
    ))
    // 离线时不删 state-old.json，但 img-exp-800.jpg 因 800 档超出 keep=2 且最旧仍会被配额淘汰
    let expectedOffline: Set<String> = [
        "img-c-400.jpg",
        "img-exp-800.jpg",
        "img-tiny-100.jpg",
        "img-legacy-1600.jpg",
    ]
    try expect(offlineRemove == expectedOffline, "离线清理结果不符：actual=\(offlineRemove) expected=\(expectedOffline)")
}

private func testReconnectBackoffAndModels() throws {
    var d: Double = 1
    var seq: [Double] = []
    for f in 1...6 {
        d = ReconnectBackoff.nextDelay(current: d, failures: f)
        seq.append(d)
    }
    try expect(seq == [2, 4, 8, 15, 15, 15], "低失败次数退避应封顶 15s：\(seq)")
    let d8 = ReconnectBackoff.nextDelay(current: 15, failures: 8)
    let d9 = ReconnectBackoff.nextDelay(current: d8, failures: 9)
    let d10 = ReconnectBackoff.nextDelay(current: d9, failures: 10)
    try expect([d8, d9, d10] == [30, 60, 60], "连续失败 >= 8 次应放宽至 60s 封顶：\([d8, d9, d10])")

    // Wallpaper 删除权限与 MacAddress IPv6 拼接
    let normal = makeWall("n.jpg", source: "/Volumes/Media0/n.jpg", sampleOnly: false)
    let sampleOnly = makeWall("s.jpg", source: "/Volumes/Media0/s.jpg", sampleOnly: true)
    let noSrc = Wallpaper(name: "o.jpg", source: nil, sampleOnly: false)
    try expect(normal.canDeleteOriginal, "普通有原图的壁纸允许删原图")
    try expect(!sampleOnly.canDeleteOriginal, "仅采样目录壁纸禁止删原图")
    try expect(!noSrc.canDeleteOriginal, "无原图记录的壁纸禁止删原图")

    let v4 = MacAddress(host: "192.168.1.10", port: 51734)
    let v6 = MacAddress(host: "fe80::1", port: 51734)
    try expect(v4.baseURL?.absoluteString == "http://192.168.1.10:51734", "IPv4 URL 拼接错误")
    try expect(v6.baseURL?.absoluteString == "http://[fe80::1]:51734", "IPv6 URL 应加方括号")
}

@main
struct IOSLogicTestMain {
    static func main() {
        do {
            try testOfflineQueueSingleAndDedup()
            try testOfflineQueueBatchAndCancelAll()
            try testImageCachePruner()
            try testWidgetCachePruner()
            try testReconnectBackoffAndModels()
            print("PASS: all iOS core logic tests passed")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }
}
