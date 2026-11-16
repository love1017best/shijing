import SwiftUI

extension View {
    /// 连接的异常状态（正在连接 / 重连中 / 配对失效）才在右上角显示徽标；正常连接时不占位置。
    func connectionToolbar(_ session: RemoteSession) -> some View {
        toolbar {
            if session.offline {
                ToolbarItem(placement: .primaryAction) { ConnectionBadge(connection: session.connection) }
            }
        }
    }
}

/// 「图标 + 粗标题 + 灰色说明」的提醒行：概览的离线 / 排队 / 待确认 / 签名到期，
/// 设置页的「仅可查看」、图库目录页的「上次同步」都用它，间距和字号只写一份。
struct NoticeRow: View {
    let icon: String
    let title: String
    /// 说明分开传，别拼成一整段：离线提示卡要保持三行（v0.3.172）
    var details: [String]
    var color: Color = .orange

    init(icon: String, title: String, detail: String, color: Color = .orange) {
        self.icon = icon
        self.title = title
        details = [detail]
        self.color = color
    }

    init(icon: String, title: String, details: [String], color: Color = .orange) {
        self.icon = icon
        self.title = title
        self.details = details
        self.color = color
    }

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.bold())
                ForEach(details.indices, id: \.self) { i in
                    Text(details[i]).font(.footnote).foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: icon).foregroundStyle(color)
        }
    }
}

/// 还没拿到状态时整页显示的占位：配对失效、连不上（带重试）、正在连接。
/// 概览和设置 / 记录页共用，文案改一处就够。
struct ConnectionFallback: View {
    let session: RemoteSession
    /// 配对失效时「移除这台 Mac」按钮做什么；不传就不显示这个按钮
    var onRemoveMac: (() -> Void)?

    var body: some View {
        switch session.connection {
        case .unpaired(let msg):
            ContentUnavailableView {
                Label("配对已失效", systemImage: "lock.slash")
            } description: {
                Text(msg + "\n移除后重新配对。")
            } actions: {
                if let onRemoveMac {
                    Button("移除这台 Mac", role: .destructive, action: onRemoveMac)
                        .buttonStyle(.borderedProminent)
                }
            }
        case .offline(let msg):
            ContentUnavailableView {
                Label("无法连接 \(session.mac.name)", systemImage: "wifi.exclamationmark")
            } description: {
                Text(msg)
            } actions: {
                Button("重试") { session.start() }.buttonStyle(.bordered)
            }
        case .connecting, .live:
            // .live 但还没收到第一份状态：照样是「正在连接」
            ProgressView("正在连接 \(session.mac.name)…")
        }
    }
}
