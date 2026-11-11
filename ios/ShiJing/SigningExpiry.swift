import Foundation
import UserNotifications

/// 免费签名的 App 7 天后打不开：从安装包里的描述文件（embedded.mobileprovision）读出到期时间，
/// 界面上提前提醒，并在到期前一天发一条本地通知。从 App Store / TestFlight 装的没有这个文件，就什么都不显示。
enum SigningExpiry {
    static let date: Date? = {
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("-demoExpiring") { return Date().addingTimeInterval(36 * 3600) }
        #endif
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return nil }
        // 文件是 CMS 签名包着的 XML plist，直接截出 <?xml … </plist> 那一段
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else { return nil }
        let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil)
        return (plist as? [String: Any])?["ExpirationDate"] as? Date
    }()

    /// 还剩不到这么久时概览顶部显示提醒
    static let warnBefore: TimeInterval = 2 * 86400

    static var isSoon: Bool { date.map { $0.timeIntervalSinceNow < warnBefore } ?? false }
    static var isExpired: Bool { date.map { $0 < Date() } ?? false }

    /// 「11月18日 17:21 到期」
    static var text: String? {
        date.map { $0.formatted(.dateTime.month().day().hour().minute()) + " 到期" }
    }

    /// 到期前一天提醒重新安装（每次启动重排一次，重新安装后时间也就跟着更新了）。
    static func scheduleReminder() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["signing-expiry"])
        guard let date, case let fire = date.addingTimeInterval(-86400), fire > Date() else { return }
        let c = UNMutableNotificationContent()
        c.title = "拾景明天就打不开了"
        c.body = "免费签名 7 天到期（\(date.formatted(.dateTime.month().day().hour().minute()))）。连上电脑重新安装一次就能续上。"
        c.sound = .default
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
        center.add(UNNotificationRequest(identifier: "signing-expiry", content: c,
                                         trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
    }
}
