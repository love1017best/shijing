import Foundation

enum APIError: LocalizedError {
    /// 令牌无效：没配对，或者在电脑上取消了配对
    case unauthorized(String)
    case server(status: Int, message: String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .unauthorized(let m): m
        case .server(_, let m): m
        case .badResponse: "电脑返回的内容看不懂，两边的拾景版本可能不一致"
        }
    }
}

/// 桌面端局域网接口（desktop/remote.go）的客户端。
struct APIClient: Sendable {
    let base: URL
    let token: String?

    init(address: MacAddress, token: String?) throws {
        guard let url = address.baseURL else { throw APIError.badResponse }
        base = url
        self.token = token
    }

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30 // 事件流每 15 秒有一次保活，不会被这个超时打断
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    private func request(_ method: String, _ path: String, body: [String: Any]? = nil, timeout: TimeInterval = 15) -> URLRequest {
        var req = URLRequest(url: base.appending(path: path))
        req.httpMethod = method
        req.timeoutInterval = timeout
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    private func send<T: Decodable>(_ req: URLRequest, as: T.Type) async throws -> T {
        let (data, resp) = try await Self.session.data(for: req)
        try Self.check(resp, data: data)
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw APIError.badResponse
        }
    }

    private static func check(_ resp: URLResponse, data: Data?) throws {
        guard let http = resp as? HTTPURLResponse else { throw APIError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            var msg = "电脑返回错误 \(http.statusCode)"
            if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let e = obj["error"] as? String {
                msg = e
            }
            if http.statusCode == 401 { throw APIError.unauthorized(msg) }
            throw APIError.server(status: http.statusCode, message: msg)
        }
    }

    // MARK: 接口

    func info() async throws -> ServerInfo {
        try await send(request("GET", "api/info", timeout: 6), as: ServerInfo.self)
    }

    /// 请求配对：电脑上会弹出 6 位配对码。
    func pairStart(device: String) async throws {
        struct R: Decodable { var expiresIn: Int }
        _ = try await send(request("POST", "api/pair/start", body: ["device": device]), as: R.self)
    }

    /// 输入配对码，成功时返回令牌和电脑名。
    func pairFinish(code: String) async throws -> (token: String, name: String) {
        struct R: Decodable { var token: String; var name: String }
        let r = try await send(request("POST", "api/pair/finish", body: ["code": code]), as: R.self)
        return (r.token, r.name)
    }

    func state() async throws -> RemoteState {
        try await send(request("GET", "api/state"), as: RemoteState.self)
    }

    /// 换一批。deleteOriginals 为 false 时这次只模拟筛选。
    func run(deleteOriginals: Bool) async throws -> RemoteState {
        try await send(request("POST", "api/run", body: ["delete": deleteOriginals], timeout: 20), as: RemoteState.self)
    }

    func stop() async throws -> RemoteState {
        try await send(request("POST", "api/stop", body: [:]), as: RemoteState.self)
    }

    // MARK: 壁纸（第 2 期）

    func wallpapers() async throws -> WallpaperList {
        try await send(request("GET", "api/wallpapers"), as: WallpaperList.self)
    }

    /// 一张壁纸的 JPEG：缩略图或大图。
    func imageData(_ name: String, kind: ImageKind) async throws -> Data {
        let req = request("GET", "api/wallpapers/\(name)/\(kind.rawValue)", timeout: kind.isLarge ? 40 : 20)
        let (data, resp) = try await Self.session.data(for: req)
        try Self.check(resp, data: data)
        return data
    }

    /// 移出壁纸文件夹（原图不动）；exclude 时还让以后的采样跳过这张原图。
    func removeWallpaper(_ name: String, exclude: Bool) async throws -> RemoteState {
        try await send(request("POST", "api/wallpapers/\(name)/remove", body: ["exclude": exclude]), as: RemoteState.self)
    }

    /// 删除图库里的原图（不可撤销，记进删除记录），同时移出壁纸文件夹。
    func deleteOriginal(_ name: String) async throws -> RemoteState {
        try await send(request("POST", "api/wallpapers/\(name)/delete", body: [:]), as: RemoteState.self)
    }

    // MARK: 设置、日志、记录（第 3 期）

    /// 改常用设置：只传要改的字段（键名同 RemoteSettings 的蛇形命名）。
    func updateSettings(_ changes: [String: Any]) async throws -> RemoteState {
        try await send(request("POST", "api/settings", body: changes), as: RemoteState.self)
    }

    /// 电脑上的运行日志（最近 400 行）。
    func log() async throws -> [String] {
        struct R: Decodable { var lines: [String] }
        return try await send(request("GET", "api/log"), as: R.self).lines
    }

    /// 撤销最近一次移出（和电脑上 ⌘Z 是同一个撤销栈）。
    func undo() async throws -> RemoteState {
        try await send(request("POST", "api/undo", body: [:]), as: RemoteState.self)
    }

    private struct ExcludedR: Decodable { var items: [ExcludedItem] }

    func excluded() async throws -> [ExcludedItem] {
        try await send(request("GET", "api/excluded"), as: ExcludedR.self).items
    }

    /// 从「不再选」名单里拿掉：paths 为 nil 时全部恢复。返回剩下的名单。
    func restoreExcluded(_ paths: [String]?) async throws -> [ExcludedItem] {
        let body: [String: Any] = paths.map { ["paths": $0] } ?? ["all": true]
        return try await send(request("POST", "api/excluded/restore", body: body), as: ExcludedR.self).items
    }

    func deletions() async throws -> DeletionList {
        try await send(request("GET", "api/deletions"), as: DeletionList.self)
    }

    /// 下载壁纸的原文件到临时目录（文件名不变），分享 / 存相册用。
    func downloadOriginal(_ name: String) async throws -> URL {
        let req = request("GET", "api/wallpapers/\(name)/original", timeout: 120)
        let (tmp, resp) = try await Self.session.download(for: req)
        try Self.check(resp, data: (try? Data(contentsOf: tmp)).flatMap { $0.count < 4096 ? $0 : nil })
        let dir = FileManager.default.temporaryDirectory.appending(path: "originals", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = dir.appending(path: name)
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.moveItem(at: tmp, to: dst)
        return dst
    }

    /// 状态事件流（SSE）：连上先收到一次当前状态，之后状态变了就收到一次。
    func events() -> AsyncThrowingStream<RemoteState, Error> {
        let req = request("GET", "api/events", timeout: 30)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, resp) = try await Self.session.bytes(for: req)
                    try Self.check(resp, data: nil)
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue } // 「: ping」保活行
                        let json = Data(line.dropFirst(6).utf8)
                        guard let s = try? Self.decoder.decode(RemoteState.self, from: json) else {
                            throw APIError.badResponse
                        }
                        continuation.yield(s)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
