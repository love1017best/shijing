import Foundation
import Observation

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

    private let store: MacStore
    private var task: Task<Void, Never>?

    init(mac: SavedMac, store: MacStore) {
        self.mac = mac
        macID = mac.id
        self.store = store
    }

    private func client() throws -> APIClient {
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

    private func loop() async {
        var delay: Double = 1
        var failures = 0
        while !Task.isCancelled {
            if state == nil { connection = .connecting }
            do {
                for try await s in try client().events() {
                    state = s
                    connection = .live
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
        await act { try await $0.run(deleteOriginals: deleteOriginals) }
    }

    func stop() async {
        await act { try await $0.stop() }
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
        return args.contains("-demoRunning") ? "running" : (args.contains("-demo") ? "idle" : nil)
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
            nextAuto: now + 6 * 3600, wallpapers: 300, dest: "~/Pictures/Wallpapers0", sampleCount: 300, libraryDirs: 3)
        s.connection = .live
        return s
    }
}
#endif
