import SwiftUI

/// 多套配置方案（场景预设）的共享列表分组：在概览页与「设置 › 电脑上的拾景」复用。
/// 点方案名称切换方案；点右侧「换一批」一键切换并触发换一批（若目标方案会删除原图则先二次确认）。
struct ProfilesSection: View {
    let session: RemoteSession
    let state: RemoteState
    /// 在设置页里带问号说明头，在概览页里用简洁标题。
    var showHelpHeader = false

    @State private var confirmRunProfile: ConfigProfile?

    private var profiles: [ConfigProfile] { state.profiles ?? [] }
    private var disabled: Bool { state.running || session.offline || session.busy || session.savingSettings }

    var body: some View {
        if !profiles.isEmpty {
            Section {
                ForEach(profiles) { p in
                    row(p)
                }
            } header: {
                if showHelpHeader {
                    HelpHeader("配置方案", "在电脑端保存的不同场景方案（图库组合、张数和分辨率）。点方案名称只切换设置，点右侧按钮直接切换并换一批。")
                } else {
                    Text("配置方案")
                }
            } footer: {
                if let active = state.activeProfile, !active.isEmpty, state.activeProfileModified == true {
                    Text("当前设置相对方案「\(active)」有改动；点击该方案可恢复原设置，或在电脑端设置页更新。")
                }
            }
            .confirmationDialog(
                "切换并换一批会删除不合格原图",
                isPresented: Binding(get: { confirmRunProfile != nil }, set: { if !$0 { confirmRunProfile = nil } }),
                titleVisibility: .visible,
                presenting: confirmRunProfile
            ) { p in
                Button("只模拟筛选并换一批") {
                    Task { await session.switchProfile(p, run: true, deleteOriginals: false) }
                }
                Button("删除不合格原图并换一批", role: .destructive) {
                    Task { await session.switchProfile(p, run: true, deleteOriginals: true) }
                }
                Button("取消", role: .cancel) {}
            } message: { p in
                Text("方案「\(p.name)」开启了删除不合格原图（低于 \(p.minWidth)×\(p.minHeight) 或非横屏），删除不可撤销。")
            }
        }
    }

    private func row(_ p: ConfigProfile) -> some View {
        let active = state.activeProfile == p.name
        let modified = active && state.activeProfileModified == true
        return HStack(spacing: 12) {
            Button {
                Task { await session.switchProfile(p, run: false) }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: active ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(active ? Color.accentColor : Color.secondary.opacity(0.4))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(p.name)
                                .font(.subheadline.weight(active ? .semibold : .regular))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            if modified {
                                Text("已修改")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.orange)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(.orange.opacity(0.14), in: Capsule())
                            }
                        }
                        Text(p.summary(presets: state.settings?.minPresets))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(disabled || (active && !modified))

            Button {
                if p.willDelete {
                    confirmRunProfile = p
                } else {
                    Task { await session.switchProfile(p, run: true, deleteOriginals: false) }
                }
            } label: {
                Label("换一批", systemImage: "shuffle")
                    .font(.caption.weight(.medium))
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize(horizontal: true, vertical: false)
            .disabled(disabled)
            .accessibilityLabel("切换到「\(p.name)」并换一批")
        }
    }
}
