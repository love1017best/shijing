import SwiftUI

// 三种操作的说法和桌面端 preview.go 的 act* 一致：「移出」只删壁纸文件夹里那份，「删除原图」才动图库。
enum WallAction {
    static let remove = "移出壁纸文件夹"
    static let exclude = "移出并不再选它"
    static let delete = "删除图库里的原图…"
    static let save = "存到相册"
    static let saveHint = "从电脑下载原文件（不是预览图），原样存进相册。"
    static let removeHint = "只删壁纸文件夹里的这一份，图库里的原图不动。"
    static let excludeHint = "还会让以后的采样跳过这张原图（可以在电脑上的「图库」页恢复）。"
}

/// 缩略图网格：概览里放前几行（rows），「全部壁纸」页放全部。点一张进大图预览，长按有三种操作。
struct WallGrid: View {
    let session: RemoteSession
    /// 只显示前几行（概览里用），nil 显示全部
    var rows: Int? = nil
    var minThumb: CGFloat = 104
    /// 点一张时由外面打开预览（概览页这样做，转屏不会丢）；nil 时自己弹
    var onOpen: ((Wallpaper) -> Void)? = nil
    @State private var previewing: Wallpaper?
    @State private var confirmDelete: Wallpaper?
    @State private var width: CGFloat = 0

    private static let gap: CGFloat = 6

    /// 列数按实际宽度算：每张不窄于 minThumb。概览里按整行取图，不会剩半行。
    private var columns: Int { max(2, Int((width + Self.gap) / (minThumb + Self.gap))) }

    private var shown: ArraySlice<Wallpaper> {
        rows.map { session.walls.prefix($0 * columns) } ?? session.walls[...]
    }

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Self.gap), count: columns), spacing: Self.gap) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, w in
                Button {
                    if let onOpen { onOpen(w) } else { previewing = w }
                } label: {
                    WallImage(session: session, wall: w)
                        .aspectRatio(16 / 10, contentMode: .fill)
                        .frame(minWidth: 0, maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(alignment: .bottomTrailing) {
                            // 「全部壁纸」页标上编号，和大图预览顶部的编号一致，方便对照着找
                            if rows == nil {
                                Text("\(i + 1)")
                                    .font(.caption2.monospacedDigit().weight(.medium))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 4).padding(.vertical, 1)
                                    .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 3))
                                    .padding(3)
                            }
                        }
                        .overlay {
                            if session.acting == w.name {
                                RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.4))
                                ProgressView().tint(.white)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(w.name)
                .contextMenu {
                    WallActionButtons(session: session, wall: w, confirmDelete: $confirmDelete)
                } preview: {
                    WallImage(session: session, wall: w, kind: .image, contentMode: .fit)
                        .frame(width: 320, height: 200)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .fullScreenCoverCompat(item: $previewing) { w in
            WallPreview(session: session, startName: w.name)
        }
        .deleteOriginalDialog(session: session, wall: $confirmDelete)
    }
}

/// 长按菜单和预览底栏共用的三个操作按钮。
struct WallActionButtons: View {
    let session: RemoteSession
    let wall: Wallpaper
    @Binding var confirmDelete: Wallpaper?

    var body: some View {
        let busy = session.acting != nil || session.state?.running == true
        Button(WallAction.save, systemImage: "square.and.arrow.down") {
            Task { await session.saveOriginal(wall) }
        }
        .disabled(session.saving != nil)
        Divider()
        Button(WallAction.remove, systemImage: "minus.circle") {
            Task { await session.removeWallpaper(wall, exclude: false) }
        }
        .disabled(busy)
        if wall.hasSource {
            Button(WallAction.exclude, systemImage: "nosign") {
                Task { await session.removeWallpaper(wall, exclude: true) }
            }
            .disabled(busy)
            Button(WallAction.delete, systemImage: "trash", role: .destructive) {
                confirmDelete = wall
            }
            .disabled(busy)
        }
    }
}

extension View {
    /// 删除原图前的二次确认：写清楚删的是哪个文件、不可撤销。
    func deleteOriginalDialog(session: RemoteSession, wall: Binding<Wallpaper?>, onDeleted: (() -> Void)? = nil) -> some View {
        confirmationDialog(
            "删除图库里的这张原图？",
            isPresented: Binding(get: { wall.wrappedValue != nil }, set: { if !$0 { wall.wrappedValue = nil } }),
            titleVisibility: .visible,
            presenting: wall.wrappedValue
        ) { w in
            Button("删除原图", role: .destructive) {
                Task {
                    if await session.deleteOriginal(w) { onDeleted?() }
                }
            }
            Button("取消", role: .cancel) {}
        } message: { w in
            Text("会从图库里删除 \(w.source ?? w.name)，并移出壁纸文件夹。删除不可撤销，会记进电脑上的删除记录。")
        }
    }

    /// iOS 用全屏弹层，Mac 上做类型检查时退回普通弹层。
    @ViewBuilder
    func fullScreenCoverCompat<Item: Identifiable, Content: View>(item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        #if os(iOS)
        fullScreenCover(item: item, content: content)
        #else
        sheet(item: item, content: content)
        #endif
    }
}

/// 「全部壁纸」页：整个壁纸文件夹的网格。
struct AllWallpapersView: View {
    let session: RemoteSession

    var body: some View {
        ScrollView {
            if session.walls.isEmpty {
                ContentUnavailableView("壁纸文件夹是空的", systemImage: "photo.on.rectangle")
                    .padding(.top, 80)
            } else {
                WallGrid(session: session, minThumb: 120)
                    .padding(.horizontal)
                Text("长按一张可以移出或删除原图。").font(.footnote).foregroundStyle(.secondary).padding()
            }
        }
        .navigationTitle("全部壁纸（\(session.walls.count)）")
        .iOSInlineTitle()
    }
}

extension View {
    @ViewBuilder
    func statusBarHiddenCompat(_ hidden: Bool) -> some View {
        #if os(iOS)
        statusBarHidden(hidden)
        #else
        self
        #endif
    }
}

/// 「撤销移出」：放回最近一次移出的那张（和电脑上 ⌘Z 是同一个撤销栈）。
struct UndoRemoveButton: View {
    let session: RemoteSession
    var onUndone: ((String) -> Void)? = nil

    var body: some View {
        if let name = session.state?.undoName {
            Button {
                Task {
                    if let n = await session.undoRemove() { onUndone?(n) }
                }
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("撤销移出")
                        Text(name).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                } icon: {
                    if session.acting == name { ProgressView() } else { Image(systemName: "arrow.uturn.backward") }
                }
            }
            .disabled(session.acting != nil || session.state?.running == true)
        }
    }
}

/// 分享 / 存原图：先从电脑下载原文件（不是 2048 宽的预览图），下完弹系统分享面板（里面有「存储图像」）。
struct ShareOriginalButton: View {
    let session: RemoteSession
    let wall: Wallpaper
    @State private var loading = false
    @State private var file: SharedFile?

    var body: some View {
        Button {
            Task { await load() }
        } label: {
            ZStack {
                Image(systemName: "square.and.arrow.up").opacity(loading ? 0 : 1)
                if loading { ProgressView() }
            }
            .font(.body.weight(.semibold)).frame(width: 36, height: 36)
        }
        .disabled(loading)
        .accessibilityLabel("分享原图")
        .sheet(item: $file) { f in
            ActivitySheet(items: [f.url]).ignoresSafeArea()
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            file = SharedFile(url: try await session.client().downloadOriginal(wall.name))
        } catch {
            session.actionError = RemoteSession.describe(error)
        }
    }
}

struct SharedFile: Identifiable {
    let url: URL
    var id: URL { url }
}

#if os(iOS)
struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
#else
struct ActivitySheet: View {
    let items: [Any]
    var body: some View { Text("只在 iOS 上可用") }
}
#endif

/// 「已存到相册」这类一闪而过的提示。
struct NoticeBubble: View {
    let text: String?

    var body: some View {
        Group {
            if let text {
                Label(text, systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: text)
        .allowsHitTesting(false)
    }
}
