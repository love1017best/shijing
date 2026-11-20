import Foundation
import UserNotifications

/// 换完发通知：App 在后台（还连着）或小组件刷新时看到一次新的运行结果，就发一条本地通知。
///
/// 没有付费开发者账号就没有推送，所以只能靠「手机这边恰好看到」：App 换到后台时会多连一会儿（见 RemoteSession），
/// 小组件运行中每分钟左右刷新一次。两边共用钥匙串里「通知过的那次运行」，同一次只通知一次，按 Mac 隔离，
/// 并用进程内缓存避免每次 SSE 帧都在主线程同步查钥匙串。
enum RunNotifier {
    /// App 在前台时用户自己就看见了，不发通知（App 启动时设置；小组件里一直是 false）。
    nonisolated(unsafe) static var isForeground: () -> Bool = { false }

    private static let legacyAccount = "notified-run-at"
    /// 太久以前结束的不再通知（比如手机一整天没看，小组件才刷到电脑上的定时自动换）
    private static let freshness: TimeInterval = 15 * 60

    private static let lock = NSLock()
    /// macKey → 本进程已知至少已处理到的运行时间戳（快路径短路用，避免高频 SSE 帧重复查钥匙串；
    /// 发现更新的时间戳时仍会重读一次钥匙串，确保 App 与小组件两个进程间同步去重）
    nonisolated(unsafe) private static var cache: [String: Double] = [:]

    private static func account(for macKey: String) -> String {
        macKey.isEmpty ? legacyAccount : "\(legacyAccount).\(macKey)"
    }

    private static func cachedMark(for macKey: String) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        return cache[macKey]
    }

    private static func updateCache(_ value: Double, for macKey: String) {
        lock.lock()
        if let cur = cache[macKey], cur >= value {
            lock.unlock()
            return
        }
        cache[macKey] = value
        lock.unlock()
    }

    private static func readKeychainMark(for macKey: String) -> Double? {
        let acc = account(for: macKey)
        let stored = Keychain.data(account: acc)
            ?? (acc != legacyAccount ? Keychain.data(account: legacyAccount) : nil)
        guard let raw = stored, let val = Double(String(decoding: raw, as: UTF8.self)) else {
            return nil
        }
        updateCache(val, for: macKey)
        return val
    }

    private static func writeMark(_ value: Double, for macKey: String) {
        updateCache(value, for: macKey)
        Keychain.setData(Data(String(value).utf8), account: account(for: macKey))
    }

    static func observe(new: RemoteState, mac: String, macKey: String? = nil) {
        guard !new.running, let last = new.last else { return }
        let key = macKey ?? mac
        // 快路径：本进程已经见过这次或更新的运行，直接跳过钥匙串 I/O
        if let cached = cachedMark(for: key), last.at <= cached {
            return
        }
        // 疑似有新运行：向共享钥匙串复核一次，防止另一进程（App / 小组件）已处理过而本进程内存缓存陈旧
        guard let seen = readKeychainMark(for: key) else {
            writeMark(last.at, for: key) // 第一次：只记下，不通知以前的
            return
        }
        guard last.at > seen else { return }
        writeMark(last.at, for: key)
        guard !isForeground(), Date().timeIntervalSince1970 - last.at < freshness else { return }
        post(last, mac: mac, macKey: key)
    }

    private static func post(_ l: LastRun, mac: String, macKey: String) {
        let c = UNMutableNotificationContent()
        switch l.status {
        case "ok":
            c.title = "已更换 \(l.copied) 张壁纸"
            c.body = [l.brief, mac].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        case "stopped":
            c.title = "壁纸更换中途停止"
            c.body = l.copied > 0 ? "已更换 \(l.copied) 张 · \(mac)" : mac
        default:
            c.title = "本次未完成更换"
            c.body = l.error ?? mac
        }
        c.sound = .default
        c.threadIdentifier = "run"
        // 点开这条通知时切到概览（看这一批换上了什么）
        c.userInfo = ["target": "overview"]
        let req = UNNotificationRequest(identifier: "run-\(macKey)-\(Int(l.at))", content: c, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
