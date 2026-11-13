import Foundation
import Observation

/// 配对过的 Mac 列表（UserDefaults）和它们的令牌（钥匙串）。
@Observable @MainActor
final class MacStore {
    private(set) var macs: [SavedMac] = []
    var selectedID: SavedMac.ID? {
        didSet {
            UserDefaults.standard.set(selectedID?.uuidString, forKey: Self.selectedKey)
            publishCurrent()
        }
    }

    private static let macsKey = "savedMacs"
    private static let selectedKey = "selectedMac"

    /// 令牌读一次就记住：`token(for:)` 会被 `client()` 频繁调用（每张图加载、每次请求），
    /// 每次都查钥匙串（同步、可能几十毫秒）会卡住主线程。令牌只在配对和取消配对时变。
    @ObservationIgnored private var tokens: [SavedMac.ID: String] = [:]

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
        publishCurrent()
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
        tokens[mac.id] = token
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
        tokens[id] = nil
        OfflineStore.shared.clear(id.uuidString) // 离线快照和记录缓存也一起清掉
        RemoteSession.clearQueue(id) // 还没补上的离线操作也不用留了
        if selectedID == id { selectedID = macs.first?.id }
        save()
    }

    func token(for id: SavedMac.ID) -> String? {
        if let t = tokens[id] { return t }
        guard let t = Keychain.get(id) else { return nil }
        tokens[id] = t
        return t
    }

    private func save() {
        if let data = try? JSONEncoder().encode(macs) {
            UserDefaults.standard.set(data, forKey: Self.macsKey)
        }
        publishCurrent()
    }

    /// 把选中的这台 Mac（地址和令牌）写进共享钥匙串，小组件和快捷指令用它（它们读不到这里的 UserDefaults）。
    private func publishCurrent() {
        guard let mac = selected, let token = token(for: mac.id) else {
            CurrentMac.clear()
            return
        }
        CurrentMac(name: mac.name, host: mac.host, port: mac.port, token: token).save()
    }
}
