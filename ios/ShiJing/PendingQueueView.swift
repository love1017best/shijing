import SwiftUI

/// 电脑上排队的待删除原图列表：图库（NAS）未连接时删的原图会排在这里，
/// 图库重新连接后电脑会自动校验并删除。这里可以查看明细，逐条或全部取消。
struct PendingQueueView: View {
    let session: RemoteSession
    @State private var confirmAll = false
    @State private var canceling: Set<String> = []

    private var items: [PendingItem] { session.state?.pendingItems ?? [] }

    var body: some View {
        List {
            if session.offline && !items.isEmpty {
                Section {
                    NoticeRow(icon: "wifi.slash", title: "离线时只能查看",
                              detail: "连接电脑后才能取消排队的删除。这些记录来自上次同步的状态。")
                }
            }
            if items.isEmpty {
                ContentUnavailableView("没有待删除的原图", systemImage: "checkmark.circle",
                                       description: Text("图库未连接时点击「删除原图」的图片会先排在这里，图库连接后电脑会自动删除。"))
            } else {
                Section {
                    ForEach(items) { it in
                        row(it)
                            .swipeActions {
                                Button("取消") { Task { await cancel(it) } }
                                    .tint(.accentColor)
                                    .disabled(session.offline || canceling.contains(it.path))
                            }
                    }
                } header: {
                    Text("共 \(items.count) 张")
                } footer: {
                    Text(session.offline
                         ? "连接电脑后可以逐条或全部取消。"
                         : "图库连接后电脑会自动校验并删除这些原图；排队期间被修改过的文件不会删除。取消后原图保留，壁纸文件夹中的那一份已经移出。")
                }
                if items.count > 1 {
                    Section {
                        Button("全部取消（\(items.count) 张）", role: .destructive) {
                            confirmAll = true
                        }
                        .disabled(session.offline || !canceling.isEmpty)
                    }
                }
            }
        }
        .navigationTitle("待删除原图")
        .navigationBarTitleDisplayMode(.inline)
        .connectionToolbar(session)
        .confirmationDialog("取消全部 \(items.count) 项排队删除？", isPresented: $confirmAll, titleVisibility: .visible) {
            Button("全部取消", role: .destructive) {
                Task { await session.cancelAllPending() }
            }
            Button("返回", role: .cancel) {}
        } message: {
            Text("取消后这些原图都会保留在图库里，不再等待删除。")
        }
    }

    private func row(_ it: PendingItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "clock")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(it.wall ?? it.name)
                    .font(.subheadline)
                    .lineLimit(1).truncationMode(.middle)
                Text(it.display)
                    .font(.footnote).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Text(it.date, format: .dateTime.month().day().hour().minute())
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            if canceling.contains(it.path) {
                ProgressView()
            } else {
                Button("取消") { Task { await cancel(it) } }
                    .buttonStyle(.borderless)
                    .disabled(session.offline)
            }
        }
    }

    private func cancel(_ item: PendingItem) async {
        canceling.insert(item.path)
        defer { canceling.remove(item.path) }
        await session.cancelPending(item)
    }
}
