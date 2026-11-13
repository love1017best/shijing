import SwiftUI

/// 「关于」页：两边各是什么版本、这台手机上的签名什么时候到期。
/// 原来这些混在设置页最下面，用户觉得怪，现在单独一页，入口在概览右上角的 ⓘ。
struct AboutView: View {
    let session: RemoteSession
    @State private var width: CGFloat = 0

    private var macVersion: String {
        guard let v = session.state?.version, !v.isEmpty else { return "还没连上" }
        return "v" + v
    }

    private var mismatch: Bool {
        guard let v = session.state?.version, !v.isEmpty else { return false }
        return v != AppVersion.short
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 6) {
                    Text("拾景").font(.title2.bold())
                    Text("把一片风景拾到屏幕上").font(.footnote).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .listRowBackground(Color.clear)
            }
            Section {
                LabeledContent("电脑上的拾景", value: macVersion)
                LabeledContent(ThisDevice.label, value: AppVersion.text)
            } header: {
                Text("版本")
            } footer: {
                if mismatch {
                    Text("两边版本不一样，有的功能可能用不了，建议都升到最新。")
                }
            }
            if let expiry = SigningExpiry.text {
                Section {
                    LabeledContent("签名", value: expiry)
                } header: {
                    Text("这台 \(ThisDevice.label)")
                } footer: {
                    Text("免费签名只有 7 天，到期后拾景就打不开了。连上电脑重新安装一次就能续上，设置和配对的 Mac 都还在。")
                }
            }
        }
        .contentMargins(.horizontal, max(0, (width - 680) / 2), for: .scrollContent)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .navigationTitle("关于")
        .connectionToolbar(session)
    }
}
