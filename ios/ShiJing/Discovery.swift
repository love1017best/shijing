import Foundation
import Network
import Observation

/// 用 Bonjour 找局域网里开着「允许手机遥控」的拾景（服务类型 _shijing._tcp）。
@Observable @MainActor
final class Discovery {
    struct Found: Identifiable, Hashable {
        var name: String
        var serverID: String?
        var endpoint: NWEndpoint
        var id: String { serverID ?? name }
    }

    static let serviceType = MacRelocator.serviceType

    private(set) var found: [Found] = []
    /// 本地网络权限被拒绝等情况的说明
    private(set) var problem: String?
    private var browser: NWBrowser?
    /// 哪些界面正在显示「附近的 Mac」：只有有人在看的时候才搜索，配对完平时不在后台一直找。
    /// 按名字记（而不是计数），同一个界面重复报告也不会算错。
    private var watchers: Set<String> = []
    private var paused = false

    func want(_ who: String, _ on: Bool) {
        if on { watchers.insert(who) } else { watchers.remove(who) }
        if watchers.isEmpty {
            stop()
        } else if !paused {
            start()
        }
    }

    /// App 进后台时停止搜索，回前台时如果还有人在看再接着找。
    func setPaused(_ p: Bool) {
        paused = p
        if p {
            stop()
        } else if !watchers.isEmpty {
            start()
        }
    }

    private func start() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let list = results.compactMap { r -> Found? in
                guard case let .service(name, _, _, _) = r.endpoint else { return nil }
                var sid: String?
                if case let .bonjour(txt) = r.metadata, let id = txt["id"], !id.isEmpty {
                    sid = id
                }
                return Found(name: name, serverID: sid, endpoint: r.endpoint)
            }.sorted { $0.name < $1.name }
            // 结果没变（Bonjour 会反复报告同样的服务）就不要刷新界面：列表一动，
            // 从列表里弹出的扫码 / 配对弹层会被一起重建、自己关掉
            Task { @MainActor in
                guard let self, self.found != list else { return }
                self.found = list
            }
        }
        b.stateUpdateHandler = { [weak self] state in
            let msg: String? = switch state {
            case .failed(let e), .waiting(let e): Self.describe(e)
            default: nil
            }
            Task { @MainActor in
                guard let self, self.problem != msg else { return }
                self.problem = msg
            }
        }
        b.start(queue: .main)
        browser = b
    }

    private func stop() {
        browser?.cancel()
        browser = nil
        found = []
        problem = nil
    }

    private nonisolated static func describe(_ e: NWError) -> String {
        if case .dns(let code) = e, code == -65570 { // kDNSServiceErr_PolicyDenied
            return "没有本地网络权限：请到「设置 › 隐私与安全性 › 本地网络」里打开拾景。"
        }
        return "找不到局域网里的 Mac：\(e.localizedDescription)"
    }

    /// 把 Bonjour 服务解析成 IPv4 地址和端口：建一个 TCP 连接，连上后看对端地址。
    nonisolated static func resolve(_ endpoint: NWEndpoint, timeout: TimeInterval = 8) async throws -> MacAddress {
        try await MacRelocator.resolve(endpoint, timeout: timeout)
    }

    /// 按服务名重新解析（兼容旧调用）。
    nonisolated static func resolve(serviceName: String) async throws -> MacAddress {
        try await MacRelocator.resolve(.service(name: serviceName, type: serviceType, domain: "local.", interface: nil))
    }
}
