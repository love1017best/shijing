import SwiftUI

/// 左栏：配对过的 Mac + 局域网里找到的、还没配对的 Mac + 手动添加。
struct MacListView: View {
    let store: MacStore
    let discovery: Discovery
    @State private var pairing: PairTarget?
    @State private var manual = false

    private var unpaired: [Discovery.Found] {
        discovery.found.filter { store.mac(serviceName: $0.name) == nil }
    }

    var body: some View {
        List(selection: Binding(get: { store.selectedID }, set: { store.selectedID = $0 })) {
            if !store.macs.isEmpty {
                Section("已配对") {
                    ForEach(store.macs) { mac in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mac.name)
                                Text("\(mac.host):\(String(mac.port))").font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "desktopcomputer")
                        }
                        .tag(mac.id)
                        .swipeActions {
                            Button("移除", role: .destructive) { store.remove(mac.id) }
                        }
                        .contextMenu {
                            Button("移除这台 Mac", systemImage: "trash", role: .destructive) { store.remove(mac.id) }
                        }
                    }
                }
            }
            Section {
                ForEach(unpaired) { found in
                    Button {
                        pairing = PairTarget(name: found.name, serviceName: found.name, endpoint: found.endpoint)
                    } label: {
                        Label {
                            Text(found.name)
                        } icon: {
                            Image(systemName: "plus.circle")
                        }
                    }
                }
                if unpaired.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("正在局域网里找拾景…").foregroundStyle(.secondary)
                    }
                }
                Button("手动输入地址…", systemImage: "keyboard") { manual = true }
            } header: {
                Text("附近的 Mac")
            } footer: {
                if let p = discovery.problem {
                    Text(p)
                } else {
                    Text("电脑上的拾景要打开「设置 › 手机遥控」，手机和电脑连同一个网络。")
                }
            }
        }
        .sheet(item: $pairing) { target in
            PairView(target: target, store: store)
        }
        .sheet(isPresented: $manual) {
            ManualAddView { target in
                manual = false
                // 等手动输入的表单收起再弹配对
                Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    pairing = target
                }
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
