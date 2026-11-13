import AppIntents
import Foundation

/// 快捷指令 / Siri / 操作按钮 / 小组件按钮用的操作。都连 App 里当前选中的那台 Mac（共享钥匙串里的 CurrentMac），
/// 不打开 App；App 和小组件两个目标都编译这份代码（小组件上的按钮在小组件进程里执行）。
enum IntentError: LocalizedError {
    case noMac

    var errorDescription: String? {
        switch self {
        case .noMac: "还没有配对 Mac：先打开拾景，在 Mac 上配对一次。"
        }
    }
}

private func currentClient() throws -> (CurrentMac, APIClient) {
    guard let mac = CurrentMac.load() else { throw IntentError.noMac }
    return (mac, try mac.client())
}

/// 把网络错误换成能直接念出来的话。
private func explain(_ error: Error, mac: String) -> Error {
    if error is APIError || error is IntentError { return error }
    if error is URLError {
        return APIError.server(status: 0, message: "连不上「\(mac)」：确认 Mac 没有睡眠、拾景开着并允许手机遥控，手机和 Mac 在同一个网络里。")
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
        let (mac, client) = try currentClient()
        do {
            let before = try await client.state()
            if before.running { return .result(dialog: "「\(mac.name)」正在换壁纸，等这次换完。") }
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
        let (mac, client) = try currentClient()
        do {
            guard try await client.state().running else { return .result(dialog: "「\(mac.name)」现在没在换壁纸。") }
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
        let (mac, client) = try currentClient()
        do {
            let s = try await client.state()
            var text: String
            if s.running {
                text = "「\(mac.name)」正在换壁纸"
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
