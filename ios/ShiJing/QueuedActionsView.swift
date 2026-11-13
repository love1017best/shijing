import SwiftUI

/// 「待补操作」：离线时在壁纸上点的整理都记在这里。
/// 单独一页，每条带缩略图预览：点图看大图，「删除原图」逐张（或全部）确认后才会真的删；
/// 「移出」「不再选」连上电脑后自动补上，也可以取消。
struct QueuedActionsView: View {
    let session: RemoteSession
    @State private var confirm: RemoteSession.OfflineAction?
    @State private var confirmAll = false
    @State private var preview: RemoteSession.OfflineAction?

    private var deletes: [RemoteSession.OfflineAction] { session.queuedDeletes }
    private var others: [RemoteSession.OfflineAction] { session.queued.filter { $0.kind != .delete } }
    private var live: Bool { session.connection == .live }
    private var busy: Bool { session.state?.running == true }

    var body: some View {
        List {
            if session.queued.isEmpty {
                ContentUnavailableView("没有待补操作", systemImage: "checkmark.circle",
                                       description: Text("离线时点的「移出」「不再选」「删除原图」会先记在这里，连上电脑后处理。"))
            } else {
                if !deletes.isEmpty {
                    Section {
                        ForEach(deletes) { a in
                            row(a, destructive: true)
                        }
                        if live {
                            Button("全部确认删除（\(deletes.count) 张）", role: .destructive) { confirmAll = true }
                                .disabled(busy)
                        }
                    } header: {
                        Text("待确认删除原图（\(deletes.count)）")
                    } footer: {
                        Text(live
                             ? "不可撤销：会从图库里删掉原文件，也会记进电脑上的删除记录。已经不在这一批壁纸里的会跳过。"
                             : "连上电脑后才能确认删除。缩略图是离线时缓存下来的那一张。")
                    }
                }
                if !others.isEmpty {
                    Section {
                        ForEach(others) { a in
                            row(a, destructive: false)
                        }
                    } header: {
                        Text("连上电脑后自动补上（\(others.count)）")
                    } footer: {
                        Text(live ? "正在陆续补上；补不上的会留在这里。" : "连上电脑后自动补上。")
                    }
                }
                Section {
                    Button("全部取消", role: .destructive) { session.cancelAllQueued() }
                } footer: {
                    Text("取消会把那张放回列表原来的位置。「删除原图」取消后，原图还在图库里。")
                }
            }
        }
        .navigationTitle("待补操作")
        .connectionToolbar(session)
        .confirmationDialog(
            "删除这张原图？",
            isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
            titleVisibility: .visible,
            presenting: confirm
        ) { a in
            Button("删除原图", role: .destructive) { Task { await session.confirmQueuedDelete(a) } }
            Button("取消", role: .cancel) {}
        } message: { a in
            Text("会从图库里删除 \(a.source ?? a.name)，不可撤销，并记进电脑上的删除记录。")
        }
        .confirmationDialog(
            "确认删除 \(deletes.count) 张原图？",
            isPresented: $confirmAll,
            titleVisibility: .visible
        ) {
            Button("全部删除", role: .destructive) { Task { await session.confirmAllQueuedDeletes() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("逐张从图库里删除，不可撤销。已经不在这一批壁纸里的会跳过。")
        }
        .sheet(item: $preview) { a in
            QueuedPreviewSheet(session: session, action: a)
        }
    }

    private func row(_ a: RemoteSession.OfflineAction, destructive: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                preview = a
            } label: {
                thumb(a)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 3) {
                Text(title(a.kind))
                    .font(.subheadline.bold())
                    .foregroundStyle(destructive ? AnyShapeStyle(Color.red) : AnyShapeStyle(.primary))
                Text(a.name).font(.footnote).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                if let src = a.source, !src.isEmpty {
                    Text(src).font(.caption2).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Text(a.at, format: .dateTime.month().day().hour().minute())
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                if destructive {
                    if live {
                        Button("确认删除", role: .destructive) { confirm = a }
                            .buttonStyle(.borderless)
                            .disabled(busy)
                    } else {
                        Text("连上后确认").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                Button("取消") { session.cancelQueued(a) }
                    .buttonStyle(.borderless)
            }
        }
    }

    private func thumb(_ a: RemoteSession.OfflineAction) -> some View {
        WallImage(session: session, wall: a.asWallpaper, kind: .thumb, rev: a.rev)
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: icon(a.kind))
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(3)
                    .background(.black.opacity(0.45), in: Circle())
                    .padding(3)
            }
    }

    private func title(_ kind: RemoteSession.OfflineAction.Kind) -> String {
        switch kind {
        case .remove: "移出"
        case .exclude: "移出并不再选它"
        case .delete: "删除原图（待确认）"
        }
    }

    private func icon(_ kind: RemoteSession.OfflineAction.Kind) -> String {
        switch kind {
        case .remove: "minus.circle.fill"
        case .exclude: "nosign"
        case .delete: "trash.fill"
        }
    }
}

/// 队列里那条对应的壁纸（旧队列没存 wall 时按名字造一个，图片按名字照样能找到）。
extension RemoteSession.OfflineAction {
    var asWallpaper: Wallpaper { wall ?? Wallpaper(name: name, source: source) }
}

/// 点缩略图看大图：先按自己那批找缓存的大图，没有再退到缩略图。
private struct QueuedPreviewSheet: View {
    let session: RemoteSession
    let action: RemoteSession.OfflineAction
    @Environment(\.dismiss) private var dismiss
    @State private var image: PlatformImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image {
                Image(platformImage: image).resizable().scaledToFit()
            } else if failed {
                VStack(spacing: 8) {
                    Image(systemName: "photo.badge.exclamationmark").font(.largeTitle)
                    Text("这张没有缓存的图")
                }
                .foregroundStyle(.white.opacity(0.7))
            } else {
                ProgressView().tint(.white)
            }
            VStack {
                HStack {
                    Text(action.name).font(.subheadline.bold()).foregroundStyle(.white)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.white.opacity(0.8))
                    }
                }
                .padding()
                Spacer()
            }
        }
        .task {
            if let big = await ImageStore.shared.load(session, action.name, .image, rev: action.rev) {
                image = big
            } else if let t = ImageStore.shared.cached(session, action.name, .thumb) {
                image = t
            } else {
                image = await ImageStore.shared.load(session, action.name, .thumb, rev: action.rev)
            }
            failed = image == nil
        }
    }
}
