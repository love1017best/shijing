import Foundation
import Observation

/// App 里的离线模式开关（设置页、概览标题菜单、离线提示卡都改它）。改了写进共享钥匙串、刷新小组件，
/// 并通知当前的 `RemoteSession` 断开或重新连接。
@Observable @MainActor
final class OfflineMode {
    static let shared = OfflineMode()
    static let changed = Notification.Name("OfflineModeChanged")

    var prefs: OfflinePrefs {
        didSet {
            guard prefs != oldValue else { return }
            prefs.save()
            WidgetReload.all()
            NotificationCenter.default.post(name: Self.changed, object: nil)
        }
    }

    private init() {
        prefs = OfflinePrefs.load()
    }

    var manual: Bool {
        get { prefs.manual }
        set { prefs.manual = newValue }
    }

    var onCellular: Bool {
        get { prefs.onCellular }
        set { prefs.onCellular = newValue }
    }
}

/// 现在为什么不连接电脑。
enum OfflineHold: Equatable {
    case manual
    case cellular

    var message: String {
        switch self {
        case .manual: "已打开离线模式，拾景暂停连接电脑。"
        case .cellular: "正在使用蜂窝网络，拾景暂停连接电脑；连接 Wi‑Fi 后自动连接。"
        }
    }
}

/// 离线模式下发请求：在发出之前就失败，不等网络超时。
struct OfflineHoldError: LocalizedError {
    var errorDescription: String? { "已暂停连接电脑（离线模式），退出离线模式后再操作。" }
}
