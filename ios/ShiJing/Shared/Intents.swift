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

private func currentClient() async throws -> (CurrentMac, APIClient) {
    if let reason = await OfflinePrefs.holdReasonNow() {
        throw IntentError.offline(reason)
    }
    guard let mac = CurrentMac.load() else { throw IntentError.noMac }
    return (mac, try mac.client())
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
        let (mac, client) = try await currentClient()
        do {
            let before = try await client.state()
            if before.running { return .result(dialog: "「\(mac.name)」正在更换壁纸，请等待本次更换完成。") }
            if let b = before.blocked { return .result(dialog: "现在换不了：\(b)") }
            let s = try await client.run(deleteOriginals: deleteOriginals)
            WidgetReload.all()
            return .result(dialog: s.running ? "好的，「\(mac.name)」开始换一批 \(s.sampleCount) 张壁纸。" : "\(s.title)")
        } catch {
            throw explain(error, mac: mac.name)
        }
    }
}

struct StopWallpaperIntent: AppIntent {
    static let title: LocalizedStringResource = "停止换壁纸"
    static let description = IntentDescription("停止 Mac 上正在进行的换壁纸。")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let (mac, client) = try await currentClient()
        do {
            guard try await client.state().running else { return .result(dialog: "「\(mac.name)」当前没有在更换壁纸。") }
            _ = try await client.stop()
            WidgetReload.all()
            return .result(dialog: "已经让「\(mac.name)」停下。")
        } catch {
            throw explain(error, mac: mac.name)
        }
    }
}

struct WallpaperStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "壁纸状态"
    static let description = IntentDescription("看看 Mac 上的拾景现在在做什么、上次换得怎么样。")

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let (mac, client) = try await currentClient()
        do {
            let s = try await client.state()
            var text: String
            if s.running {
                text = "「\(mac.name)」正在更换壁纸"
                if let l = s.label, !l.isEmpty { text += "：\(l)" }
            } else {
                text = "\(s.title)。"
                if let next = s.nextAutoDate {
                    text += "下次自动换在 \(next.formatted(.dateTime.month().day().hour().minute()))。"
                }
            }
            return .result(value: text, dialog: "\(text)")
        } catch {
            throw explain(error, mac: mac.name)
        }
    }
}
