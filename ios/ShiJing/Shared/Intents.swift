import AppIntents
import Foundation

/// 快捷指令 / Siri / 操作按钮 / 小组件按钮用的操作。都连 App 里当前选中的那台 Mac（共享钥匙串里的 CurrentMac），
/// 不打开 App；App 和小组件两个目标都编译这份代码（小组件上的按钮在小组件进程里执行）。
enum IntentError: LocalizedError {
    case noMac
    case offline(OfflinePrefs.HoldReason)

    var errorDescription: String? {
        switch self {
        case .noMac:
            "尚未配对 Mac：请先打开拾景，在 Mac 上完成配对。"
        case .offline(.manual):
            "已打开离线模式，拾景暂停连接电脑。需要时先在拾景里关闭离线模式。"
        case .offline(.cellular):
            "正在使用蜂窝网络，拾景暂停连接电脑；连接 Wi‑Fi 后再试。"
        }
    }
}

private func currentMac() async throws -> CurrentMac {
    if let reason = await OfflinePrefs.holdReasonNow() {
        throw IntentError.offline(reason)
    }
    guard let mac = CurrentMac.load() else { throw IntentError.noMac }
    return mac
}

/// 连接当前 Mac 执行操作；若因网络层错误连不上，尝试短时 Bonjour 重定位并回写钥匙串后重试一次。
private func withRecoveredClient<T>(_ work: (CurrentMac, APIClient) async throws -> T) async throws -> T {
    let mac = try await currentMac()
    do {
        return try await work(mac, try mac.client())
    } catch {
        if MacRelocator.isNetworkFailure(error),
           let recovered = await MacRelocator.recoverCurrentMac(mac, timeout: 3.0) {
            do {
                return try await work(recovered, try recovered.client())
            } catch {
                throw explain(error, mac: recovered.name)
            }
        }
        throw explain(error, mac: mac.name)
    }
}

/// 把网络错误换成能直接念出来的话。
private func explain(_ error: Error, mac: String) -> Error {
    if error is APIError || error is IntentError { return error }
    if error is URLError {
        return APIError.server(status: 0, message: "无法连接到「\(mac)」：确认 Mac 未休眠、拾景正在运行并已打开「允许手机遥控」，手机与 Mac 处于同一网络。")
    }
    return error
}

struct RunWallpaperIntent: AppIntent {
    static let title: LocalizedStringResource = "换一批壁纸"
    static let description = IntentDescription("让 Mac 上的拾景换一批新壁纸。")

    @Parameter(title: "删除不合格的原图", description: "电脑上打开了「删除不合格原图」时，这次是否真的删除；关着时只模拟筛选。", default: false)
    var deleteOriginals: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("换一批壁纸") { \.$deleteOriginals }
    }

    init() {}
    init(deleteOriginals: Bool) { self.deleteOriginals = deleteOriginals }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let dialog: String = try await withRecoveredClient { mac, client in
            let before = try await client.state(timeout: 6)
            if before.running { return "「\(mac.name)」正在更换壁纸，请等待本次更换完成。" }
            if let b = before.blocked { return "现在换不了：\(b)" }
            let s = try await client.run(deleteOriginals: deleteOriginals)
            WidgetReload.all()
            return s.running ? "好的，「\(mac.name)」开始换一批 \(s.sampleCount) 张壁纸。" : "\(s.title)"
        }
        return .result(dialog: "\(dialog)")
    }
}

struct StopWallpaperIntent: AppIntent {
    static let title: LocalizedStringResource = "停止换壁纸"
    static let description = IntentDescription("停止 Mac 上正在进行的换壁纸。")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let dialog: String = try await withRecoveredClient { mac, client in
            guard try await client.state(timeout: 6).running else { return "「\(mac.name)」当前没有在更换壁纸。" }
            _ = try await client.stop()
            WidgetReload.all()
            return "已经让「\(mac.name)」停下。"
        }
        return .result(dialog: "\(dialog)")
    }
}

struct WallpaperStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "壁纸状态"
    static let description = IntentDescription("看看 Mac 上的拾景现在在做什么、上次换得怎么样。")

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let text: String = try await withRecoveredClient { mac, client in
            let s = try await client.state(timeout: 6)
            var out: String
            if s.running {
                out = "「\(mac.name)」正在更换壁纸"
                if let l = s.label, !l.isEmpty { out += "：\(l)" }
            } else {
                out = "\(s.title)。"
                if let next = s.nextAutoDate {
                    out += "下次自动换在 \(next.formatted(.dateTime.month().day().hour().minute()))。"
                }
            }
            return out
        }
        return .result(value: text, dialog: "\(text)")
    }
}
