import Foundation
import UserNotifications

/// 换完发通知：App 在后台（还连着）或小组件刷新时看到一次新的运行结果，就发一条本地通知。
///
/// 没有付费开发者账号就没有推送，所以只能靠「手机这边恰好看到」：App 换到后台时会多连一会儿（见 RemoteSession），
/// 小组件运行中每分钟左右刷新一次。两边共用钥匙串里「通知过的那次运行」，同一次只通知一次。
enum RunNotifier {
    /// App 在前台时用户自己就看见了，不发通知（App 启动时设置；小组件里一直是 false）。
    nonisolated(unsafe) static var isForeground: () -> Bool = { false }

    private static let account = "notified-run-at"
    /// 太久以前结束的不再通知（比如手机一整天没看，小组件才刷到电脑上的定时自动换）
    private static let freshness: TimeInterval = 15 * 60

    private static var mark: Double? {
        get { Keychain.data(account: account).flatMap { Double(String(decoding: $0, as: UTF8.self)) } }
        set { if let v = newValue { Keychain.setData(Data(String(v).utf8), account: account) } }
    }

    static func observe(old: RemoteState?, new: RemoteState, mac: String) {
        guard !new.running, let last = new.last else { return }
        guard let seen = mark else {
            mark = last.at // 第一次：只记下，不通知以前的
            return
        }
        guard last.at > seen else { return }
        mark = last.at
        guard !isForeground(), Date().timeIntervalSince1970 - last.at < freshness else { return }
        post(last, mac: mac)
    }

    private static func post(_ l: LastRun, mac: String) {
        let c = UNMutableNotificationContent()
        switch l.status {
        case "ok":
            c.title = "换上了 \(l.copied) 张新壁纸"
            c.body = [l.brief, mac].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        case "stopped":
            c.title = "换壁纸中途停止了"
            c.body = l.copied > 0 ? "换上了 \(l.copied) 张 · \(mac)" : mac
        default:
            c.title = "壁纸没有换成"
            c.body = l.error ?? mac
        }
        c.sound = .default
        c.threadIdentifier = "run"
        let req = UNNotificationRequest(identifier: "run-\(Int(l.at))", content: c, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
