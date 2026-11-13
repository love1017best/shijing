import Foundation
import Network
import Observation

/// 用 Bonjour 找局域网里开着「允许手机遥控」的拾景（服务类型 _shijing._tcp）。
@Observable @MainActor
final class Discovery {
    struct Found: Identifiable, Hashable {
        var name: String
        var endpoint: NWEndpoint
        var id: String { name }
    }

    static let serviceType = "_shijing._tcp"

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
        let b = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let list = results.compactMap { r -> Found? in
                guard case let .service(name, _, _, _) = r.endpoint else { return nil }
                return Found(name: name, endpoint: r.endpoint)
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
        let params = NWParameters.tcp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4 // IPv6 链路本地地址带 %en0，拼进 URL 很麻烦
        }
        let conn = NWConnection(to: endpoint, using: params)
        let once = Once<MacAddress>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<MacAddress, Error>) in
                once.set(cont)
                conn.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if case let .hostPort(host, port)? = conn.currentPath?.remoteEndpoint {
                            var h = "\(host)"
                            if let i = h.firstIndex(of: "%") { h = String(h[..<i]) }
                            once.resume(.success(MacAddress(host: h, port: Int(port.rawValue))))
                        } else {
                            once.resume(.failure(APIError.badResponse))
                        }
                        conn.cancel()
                    case .failed(let e):
                        once.resume(.failure(e))
                        conn.cancel()
                    default:
                        break
                    }
                }
                conn.start(queue: .global())
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    once.resume(.failure(URLError(.timedOut)))
                    conn.cancel()
                }
            }
        } onCancel: {
            once.resume(.failure(CancellationError()))
            conn.cancel()
        }
    }

    /// 按服务名重新解析（Mac 的 IP 变了的时候）。
    nonisolated static func resolve(serviceName: String) async throws -> MacAddress {
        try await resolve(.service(name: serviceName, type: serviceType, domain: "local.", interface: nil))
    }
}

/// 只恢复一次的 continuation（连接回调、超时、取消三者谁先到算谁）。
private final class Once<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<T, Error>?
    private var pending: Result<T, Error>?

    func set(_ c: CheckedContinuation<T, Error>) {
        lock.lock()
        if let p = pending {
            lock.unlock()
            c.resume(with: p)
            return
        }
        cont = c
        lock.unlock()
    }

    func resume(_ r: Result<T, Error>) {
        lock.lock()
        defer { lock.unlock() }
        if let c = cont {
            cont = nil
            pending = r // 之后再来的都忽略
            c.resume(with: r)
        } else if pending == nil {
            pending = r
        }
    }
}
