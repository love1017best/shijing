import Foundation
import Network

/// 手机上的离线模式：手动离线、使用蜂窝网络时离线。打开后 App 和小组件都停止连接电脑，
/// 只显示手机上缓存的状态和图片；离线时记下的整理操作照常排队，退出离线模式、连接电脑后处理。
/// 小组件读不到 App 的 UserDefaults，所以存在共享钥匙串里。
struct OfflinePrefs: Codable, Equatable {
    /// 用户手动打开的离线模式
    var manual = false
    /// 只有蜂窝网络（没有 Wi‑Fi、有线）时离线：电脑在局域网里，这时连接只会反复超时、耗电
    var onCellular = true

    private static let account = "offline-prefs"

    static func load() -> OfflinePrefs {
        Keychain.data(account: account).flatMap { try? JSONDecoder().decode(OfflinePrefs.self, from: $0) } ?? OfflinePrefs()
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        Keychain.setData(data, account: Self.account)
    }

    /// 当前网络只有蜂窝（没有 Wi‑Fi、有线）。
    static func cellularOnly(_ path: NWPath) -> Bool {
        path.status == .satisfied && path.usesInterfaceType(.cellular)
            && !path.usesInterfaceType(.wifi) && !path.usesInterfaceType(.wiredEthernet)
    }

    /// 按设置和当前网络，这次该不该离线。小组件每次排时间线前调用一次，最多等 1 秒读网络状态。
    static func holdNow() async -> Bool {
        let prefs = load()
        if prefs.manual { return true }
        guard prefs.onCellular else { return false }
        return await currentlyCellularOnly()
    }

    private static func currentlyCellularOnly() async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let monitor = NWPathMonitor()
            let once = Once()
            monitor.pathUpdateHandler = { path in
                if once.take() { monitor.cancel(); cont.resume(returning: cellularOnly(path)) }
            }
            monitor.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if once.take() { monitor.cancel(); cont.resume(returning: false) }
            }
        }
    }

    /// 两个回调里只有先到的那个生效。
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func take() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }
}
