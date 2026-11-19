import Foundation
import Security

/// 钥匙串：配对令牌（每台 Mac 一条），以及给小组件、快捷指令用的「当前这台 Mac」。
///
/// 存在 App 和小组件共享的钥匙串组里（免费签名没有 App Groups，钥匙串共享可以用）。
/// 组名带团队前缀，构建时写进 Info.plist 的 ShiJingKeychainGroup；模拟器等没签名的情况下退回默认组。
enum Keychain {
    private static let service = "com.love1017best.shijing.ios.token"

    static let group: String? = {
        guard let g = Bundle.main.object(forInfoDictionaryKey: "ShiJingKeychainGroup") as? String,
              !g.hasPrefix("."), !g.hasPrefix("$") else { return nil }
        return g
    }()

    private static func query(_ account: String, group: String?) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        if let group { q[kSecAttrAccessGroup as String] = group }
        return q
    }

    private static func write(_ data: Data, account: String, group: String?) -> OSStatus {
        let base = query(account, group: group)
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        // 优先原地更新，避免先删后加期间小组件并发读到 nil；仅不存在时再新增。
        var status = SecItemUpdate(base as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
            if status == errSecDuplicateItem {
                status = SecItemUpdate(base as CFDictionary, attrs as CFDictionary)
            }
        }
        return status
    }

    static func setData(_ data: Data, account: String) {
        // 注意：绝不能在写入共享组成功后对 group: nil 调用 SecItemDelete。
        // SecItemDelete 省略 kSecAttrAccessGroup 时会删除当前进程有权访问的所有组里的匹配项，包括刚写入的共享组。
        if let group, write(data, account: account, group: group) == errSecSuccess {
            return
        }
        _ = write(data, account: account, group: nil)
    }

    private static func copyData(account: String, group: String) -> Data? {
        var q = query(account, group: group)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func data(account: String) -> Data? {
        // 先查共享组；旧版本存在其它组里的，找到后迁进共享组并按其精确组名删除旧副本。
        if let group, let data = copyData(account: account, group: group) {
            return data
        }
        var q = query(account, group: nil)
        q[kSecReturnData as String] = true
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let dict = out as? [String: Any],
              let data = dict[kSecValueData as String] as? Data else {
            return nil
        }
        if let group {
            let foundGroup = dict[kSecAttrAccessGroup as String] as? String
            if foundGroup != group, write(data, account: account, group: group) == errSecSuccess,
               let oldGroup = foundGroup, !oldGroup.isEmpty {
                SecItemDelete(query(account, group: oldGroup) as CFDictionary)
            }
        }
        return data
    }

    static func deleteData(account: String) {
        if let group {
            SecItemDelete(query(account, group: group) as CFDictionary)
        }
        SecItemDelete(query(account, group: nil) as CFDictionary)
    }

    static func set(_ token: String, for id: UUID) { setData(Data(token.utf8), account: id.uuidString) }
    static func get(_ id: UUID) -> String? { data(account: id.uuidString).flatMap { String(data: $0, encoding: .utf8) } }
    static func delete(_ id: UUID) { deleteData(account: id.uuidString) }
}

/// App 里选中的那台 Mac，给小组件和快捷指令用。
struct CurrentMac: Codable, Equatable {
    /// Mac 的固定标识（旧版本钥匙串记录没有这个字段，解码时为 nil）
    var id: UUID?
    var name: String
    var host: String
    var port: Int
    var token: String

    private static let account = "current-mac"

    var address: MacAddress { MacAddress(host: host, port: port) }

    /// 小组件缓存用的稳定键：优先按 Mac 的固定 ID，换 IP 或端口不断档；旧记录退回 host:port
    var cacheKey: String { id?.uuidString ?? "\(host):\(port)" }

    func client() throws -> APIClient { try APIClient(address: address, token: token) }

    func save() {
        guard Self.load() != self, let data = try? JSONEncoder().encode(self) else { return }
        Keychain.setData(data, account: Self.account)
        Self.changed()
    }

    static func load() -> CurrentMac? {
        Keychain.data(account: account).flatMap { try? JSONDecoder().decode(CurrentMac.self, from: $0) }
    }

    static func clear() {
        guard load() != nil else { return }
        Keychain.deleteData(account: account)
        changed()
    }

    /// 换了 Mac：让小组件重新取状态。
    private static func changed() {
        #if canImport(WidgetKit)
        WidgetReload.all()
        #endif
    }
}
