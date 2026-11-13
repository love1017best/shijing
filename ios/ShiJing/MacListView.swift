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

/// 已配对的 Mac：点一台切换过去，左滑或长按移除。
struct ManageMacsView: View {
    let store: MacStore
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
                        }
                        .contextMenu {
                            Button("移除这台 Mac", systemImage: "trash", role: .destructive) { store.remove(mac.id) }
                        }
                    }
                } footer: {
                    Text("移除后要在电脑上重新配对才能再连。电脑上的拾景也可以在「设置 › 手机遥控」里取消这台手机的配对。")
                }
            }
            .navigationTitle("已配对的 Mac")
            .iOSInlineTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
        .onChange(of: store.macs.isEmpty) { _, empty in if empty { dismiss() } }
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
        .onChange(of: store.macs.count) { old, new in
            if new > old { dismiss() }
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
        discovery.found.filter { store.mac(serviceName: $0.name) == nil }
    }

    var body: some View {
        Section {
            ForEach(unpaired) { found in
                Button {
                    flow.pairing = PairTarget(name: found.name, serviceName: found.name, endpoint: found.endpoint)
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
            Text("附近的 Mac")
        } footer: {
            if let p = discovery.problem {
                Text(p)
            } else {
                Text("电脑上的拾景要打开「设置 › 手机遥控」，手机和电脑连同一个网络。找不到时可以在电脑上点「显示二维码」，直接扫一扫。")
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
            onNext(PairTarget(name: info.name, serviceName: nil, address: addr))
        } catch {
            self.error = RemoteSession.describe(error)
        }
    }
}
