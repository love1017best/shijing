import Foundation
import Observation
import Security

/// 配对过的 Mac 列表（UserDefaults）和它们的令牌（钥匙串）。
@Observable @MainActor
final class MacStore {
    private(set) var macs: [SavedMac] = []
    var selectedID: SavedMac.ID? {
        didSet { UserDefaults.standard.set(selectedID?.uuidString, forKey: Self.selectedKey) }
    }

    private static let macsKey = "savedMacs"
    private static let selectedKey = "selectedMac"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.macsKey),
           let list = try? JSONDecoder().decode([SavedMac].self, from: data) {
            macs = list
        }
        if let s = UserDefaults.standard.string(forKey: Self.selectedKey), let id = UUID(uuidString: s),
           macs.contains(where: { $0.id == id }) {
            selectedID = id
        } else {
            selectedID = macs.first?.id
        }
    }

    var selected: SavedMac? { macs.first { $0.id == selectedID } }

    func mac(serviceName: String) -> SavedMac? { macs.first { $0.serviceName == serviceName } }

    /// 配对成功：同一台 Mac（同一个服务名或同一个地址）重新配对时替换旧的那条。
    @discardableResult
    func add(name: String, serviceName: String?, address: MacAddress, token: String) -> SavedMac {
        let old = macs.first {
            (serviceName != nil && $0.serviceName == serviceName) || ($0.host == address.host && $0.port == address.port)
        }
        var mac = SavedMac(name: name, serviceName: serviceName, host: address.host, port: address.port)
        if let old {
            mac.id = old.id
            macs.removeAll { $0.id == old.id }
        }
        macs.append(mac)
        Keychain.set(token, for: mac.id)
        save()
        selectedID = mac.id
        return mac
    }

    /// Mac 的 IP 变了：更新记住的地址。
    func update(_ id: SavedMac.ID, address: MacAddress) {
        guard let i = macs.firstIndex(where: { $0.id == id }),
              macs[i].host != address.host || macs[i].port != address.port else { return }
        macs[i].host = address.host
        macs[i].port = address.port
        save()
    }

    func remove(_ id: SavedMac.ID) {
        macs.removeAll { $0.id == id }
        Keychain.delete(id)
        if selectedID == id { selectedID = macs.first?.id }
        save()
    }

    func token(for id: SavedMac.ID) -> String? { Keychain.get(id) }

    private func save() {
        if let data = try? JSONEncoder().encode(macs) {
            UserDefaults.standard.set(data, forKey: Self.macsKey)
        }
    }
}

/// 令牌存在钥匙串里，每台 Mac 一条。
enum Keychain {
    private static let service = "com.love1017best.shijing.ios.token"

    private static func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString]
    }

    static func set(_ token: String, for id: UUID) {
        delete(id)
        var q = query(id)
        q[kSecValueData as String] = Data(token.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    static func get(_ id: UUID) -> String? {
        var q = query(id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ id: UUID) {
        SecItemDelete(query(id) as CFDictionary)
    }
}
