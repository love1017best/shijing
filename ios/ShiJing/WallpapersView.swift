import SwiftUI

// 三种操作的说法和桌面端 preview.go 的 act* 一致：「移出」只删壁纸文件夹里那份，「删除原图」才动图库。
enum WallAction {
    static let remove = "移出壁纸文件夹"
    static let exclude = "移出并不再选它"
    static let delete = "删除图库里的原图…"
    static let removeHint = "只删壁纸文件夹里的这一份，图库里的原图不动。"
    static let excludeHint = "还会让以后的采样跳过这张原图（可以在电脑上的「图库」页恢复）。"
}

/// 缩略图网格：概览里放前几行（rows），「全部壁纸」页放全部。点一张进大图预览，长按有三种操作。
struct WallGrid: View {
    let session: RemoteSession
    /// 只显示前几行（概览里用），nil 显示全部
    var rows: Int? = nil
    var minThumb: CGFloat = 104
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
            ForEach(shown) { w in
                Button {
                    previewing = w
                } label: {
                    WallImage(session: session, wall: w)
                        .aspectRatio(16 / 10, contentMode: .fill)
                        .frame(minWidth: 0, maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
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
        #if DEBUG
        .onAppear {
            // 演示模式截图用：启动参数带 -demoPreview 时直接打开第 3 张的大图预览
            if rows != nil, ProcessInfo.processInfo.arguments.contains("-demoPreview"), session.walls.count > 2 {
                previewing = session.walls[2]
            }
        }
        #endif
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

/// 大图预览：左右滑翻看壁纸文件夹里的全部图片，底栏三种操作。操作完停在原位置，看到的就是下一张。
struct WallPreview: View {
    let session: RemoteSession
    @State private var current: String
    @State private var confirmDelete: Wallpaper?
    @State private var chrome = true
    @Environment(\.dismiss) private var dismiss

    init(session: RemoteSession, startName: String) {
        self.session = session
        _current = State(initialValue: startName)
    }

    private var index: Int? { session.walls.firstIndex { $0.name == current } }
    private var wall: Wallpaper? { index.map { session.walls[$0] } }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $current) {
                ForEach(session.walls) { w in
                    WallImage(session: session, wall: w, kind: .image, contentMode: .fit)
                        .tag(w.name)
                        .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { chrome.toggle() } }
                }
            }
            #if os(iOS)
            .tabViewStyle(.page(indexDisplayMode: .never))
            #endif
            .ignoresSafeArea()

            if chrome {
                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    if let wall { bottomBar(wall) }
                }
                .transition(.opacity)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHiddenCompat(!chrome)
        .deleteOriginalDialog(session: session, wall: $confirmDelete)
        .onChange(of: session.walls) { old, new in
            // 当前这张被移出了：停在原来的位置（就是下一张），删光了就关掉
            guard !new.contains(where: { $0.name == current }) else { return }
            if new.isEmpty {
                dismiss()
                return
            }
            let oldIdx = old.firstIndex { $0.name == current } ?? 0
            current = new[min(oldIdx, new.count - 1)].name
        }
        .sensoryFeedback(.success, trigger: session.walls.count) { old, new in new < old }
    }

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark").font(.body.weight(.semibold)).frame(width: 36, height: 36)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .accessibilityLabel("关闭")
            Spacer()
            if let index {
                Text("\(index + 1) / \(session.walls.count)")
                    .font(.subheadline.monospacedDigit())
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private func bottomBar(_ w: Wallpaper) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(w.name).font(.subheadline.bold()).lineLimit(1).truncationMode(.middle)
                Text(w.hasSource ? "原图：\(w.source ?? "")" : "原图：没有记录（之前的版本换上的），只能移出")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
            }
            if session.state?.running == true {
                Label("正在换壁纸，等换完再整理", systemImage: "hourglass").font(.footnote).foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { actionButtons(w) }
                VStack(alignment: .leading, spacing: 8) { actionButtons(w) }
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .disabled(session.acting != nil || session.state?.running == true)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private func actionButtons(_ w: Wallpaper) -> some View {
        Button {
            Task { await session.removeWallpaper(w, exclude: false) }
        } label: {
            Label("移出", systemImage: "minus.circle").fixedSize()
        }
        .accessibilityHint(WallAction.removeHint)
        if w.hasSource {
            Button {
                Task { await session.removeWallpaper(w, exclude: true) }
            } label: {
                Label("不再选它", systemImage: "nosign").fixedSize()
            }
            .accessibilityHint(WallAction.excludeHint)
            Button(role: .destructive) {
                confirmDelete = w
            } label: {
                Label("删除原图…", systemImage: "trash").fixedSize()
            }
        }
        if session.acting == w.name {
            ProgressView()
        }
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
