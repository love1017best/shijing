import Network
import SwiftUI

/// 要配对的那台 Mac：从 Bonjour 找到的（endpoint）或手动输入的（address）。
struct PairTarget: Identifiable {
    var name: String
    var serviceName: String?
    var endpoint: NWEndpoint?
    var address: MacAddress?
    var id: String { serviceName ?? address.map { "\($0.host):\($0.port)" } ?? name }
}

/// 配对：请求后电脑上弹出 6 位配对码，在这里输入。
struct PairView: View {
    let target: PairTarget
    let store: MacStore
    @State private var device = Self.defaultDeviceName
    @State private var address: MacAddress?
    @State private var requested = false
    @State private var code = ""
    @State private var working = false
    @State private var error: String?
    @FocusState private var codeFocused: Bool
    @Environment(\.dismiss) private var dismiss

    static var defaultDeviceName: String {
        #if os(iOS)
        UIDevice.current.name // iOS 16 起没有特殊授权只会返回「iPhone」，可以在这里改
        #else
        "iPhone"
        #endif
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Mac", value: target.name)
                    TextField("这台手机的名字", text: $device)
                        .disabled(requested)
                } footer: {
                    Text("名字会显示在电脑的「设置 › 手机遥控」里，以后可以在那里取消配对。")
                }
                if requested {
                    Section {
                        TextField("6 位配对码", text: $code)
                            .font(.system(.title2, design: .rounded).monospacedDigit())
                            .iOSKeyboard(.numberPad)
                            .iOSOneTimeCode()
                            .focused($codeFocused)
                            .onChange(of: code) { _, new in
                                code = String(new.filter(\.isNumber).prefix(6))
                                if code.count == 6 { Task { await finish() } }
                            }
                    } header: {
                        Text("配对码")
                    } footer: {
                        Text("电脑上弹出了配对码，2 分钟内有效。")
                    }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("配对")
            .iOSInlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else if requested {
                        Button("配对") { Task { await finish() } }.disabled(code.count != 6)
                    } else {
                        Button("请求配对") { Task { await start() } }
                            .disabled(device.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func resolveAddress() async throws -> MacAddress {
        if let address { return address }
        if let a = target.address {
            address = a
            return a
        }
        guard let ep = target.endpoint else { throw APIError.badResponse }
        let a = try await Discovery.resolve(ep)
        address = a
        return a
    }

    private func start() async {
        working = true
        defer { working = false }
        error = nil
        do {
            let addr = try await resolveAddress()
            try await APIClient(address: addr, token: nil).pairStart(device: device.trimmingCharacters(in: .whitespaces))
            requested = true
            code = ""
            codeFocused = true
        } catch {
            self.error = RemoteSession.describe(error)
        }
    }

    private func finish() async {
        guard code.count == 6, !working, let addr = address else { return }
        working = true
        defer { working = false }
        error = nil
        do {
            let r = try await APIClient(address: addr, token: nil).pairFinish(code: code)
            store.add(name: r.name, serviceName: target.serviceName, address: addr, token: r.token)
            dismiss()
        } catch APIError.server(let status, let msg) {
            error = msg
            code = ""
            if status == 410 { requested = false } // 过期或被拒绝：重新请求
        } catch {
            self.error = RemoteSession.describe(error)
        }
    }
}

// MARK: - 只在 iOS 上有的修饰符（方便在 Mac 上用命令行做类型检查）

extension View {
    #if os(iOS)
    func iOSKeyboard(_ type: UIKeyboardType) -> some View { keyboardType(type) }
    func iOSOneTimeCode() -> some View { textContentType(.oneTimeCode) }
    func iOSInlineTitle() -> some View { navigationBarTitleDisplayMode(.inline) }
    /// 搜索框一直显示在标题下面（默认会被滚走）；macOS 上没这个位置
    func searchableAlways(text: Binding<String>, prompt: String) -> some View {
        searchable(text: text, placement: .navigationBarDrawer(displayMode: .always), prompt: prompt)
    }
    #else
    func iOSKeyboard(_ type: KeyboardKind) -> some View { self }
    func iOSOneTimeCode() -> some View { self }
    func iOSInlineTitle() -> some View { self }
    func searchableAlways(text: Binding<String>, prompt: String) -> some View {
        searchable(text: text, prompt: prompt)
    }
    #endif
}

#if !os(iOS)
enum KeyboardKind { case numberPad, numbersAndPunctuation }
#endif
