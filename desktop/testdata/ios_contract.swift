import Foundation

// macOS 桌面端与 iOS 共享层（Models.swift / APIClient.swift）的契约测试驱动。
// 由 desktop/contract_test.go 通过 swiftc 与生产代码一起编译运行，覆盖：
//   1. schema 模式：核对桌面端 JSON 响应与 iOS Codable 模型字段严格一致（防止增删/改名静默漂移）；
//   2. live 模式：用真实 APIClient 直连桌面端 remoteServer，跑通鉴权、配对、快照、壁纸、图片、设置、记录、条件请求与 SSE。

private struct ContractFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

private func check(_ cond: @autoclosure () -> Bool, _ msg: String, file: StaticString = #file, line: UInt = #line) throws {
    if !cond() {
        throw ContractFailure(message: "[\(file):\(line)] \(msg)")
    }
}

private func makeDecoder() -> JSONDecoder {
    let d = JSONDecoder()
    d.keyDecodingStrategy = .convertFromSnakeCase
    return d
}

private func makeEncoder() -> JSONEncoder {
    let e = JSONEncoder()
    e.keyEncodingStrategy = .convertToSnakeCase
    return e
}

/// 递归对比服务端原始 JSON 与 iOS 模型反序列化再编码后的键集合，捕获字段名漂移或未映射的新字段。
private func compareJSONStructure(_ expected: Any, _ actual: Any, path: String) throws {
    if let expDict = expected as? [String: Any], let actDict = actual as? [String: Any] {
        let expKeys = Set(expDict.keys)
        let actKeys = Set(actDict.keys)
        let missingInSwift = expKeys.subtracting(actKeys).sorted()
        let extraInSwift = actKeys.subtracting(expKeys).sorted()
        if !missingInSwift.isEmpty || !extraInSwift.isEmpty {
            throw ContractFailure(message: "\(path): 键集合不一致；服务端有但 iOS 未映射=\(missingInSwift)，iOS 多出=\(extraInSwift)")
        }
        for key in expKeys.sorted() {
            try compareJSONStructure(expDict[key]!, actDict[key]!, path: "\(path).\(key)")
        }
        return
    }
    if let expArr = expected as? [Any], let actArr = actual as? [Any] {
        try check(expArr.count == actArr.count, "\(path): 数组长度不一致 go=\(expArr.count) swift=\(actArr.count)")
        for i in 0..<expArr.count {
            try compareJSONStructure(expArr[i], actArr[i], path: "\(path)[\(i)]")
        }
    }
}

private func verifyRoundTrip<T: Codable>(_ type: T.Type, file: URL, name: String) throws -> T {
    let raw = try Data(contentsOf: file)
    let model = try makeDecoder().decode(T.self, from: raw)
    let reencoded = try makeEncoder().encode(model)
    let goObj = try JSONSerialization.jsonObject(with: raw)
    let swiftObj = try JSONSerialization.jsonObject(with: reencoded)
    try compareJSONStructure(goObj, swiftObj, path: name)
    return model
}

// MARK: - Schema 模式

private struct ExcludedEnvelope: Codable { var items: [ExcludedItem] }
private struct LogEnvelope: Codable { var lines: [String] }

private func runSchemaMode(dir: URL) throws {
    let info = try verifyRoundTrip(ServerInfo.self, file: dir.appending(path: "info.json"), name: "ServerInfo")
    try check(info.app == "拾景" && info.api == 1 && info.paired && info.serverId == "11111111-2222-4333-8444-555555555555", "ServerInfo 字段值异常: \(info)")

    let full = try verifyRoundTrip(RemoteState.self, file: dir.appending(path: "state_full.json"), name: "RemoteState(full)")
    try check(full.running && full.stopping, "RemoteState running/stopping 不一致")
    try check(full.stage == "copy" && full.label != nil && full.lastLine != nil, "RemoteState 进度字段缺失")
    try check(full.blocked != nil && full.willDelete && full.deleteNote != nil, "RemoteState 提示字段缺失")
    try check(full.nextAuto != nil && full.wallsRev != nil && full.undoName != nil, "RemoteState 可选字段缺失")
    try check(full.excluded == 2 && full.pending == 1 && full.pendingItems?.count == 1, "RemoteState 计数或待删列表缺失")
    try check(full.pendingItems?.first?.wall != nil, "PendingItem.wall 缺失")
    try check(full.dirs?.count == 2 && full.dirs?.first?.deleted != nil, "LibraryDir 字段缺失")
    try check(
        full.activeProfile == "日常风景" && full.activeProfileModified == true &&
        full.profiles?.count == 2 && full.profiles?.first?.willDelete == true &&
        full.profiles?.last?.mode == "symlink",
        "RemoteState 配置方案字段缺失或不一致"
    )
    let last = try unwrap(full.last, "RemoteState.last 为空")
    try check(last.error != nil && last.brief != nil && last.detail != nil, "LastRun 可选字段缺失")
    let set = try unwrap(full.settings, "RemoteState.settings 为空")
    try check(
        set.balanceFirst != nil && set.incremental != nil && set.mode != nil &&
        set.minWidth != nil && set.minHeight != nil && !(set.minPresets ?? []).isEmpty &&
        set.archiveEnabled != nil && set.archiveSubdir != nil && set.archiveDir != nil,
        "RemoteSettings 字段缺失"
    )

    let minimal = try verifyRoundTrip(RemoteState.self, file: dir.appending(path: "state_minimal.json"), name: "RemoteState(minimal)")
    try check(!minimal.running && minimal.last == nil && minimal.undoName == nil, "最小状态快照解析异常")

    let walls = try verifyRoundTrip(WallpaperList.self, file: dir.appending(path: "wallpapers.json"), name: "WallpaperList")
    try check(
        walls.hero != nil && walls.items.count == 3 &&
        walls.items[0].hasSource && !walls.items[0].isSampleOnly && walls.items[0].canDeleteOriginal &&
        walls.items[1].hasSource && walls.items[1].isSampleOnly && !walls.items[1].canDeleteOriginal &&
        !walls.items[2].hasSource && !walls.items[2].canDeleteOriginal,
        "WallpaperList 字段异常"
    )

    let dels = try verifyRoundTrip(DeletionList.self, file: dir.appending(path: "deletions.json"), name: "DeletionList")
    try check(dels.total == 2 && dels.filter == 1 && dels.manual == 1 && dels.items.count == 2, "DeletionList 字段异常")
    try check(dels.items[0].reason != nil, "Deletion.reason 缺失")

    let excl = try verifyRoundTrip(ExcludedEnvelope.self, file: dir.appending(path: "excluded.json"), name: "ExcludedList")
    try check(excl.items.count == 1 && !excl.items[0].path.isEmpty && !excl.items[0].display.isEmpty, "ExcludedList 字段异常")

    let log = try verifyRoundTrip(LogEnvelope.self, file: dir.appending(path: "log.json"), name: "LogList")
    try check(log.lines.count == 2, "LogList 字段异常")
}

private func unwrap<T>(_ value: T?, _ msg: String) throws -> T {
    guard let value else { throw ContractFailure(message: msg) }
    return value
}

// MARK: - Live 模式

private func expectUnauthorized(_ label: String, _ work: () async throws -> Void) async throws {
    do {
        try await work()
        throw ContractFailure(message: "\(label): 期望返回 401 unauthorized，却成功了")
    } catch APIError.unauthorized(let msg) {
        try check(!msg.isEmpty, "\(label): 401 错误消息不应为空")
    }
}

private func expectServerError(_ label: String, status expected: Int, _ work: () async throws -> Void) async throws {
    do {
        try await work()
        throw ContractFailure(message: "\(label): 期望返回 HTTP \(expected)，却成功了")
    } catch APIError.server(let status, let msg) {
        try check(status == expected && !msg.isEmpty, "\(label): 期望 HTTP \(expected)，实际 \(status) (\(msg))")
    }
}

private func runLiveMode() async throws {
    let env = ProcessInfo.processInfo.environment
    let host = try unwrap(env["CONTRACT_HOST"], "缺少 CONTRACT_HOST")
    let port = try unwrap(env["CONTRACT_PORT"].flatMap(Int.init), "缺少 CONTRACT_PORT")
    let qrCode = try unwrap(env["CONTRACT_QR_CODE"], "缺少 CONTRACT_QR_CODE")
    let pendingFirst = try unwrap(env["CONTRACT_PENDING_FIRST"], "缺少 CONTRACT_PENDING_FIRST")
    let exclA = try unwrap(env["CONTRACT_EXCLUDED_A"], "缺少 CONTRACT_EXCLUDED_A")
    let exclB = try unwrap(env["CONTRACT_EXCLUDED_B"], "缺少 CONTRACT_EXCLUDED_B")

    let addr = MacAddress(host: host, port: port)
    let guest = try APIClient(address: addr, token: nil)

    // 1. 未配对 /api/info 与 401 鉴权（常规接口 + SSE）
    let guestInfo = try await guest.info()
    try check(guestInfo.app == "拾景" && guestInfo.name == "测试 Mac" && guestInfo.api == 1 && !guestInfo.paired && !(guestInfo.serverId ?? "").isEmpty, "未配对 info 异常: \(guestInfo)")
    try await expectUnauthorized("GET /api/state") { _ = try await guest.state() }
    try await expectUnauthorized("GET /api/events") {
        for try await _ in guest.events() { break }
    }

    // 2. 扫码配对完成 + 新设备发起配对请求
    let paired = try await guest.pairFinish(code: qrCode, device: "契约测试 iPhone", id: "contract-ios-1")
    try check(!paired.token.isEmpty && paired.name == "测试 Mac" && paired.serverId == guestInfo.serverId, "pairFinish 返回异常: \(paired)")
    try await guest.pairStart(device: "第二台 iPhone", id: "contract-ios-2")

    let client = try APIClient(address: addr, token: paired.token)

    // 3. 已配对 /api/info 与 /api/state
    let authedInfo = try await client.info()
    try check(authedInfo.paired, "已配对 info.paired 应为 true")
    let st = try await client.state()
    try check(st.wallpapers == 3 && st.wallsRev != nil, "state 壁纸信息异常")
    try check(st.pending == 2 && st.pendingItems?.count == 2, "state 待删除列表异常")
    try check(st.dirs?.count == 2, "state 图库目录异常")
    try check(st.settings != nil, "state 缺少 settings")

    // 4. 壁纸列表与图片/原图下载（含中文文件名）
    let walls = try await client.wallpapers()
    try check(walls.rev == st.wallsRev, "wallpapers.rev 与 state.wallsRev 不一致")
    try check(walls.hero == "风景-a.jpg", "wallpapers.hero 异常: \(String(describing: walls.hero))")
    try check(walls.items.count == 3 && walls.items[0].name == "风景-a.jpg" && walls.items[0].hasSource, "wallpapers 首项异常")
    try check(walls.items[2].name == "c.jpg" && !walls.items[2].hasSource, "wallpapers 无原图项异常")

    for kind in [ImageKind.thumb, .hero, .image] {
        let data = try await client.imageData("风景-a.jpg", kind: kind)
        try check(data.count > 100 && data[0] == 0xFF && data[1] == 0xD8, "imageData(\(kind.rawValue)) 不是有效 JPEG")
    }
    let origURL = try await client.downloadOriginal("风景-a.jpg")
    defer { try? FileManager.default.removeItem(at: origURL.deletingLastPathComponent()) }
    let origData = try Data(contentsOf: origURL)
    try check(origURL.lastPathComponent == "风景-a.jpg" && origData.count > 100 && origData[0] == 0xFF && origData[1] == 0xD8, "downloadOriginal 异常")

    // 5. 运行日志
    let lines = try await client.log()
    try check(lines.contains { $0.contains("契约测试日志行") }, "log 未包含预期日志: \(lines)")

    // 6. 删除记录与 ETag / 304 条件请求
    let delList = try await client.deletions()
    try check(delList.total == 2 && delList.filter == 1 && delList.manual == 1 && delList.items.count == 2, "deletions 统计异常: \(delList)")
    let cond1 = try unwrap(try await client.deletions(ifNoneMatch: nil), "首次条件请求不应为 304")
    let etag1 = try unwrap(cond1.etag, "删除记录响应缺少 ETag")
    let cond2 = try await client.deletions(ifNoneMatch: etag1)
    try check(cond2 == nil, "携带相同 ETag 应返回 304 (nil)")

    // 7. 设置修改（覆盖全部可写字段 + 400 参数校验）
    let updated = try await client.updateSettings([
        "sample_count": 88,
        "auto_run_hours": 24,
        "delete_during_filter": true,
        "prefer_unseen": false,
        "refresh_wallpaper": false,
        "balance_first": false,
        "incremental": false,
        "mode": "symlink",
        "min_width": 2560,
        "min_height": 1440,
        "archive_enabled": true,
    ])
    let us = try unwrap(updated.settings, "updateSettings 未返回 settings")
    try check(
        us.sampleCount == 88 && us.autoRunHours == 24 && us.deleteDuringFilter &&
        !us.preferUnseen && !us.refreshWallpaper && us.balanceFirst == false &&
        us.incremental == false && us.mode == "symlink" &&
        us.minWidth == 2560 && us.minHeight == 1440 && us.archiveEnabled == true,
        "updateSettings 回显字段与写入不一致: \(us)"
    )
    try await expectServerError("POST /api/settings invalid", status: 400) {
        _ = try await client.updateSettings(["sample_count": 0])
    }

    // 8. 移出 + 不再选 + 撤销 + 重复撤销 409
    let afterRemove = try await client.removeWallpaper("风景-a.jpg", exclude: true)
    try check(afterRemove.wallpapers == 2 && afterRemove.undoName == "风景-a.jpg" && afterRemove.excluded == 1, "removeWallpaper 状态异常")
    let exclAfterRemove = try await client.excluded()
    try check(exclAfterRemove.count == 1, "excluded 应为 1 项")
    let afterUndo = try await client.undo()
    try check(afterUndo.wallpapers == 3 && afterUndo.undoName == nil && afterUndo.excluded == 0, "undo 状态异常")
    try await expectServerError("POST /api/undo empty", status: 409) {
        _ = try await client.undo()
    }

    // 9. 离线补交不再选 + 单项/全部恢复
    let addedExcl = try await client.addExcluded([exclA, exclB])
    try check(addedExcl.count == 2, "addExcluded 数量异常: \(addedExcl.count)")
    let restoredOne = try await client.restoreExcluded([exclA])
    try check(restoredOne.count == 1 && restoredOne[0].path == exclB, "restoreExcluded 单项异常")
    let restoredAll = try await client.restoreExcluded(nil)
    try check(restoredAll.isEmpty, "restoreExcluded(nil) 应清空名单")

    // 10. 删除原图并验证删除记录 ETag 失效返回新数据
    let afterDelete = try await client.deleteOriginal("风景-b.jpg")
    try check(afterDelete.wallpapers == 2, "deleteOriginal 后壁纸数应为 2")
    let cond3 = try unwrap(try await client.deletions(ifNoneMatch: etag1), "删除原图后旧 ETag 应失效并返回新记录")
    try check(cond3.list.total == 3 && cond3.list.manual == 2 && cond3.etag != etag1, "删除原图后 deletions 数据或 ETag 未更新")

    // 11. 待删除队列单项/全部取消与重新检查挂载
    let afterCancel1 = try await client.cancelPending(pendingFirst)
    try check(afterCancel1.pending == 1, "cancelPending 单项后应剩 1 项")
    let afterCancelAll = try await client.cancelPending(nil)
    try check(afterCancelAll.pending == 0, "cancelPending(nil) 后应清空")
    _ = try await client.checkMounts()

    // 11.5 配置方案切换（仅切换、错误校验）
    let switched = try await client.switchProfile("暗色极简", run: false)
    try check(
        switched.activeProfile == "暗色极简" && switched.activeProfileModified != true &&
        switched.sampleCount == 15 && switched.libraryDirs == 1 && switched.profiles?.count == 2 &&
        switched.settings?.minWidth == 2560 && switched.settings?.minHeight == 1440,
        "switchProfile(暗色极简) 状态异常: \(switched)"
    )
    try await expectServerError("POST /api/profiles/switch missing", status: 404) {
        _ = try await client.switchProfile("不存在的方案")
    }
    try await expectServerError("POST /api/profiles/switch empty", status: 400) {
        _ = try await client.switchProfile("   ")
    }

    // 12. 遥控运行与停止接口（用 switchProfile run: true 切回方案并启动）
    let switchedRun = try await client.switchProfile("日常风景", run: true, deleteOriginals: false)
    try check(switchedRun.activeProfile == "日常风景" && switchedRun.running, "switchProfile(run: true) 未启动运行")
    _ = try await client.stop()

    // 13. SSE 事件流：接收首帧并响应服务端状态变化
    let sseTask = Task<Void, Error> {
        var sawInitial = false
        for try await frame in client.events() {
            if !sawInitial {
                sawInitial = true
                Task {
                    _ = try? await client.updateSettings(["sample_count": 77])
                }
                continue
            }
            if frame.settings?.sampleCount == 77 {
                return
            }
        }
        throw ContractFailure(message: "SSE 在收到预期状态更新前结束")
    }
    let timeoutTask = Task {
        try await Task.sleep(for: .seconds(8))
        sseTask.cancel()
    }
    defer { timeoutTask.cancel() }
    try await sseTask.value
}

@main
struct IOSContractRunner {
    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard args.count >= 2, args[0] == "--mode" else {
                throw ContractFailure(message: "用法: ios_contract --mode schema <dir> | --mode live")
            }
            switch args[1] {
            case "schema":
                guard args.count == 3 else { throw ContractFailure(message: "schema 模式需要目录参数") }
                try runSchemaMode(dir: URL(filePath: args[2]))
            case "live":
                try await runLiveMode()
            default:
                throw ContractFailure(message: "未知模式: \(args[1])")
            }
        } catch {
            fputs("契约测试失败: \(error)\n", stderr)
            exit(1)
        }
    }
}
