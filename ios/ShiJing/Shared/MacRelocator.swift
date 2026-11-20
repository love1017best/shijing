import Foundation
import Network

/// 局域网 Bonjour 重解析与身份核对：Mac 换 IP、换端口或改名后重新找到同一台 Mac。
/// 主 App、小组件和快捷指令共用。
enum MacRelocator {
    static let serviceType = "_shijing._tcp"

    struct ResolvedMac: Sendable, Equatable {
        var address: MacAddress
        var name: String
        var serviceName: String
        var serverID: String?
    }

    /// 把 Bonjour 端点解析成 IPv4 地址和端口：建立 TCP 连接后读取对端地址。
    static func resolve(_ endpoint: NWEndpoint, timeout: TimeInterval = 8) async throws -> MacAddress {
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

    /// 按 serverID（优先，经 TXT 记录精准匹配）或 serviceName（兜底，兼容旧版桌面端）重新定位 Mac，
    /// 并通过不带令牌的 `GET /api/info` 核对身份后才返回新地址，防止把配对令牌发给局域网里的同名机器。
    static func locate(serverID: String?, serviceName: String?, timeout: TimeInterval = 3.5) async -> ResolvedMac? {
        let cleanID = serverID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetID = (cleanID?.isEmpty == false) ? cleanID : nil
        let cleanSvc = serviceName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetSvc = (cleanSvc?.isEmpty == false) ? cleanSvc : nil
        guard targetID != nil || targetSvc != nil else { return nil }

        let deadline = Date().addingTimeInterval(timeout)
        let candidate: (endpoint: NWEndpoint, serviceName: String)?

        if let targetID {
            let browseBudget = min(max(timeout * 0.6, 1.2), 2.5)
            candidate = await browse(serverID: targetID, fallbackServiceName: targetSvc, timeout: browseBudget)
        } else if let targetSvc {
            candidate = (.service(name: targetSvc, type: serviceType, domain: "local.", interface: nil), targetSvc)
        } else {
            candidate = nil
        }

        guard let candidate else { return nil }

        let resolveBudget = min(max(deadline.timeIntervalSinceNow, 1.2), 3.0)
        guard let addr = try? await resolve(candidate.endpoint, timeout: resolveBudget) else {
            return nil
        }

        let probeBudget = min(max(deadline.timeIntervalSinceNow, 1.5), 3.0)
        guard let probe = try? APIClient(address: addr, token: nil),
              let info = try? await probe.info(timeout: probeBudget),
              info.app == "拾景" else {
            return nil
        }

        // 已知 serverID 时严格校验一致，拒绝同名机器或冒充服务
        if let targetID, info.serverId != targetID {
            return nil
        }

        return ResolvedMac(
            address: addr,
            name: info.name,
            serviceName: candidate.serviceName,
            serverID: info.serverId ?? targetID
        )
    }

    /// 供小组件与快捷指令使用：连接旧地址失败后在短预算内按 Bonjour 重新定位，核对后回写共享钥匙串。
    static func recoverCurrentMac(_ mac: CurrentMac, timeout: TimeInterval = 3.0) async -> CurrentMac? {
        guard mac.serverID != nil || mac.serviceName != nil else { return nil }
        guard let resolved = await locate(serverID: mac.serverID, serviceName: mac.serviceName, timeout: timeout) else {
            return nil
        }
        var updated = mac
        updated.host = resolved.address.host
        updated.port = resolved.address.port
        updated.name = resolved.name
        updated.serviceName = resolved.serviceName
        if let sid = resolved.serverID, !sid.isEmpty {
            updated.serverID = sid
        }
        if updated != mac {
            updated.save(reloadWidgets: false)
        }
        return updated
    }

    /// 是否属于网络层连接失败（而非服务端返回 401/4xx/5xx 或取消），适合触发 Bonjour 地址恢复。
    static func isNetworkFailure(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if error is APIError { return false }
        return true
    }

    /// 短时浏览局域网里的 `_shijing._tcp` 服务，读取 TXT 记录中的 `id` 匹配指定 `serverID`。
    private static func browse(
        serverID: String,
        fallbackServiceName: String?,
        timeout: TimeInterval
    ) async -> (endpoint: NWEndpoint, serviceName: String)? {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: serviceType, domain: nil), using: .tcp)
        let state = BrowseState()
        let once = Once<(NWEndpoint, String)?>()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<(NWEndpoint, String)?, Never>) in
                once.set(cont)
                browser.browseResultsChangedHandler = { results, _ in
                    for r in results {
                        guard case let .service(name, _, _, _) = r.endpoint else { continue }
                        if case let .bonjour(txt) = r.metadata, txt["id"] == serverID {
                            once.resume(.success((r.endpoint, name)))
                            browser.cancel()
                            return
                        }
                        if let fallbackServiceName, name == fallbackServiceName {
                            state.setFallback((r.endpoint, name))
                        }
                    }
                }
                browser.stateUpdateHandler = { st in
                    if case .failed = st {
                        once.resume(.success(state.fallback()))
                        browser.cancel()
                    }
                }
                browser.start(queue: .global(qos: .utility))
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                    once.resume(.success(state.fallback()))
                    browser.cancel()
                }
            }
        } onCancel: {
            once.resume(.success(nil))
            browser.cancel()
        }
    }
}

private final class BrowseState: @unchecked Sendable {
    private let lock = NSLock()
    private var item: (NWEndpoint, String)?

    func setFallback(_ value: (NWEndpoint, String)) {
        lock.lock()
        item = value
        lock.unlock()
    }

    func fallback() -> (NWEndpoint, String)? {
        lock.lock()
        defer { lock.unlock() }
        return item
    }
}

/// 只恢复一次的 continuation（回调、超时、取消三者谁先到算谁）。
private final class Once<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<T, Error>?
    private var nonThrowingCont: CheckedContinuation<T, Never>?
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

    func set(_ c: CheckedContinuation<T, Never>) {
        lock.lock()
        if case .success(let v) = pending {
            lock.unlock()
            c.resume(returning: v)
            return
        }
        nonThrowingCont = c
        lock.unlock()
    }

    func resume(_ r: Result<T, Error>) {
        lock.lock()
        defer { lock.unlock() }
        if let c = cont {
            cont = nil
            pending = r
            c.resume(with: r)
        } else if let c = nonThrowingCont, case .success(let v) = r {
            nonThrowingCont = nil
            pending = r
            c.resume(returning: v)
        } else if pending == nil {
            pending = r
        }
    }
}
