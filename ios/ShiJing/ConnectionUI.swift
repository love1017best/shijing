import SwiftUI

extension View {
    /// 连接的异常状态（正在连接 / 重连中 / 配对失效）才在右上角显示徽标；正常连接时不占位置。
    func connectionToolbar(_ session: RemoteSession) -> some View {
        toolbar {
            if session.connection != .live {
                ToolbarItem(placement: .primaryAction) { ConnectionBadge(connection: session.connection) }
            }
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
                Label("连不上 \(session.mac.name)", systemImage: "wifi.exclamationmark")
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
