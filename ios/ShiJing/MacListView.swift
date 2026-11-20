import Observation
import SwiftUI

/// 还没配对过任何 Mac 时的首页：列出局域网里找到的拾景，点一台配对，或者手动输入地址。
struct SetupView: View {
    let store: MacStore
    let discovery: Discovery
    @State private var flow = NearbyFlow()
    /// 截图用：-demoScan 一进来就打开扫码页，只开一次
    @State private var demoScanOpened = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.largeTitle)
                            .foregroundStyle(.tint)
                        Text("在手机上遥控电脑上的拾景：换一批壁纸、看当前的壁纸、整理不想要的。")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
                NearbySection(store: store, discovery: discovery, flow: flow)
            }
            .navigationTitle("拾景")
            // 内屏、iPad 上内容别拉得太宽（只收窄内容，背景照样铺满）
            .contentWidthCap(max: 640)
        }
        .nearbyPresenters(store: store, flow: flow)
        .onAppear {
            discovery.want("setup", true)
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-demoPair") {
                flow.pairing = PairTarget(name: "MacBook Pro", serviceName: nil,
                                          address: MacAddress(host: "192.168.1.20", port: 52819))
            }
            if !demoScanOpened, ProcessInfo.processInfo.arguments.contains("-demoScan") {
                demoScanOpened = true
                // 等局域网搜索结果出来再打开：模拟「已经看到 Mac 列表后再点扫码」的时序
                Task {
                    try? await Task.sleep(for: .seconds(4))
                    flow.scanning = true
                }
            }
            #endif
        }
        .onDisappear { discovery.want("setup", false) }
    }
}

extension View {
    /// 遥控面板的标题菜单（点顶部的 Mac 名字）：切换 Mac、添加其他 Mac、管理已配对的。
    func macTitleMenu(store: MacStore, discovery: Discovery) -> some View {
        modifier(MacTitleMenu(store: store, discovery: discovery))
    }
}

private struct MacTitleMenu: ViewModifier {
    let store: MacStore
    let discovery: Discovery
    @State private var adding = false
    @State private var managing = false

    func body(content: Content) -> some View {
        content
            .toolbarTitleMenu {
                if store.macs.count > 1 {
                    Picker("切换 Mac", selection: Binding(get: { store.selectedID }, set: { store.selectedID = $0 })) {
                        ForEach(store.macs) { mac in
                            Label(mac.name, systemImage: "desktopcomputer").tag(Optional(mac.id))
                        }
                    }
                    Divider()
                }
                Toggle(isOn: Binding(get: { OfflineMode.shared.manual }, set: { OfflineMode.shared.manual = $0 })) {
                    Label("离线模式", systemImage: "wifi.slash")
                }
                Divider()
                Button("添加其他 Mac…", systemImage: "plus") { adding = true }
                Button("管理已配对的 Mac…", systemImage: "list.bullet") { managing = true }
            }
            .sheet(isPresented: $adding) {
                AddMacView(store: store, discovery: discovery)
            }
            .sheet(isPresented: $managing) {
                ManageMacsView(store: store)
            }
    }
}

/// 已配对的 Mac：点一台切换过去，左滑或长按修改地址、移除。
struct ManageMacsView: View {
    let store: MacStore
    @State private var editing: SavedMac?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.macs) { mac in
                        Button {
                            store.selectedID = mac.id
                            dismiss()
                        } label: {
                            HStack {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(mac.name).foregroundStyle(.primary)
                                        Text("\(mac.host):\(String(mac.port))").font(.caption).foregroundStyle(.secondary)
                                    }
                                } icon: {
                                    Image(systemName: "desktopcomputer")
                                }
                                Spacer()
                                if mac.id == store.selectedID {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                        .swipeActions {
                            Button("移除", role: .destructive) { store.remove(mac.id) }
                            Button("修改地址") { editing = mac }.tint(.blue)
                        }
                        .contextMenu {
                            Button("修改地址…", systemImage: "network") { editing = mac }
                            Button("移除这台 Mac", systemImage: "trash", role: .destructive) { store.remove(mac.id) }
                        }
                    }
                } footer: {
                    Text("同一局域网内 Mac 更换地址后会自动更新；跨网段或使用 VPN 时，可长按或左滑修改地址。移除后需重新配对。")
                }
            }
            .navigationTitle("已配对的 Mac")
            .iOSInlineTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
        .sheet(item: $editing) { mac in
            EditMacAddressView(mac: mac, store: store)
        }
        .onChange(of: store.macs.isEmpty) { _, empty in if empty { dismiss() } }
    }
}

/// 手动修改已配对 Mac 的 IP 和端口（跨网段、VPN 场景保留原有令牌、缓存和离线队列）。
private struct EditMacAddressView: View {
    let mac: SavedMac
    let store: MacStore
    @State private var host: String
    @State private var port: String
    @State private var checking = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(mac: SavedMac, store: MacStore) {
        self.mac = mac
        self.store = store
        _host = State(initialValue: mac.host)
        _port = State(initialValue: String(mac.port))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Mac", value: mac.name)
                }
                Section {
                    TextField("IP 地址，比如 192.168.1.20", text: $host)
                        .autocorrectionDisabled()
                        .iOSKeyboard(.numbersAndPunctuation)
                    TextField("端口", text: $port)
                        .iOSKeyboard(.numberPad)
                } footer: {
                    Text("保存前会连接新地址核对身份，原有的配对令牌、本地缓存和待处理操作都会保留。")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("修改地址")
            .iOSInlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if checking {
                        ProgressView()
                    } else {
                        Button("保存") { Task { await save() } }
                            .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty || Int(port) == nil)
                    }
                }
            }
        }
    }

    private func save() async {
        checking = true
        defer { checking = false }
        error = nil
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanHost.isEmpty, let portNum = Int(port.trimmingCharacters(in: .whitespacesAndNewlines)), (1...65535).contains(portNum) else {
            error = "请输入有效的 IP 地址和端口。"
            return
        }
        let addr = MacAddress(host: cleanHost, port: portNum)
        do {
            let info = try await APIClient(address: addr, token: nil).info()
            guard info.app == "拾景" else {
                error = "这个地址上不是拾景。"
                return
            }
            if let expectedID = mac.serverID, !expectedID.isEmpty,
               let actualID = info.serverId, !actualID.isEmpty,
               expectedID != actualID {
                error = "这个地址上是另一台 Mac（\(info.name)），无法替换当前配对。"
                return
            }
            store.update(
                mac.id,
                address: addr,
                name: info.name,
                serverID: info.serverId ?? mac.serverID,
                serviceName: mac.serviceName ?? info.name
            )
            dismiss()
        } catch {
            self.error = RemoteSession.describe(error)
        }
    }
}

/// 「添加其他 Mac」：打开时才在局域网里找，配对成功后自动关闭。
struct AddMacView: View {
    let store: MacStore
    let discovery: Discovery
    @State private var flow = NearbyFlow()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                NearbySection(store: store, discovery: discovery, flow: flow)
            }
            .navigationTitle("添加 Mac")
            .iOSInlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            }
        }
        .nearbyPresenters(store: store, flow: flow)
        .onAppear { discovery.want("add", true) }
        .onDisappear { discovery.want("add", false) }
        .onChange(of: store.pairRevision) { _, _ in
            dismiss()
        }
    }
}

/// 「附近的 Mac」三个弹层（配对、手动输入、扫码）的状态。弹层要挂在 SetupView / AddMacView
/// 这种稳定的容器上，不能挂在这个 Section 上：局域网搜索结果一变，List 的行会被重建，
/// 挂在行里的弹层会跟着自己关掉（扫码页开着时「附近」刚好找到了 Mac，相机界面就闪退了）。
@Observable @MainActor
final class NearbyFlow {
    var pairing: PairTarget?
    var manual = false
    var scanning = false
}

private struct NearbyPresenters: ViewModifier {
    let store: MacStore
    let flow: NearbyFlow

    func body(content: Content) -> some View {
        @Bindable var flow = flow
        content
            .fullScreenCoverCompat(isPresented: $flow.scanning) {
                QRScanView(store: store)
            }
            .sheet(item: $flow.pairing) { target in
                PairView(target: target, store: store)
            }
            .sheet(isPresented: $flow.manual) {
                ManualAddView { target in
                    flow.manual = false
                    // 等手动输入的表单收起再弹配对
                    Task {
                        try? await Task.sleep(for: .milliseconds(400))
                        flow.pairing = target
                    }
                }
            }
    }
}

extension View {
    func nearbyPresenters(store: MacStore, flow: NearbyFlow) -> some View {
        modifier(NearbyPresenters(store: store, flow: flow))
    }
}

/// 附近找到的、还没配对的 Mac，加上手动输入地址。搜索的开关由显示它的界面用 discovery.want 管。
struct NearbySection: View {
    let store: MacStore
    let discovery: Discovery
    let flow: NearbyFlow

    private var unpaired: [Discovery.Found] {
        discovery.found.filter { !store.isPaired(serverID: $0.serverID, serviceName: $0.name) }
    }

    var body: some View {
        Section {
            ForEach(unpaired) { found in
                Button {
                    flow.pairing = PairTarget(
                        name: found.name,
                        serverID: found.serverID,
                        serviceName: found.name,
                        endpoint: found.endpoint
                    )
                } label: {
                    Label(found.name, systemImage: "plus.circle")
                }
            }
            if unpaired.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在局域网里找拾景…").foregroundStyle(.secondary)
                }
            }
            Button("扫描电脑上的二维码…", systemImage: "qrcode.viewfinder") { flow.scanning = true }
            Button("手动输入地址…", systemImage: "keyboard") { flow.manual = true }
        } header: {
            HelpHeader("附近的 Mac", "电脑上的拾景要打开「设置 › 手机遥控」，手机和电脑连同一个网络。找不到时可以在电脑上点「显示二维码」，用手机扫码配对。")
        } footer: {
            // 只有搜索出问题时才占一行；上面那段怎么连的说明收进了问号
            if let p = discovery.problem {
                Text(p)
            }
        }
    }
}

/// 手动输入 IP 和端口（Bonjour 找不到时，比如手机连着 VPN）。
struct ManualAddView: View {
    let onNext: (PairTarget) -> Void
    @State private var host = ""
    @State private var port = "52819"
    @State private var checking = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("IP 地址，比如 192.168.1.20", text: $host)
                        .autocorrectionDisabled()
                        .iOSKeyboard(.numbersAndPunctuation)
                    TextField("端口", text: $port)
                        .iOSKeyboard(.numberPad)
                } footer: {
                    Text("地址显示在电脑上拾景的「设置 › 手机遥控」里。")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("手动添加")
            .iOSInlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if checking {
                        ProgressView()
                    } else {
                        Button("下一步") { Task { await check() } }
                            .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty || Int(port) == nil)
                    }
                }
            }
        }
    }

    private func check() async {
        checking = true
        defer { checking = false }
        let addr = MacAddress(host: host.trimmingCharacters(in: .whitespaces), port: Int(port) ?? 52819)
        do {
            let info = try await APIClient(address: addr, token: nil).info()
            guard info.app == "拾景" else {
                error = "这个地址上不是拾景。"
                return
            }
            onNext(PairTarget(name: info.name, serverID: info.serverId, serviceName: info.name, address: addr))
        } catch {
            self.error = RemoteSession.describe(error)
        }
    }
}
