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

    static func setData(_ data: Data, account: String) {
        deleteData(account: account)
        for g in [group, nil] {
            var q = query(account, group: g)
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            if SecItemAdd(q as CFDictionary, nil) == errSecSuccess || g == nil { return }
        }
    }

    static func data(account: String) -> Data? {
        // 先找共享组；旧版本存在默认组里的，找到后挪进共享组
        for g in [group, nil] {
            var q = query(account, group: g)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: AnyObject?
            if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data {
                if g == nil, group != nil { setData(data, account: account) }
                return data
            }
        }
        return nil
    }

    static func deleteData(account: String) {
        SecItemDelete(query(account, group: group) as CFDictionary)
        SecItemDelete(query(account, group: nil) as CFDictionary)
    }

    static func set(_ token: String, for id: UUID) { setData(Data(token.utf8), account: id.uuidString) }
    static func get(_ id: UUID) -> String? { data(account: id.uuidString).flatMap { String(data: $0, encoding: .utf8) } }
    static func delete(_ id: UUID) { deleteData(account: id.uuidString) }
}

/// App 里选中的那台 Mac，给小组件和快捷指令用。
struct CurrentMac: Codable, Equatable {
    var name: String
    var host: String
    var port: Int
    var token: String

    private static let account = "current-mac"

    var address: MacAddress { MacAddress(host: host, port: port) }

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
