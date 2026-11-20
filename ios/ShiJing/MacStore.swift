import Foundation
import Observation

/// 配对过的 Mac 列表（UserDefaults）和它们的令牌（钥匙串）。
@Observable @MainActor
final class MacStore {
    private(set) var macs: [SavedMac] = []
    /// 每次配对（含同台 Mac 重新配对）递增，让会话重建连接、添加页自动关闭。
    private(set) var pairRevision = 0
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
        syncFromCurrentMac()
        publishCurrent()
    }

    var selected: SavedMac? { macs.first { $0.id == selectedID } }

    func mac(serviceName: String) -> SavedMac? { macs.first { $0.serviceName == serviceName } }

    /// 判断局域网里发现的 Mac 是否已经配对过：优先按 serverID 匹配，无 serverID 时退回 serviceName。
    func isPaired(serverID: String?, serviceName: String) -> Bool {
        if let serverID, !serverID.isEmpty, macs.contains(where: { $0.serverID == serverID }) {
            return true
        }
        return macs.contains { $0.serviceName == serviceName }
    }

    /// 配对成功：同一台 Mac（同一 serverID、同一服务名或同一地址）重新配对时替换旧的那条，保留本地 ID 与缓存。
    @discardableResult
    func add(name: String, serverID: String? = nil, serviceName: String?, address: MacAddress, token: String) -> SavedMac {
        let cleanSID = serverID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sid = (cleanSID?.isEmpty == false) ? cleanSID : nil
        let cleanSvc = serviceName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let svc = (cleanSvc?.isEmpty == false) ? cleanSvc : (name.isEmpty ? nil : name)

        let old = macs.first {
            (sid != nil && $0.serverID == sid)
                || (svc != nil && $0.serviceName == svc)
                || ($0.host == address.host && $0.port == address.port)
        }
        var mac = SavedMac(
            name: name,
            serverID: sid ?? old?.serverID,
            serviceName: svc ?? old?.serviceName,
            host: address.host,
            port: address.port
        )
        if let old {
            mac.id = old.id
            macs.removeAll { $0.id == old.id }
        }
        macs.append(mac)
        Keychain.set(token, for: mac.id)
        tokens[mac.id] = token
        save()
        selectedID = mac.id
        pairRevision += 1
        return mac
    }

    /// 更新已配对 Mac 的地址、名称或身份信息（Bonjour 自动重定位、老数据回填、手动修改地址共用）。
    @discardableResult
    func update(
        _ id: SavedMac.ID,
        address: MacAddress? = nil,
        name: String? = nil,
        serverID: String? = nil,
        serviceName: String? = nil
    ) -> SavedMac? {
        guard let i = macs.firstIndex(where: { $0.id == id }) else { return nil }
        var changed = false
        if let address, macs[i].host != address.host || macs[i].port != address.port {
            macs[i].host = address.host
            macs[i].port = address.port
            changed = true
        }
        if let name, !name.isEmpty, macs[i].name != name {
            macs[i].name = name
            changed = true
        }
        if let serverID, !serverID.isEmpty, macs[i].serverID != serverID {
            macs[i].serverID = serverID
            changed = true
        }
        if let serviceName, !serviceName.isEmpty, macs[i].serviceName != serviceName {
            macs[i].serviceName = serviceName
            changed = true
        }
        if changed {
            save()
        }
        return macs[i]
    }

    /// 主 App 启动或回到前台时，若小组件/快捷指令在后台已通过 Bonjour 更新了共享钥匙串里的地址，同步回 MacStore。
    func syncFromCurrentMac() {
        guard let cur = CurrentMac.load() else { return }
        let idx: Int? = if let curID = cur.id {
            macs.firstIndex { $0.id == curID }
        } else if let sid = cur.serverID, !sid.isEmpty {
            macs.firstIndex { $0.serverID == sid }
        } else {
            nil
        }
        guard let i = idx else { return }
        var changed = false
        if macs[i].host != cur.host || macs[i].port != cur.port {
            macs[i].host = cur.host
            macs[i].port = cur.port
            changed = true
        }
        if !cur.name.isEmpty, macs[i].name != cur.name {
            macs[i].name = cur.name
            changed = true
        }
        if let sid = cur.serverID, !sid.isEmpty, macs[i].serverID != sid {
            macs[i].serverID = sid
            changed = true
        }
        if let svc = cur.serviceName, !svc.isEmpty, macs[i].serviceName != svc {
            macs[i].serviceName = svc
            changed = true
        }
        if changed, let data = try? JSONEncoder().encode(macs) {
            UserDefaults.standard.set(data, forKey: Self.macsKey)
        }
    }

    func remove(_ id: SavedMac.ID) {
        macs.removeAll { $0.id == id }
        Keychain.delete(id)
        tokens[id] = nil
        OfflineStore.shared.clear(id.uuidString) // 离线快照和记录缓存也一起清掉
        ImageStore.shared.clear(macID: id.uuidString) // 这台 Mac 的磁盘图片缓存也一起清掉
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
        CurrentMac(
            id: mac.id,
            name: mac.name,
            serverID: mac.serverID,
            serviceName: mac.serviceName,
            host: mac.host,
            port: mac.port,
            token: token
        ).save()
    }
}
