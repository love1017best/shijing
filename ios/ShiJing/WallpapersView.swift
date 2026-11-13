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

/// 对一张壁纸能做的四件事。长按菜单和预览底栏都从这里取：文案、图标、能不能点、点了做什么只写一份。
enum WallActionKind: CaseIterable {
    case save, remove, exclude, delete

    var icon: String {
        switch self {
        case .save: "square.and.arrow.down"
        case .remove: "minus.circle"
        case .exclude: "nosign"
        case .delete: "trash"
        }
    }

    /// 长按菜单里的说法（空间够，写得完整些）
    var menuTitle: String {
        switch self {
        case .save: WallAction.save
        case .remove: WallAction.remove
        case .exclude: WallAction.exclude
        case .delete: WallAction.delete
        }
    }

    /// 预览底栏里的说法（一行放四个按钮，短一点）
    var barTitle: String {
        switch self {
        case .save: WallAction.save
        case .remove: "移出"
        case .exclude: "不再选它"
        case .delete: "删除原图…"
        }
    }

    var hint: String {
        switch self {
        case .save: WallAction.saveHint
        case .remove: WallAction.removeHint
        case .exclude: WallAction.excludeHint
        case .delete: "从图库删除这张原图，不可撤销。"
        }
    }

    var isDestructive: Bool { self == .delete }

    /// 动的是图库里的原图：旧版本换上的没有原图路径，这两种就不显示
    var needsSource: Bool { self == .exclude || self == .delete }

    /// 要连上电脑才能做（下载原文件 / 删原图不排队）
    var needsOnline: Bool { self == .save || self == .delete }
}

extension WallActionKind {
    /// 现在能不能点。换壁纸的过程中不能整理；存原图和删原图离线时做不了。
    @MainActor
    func isEnabled(_ session: RemoteSession) -> Bool {
        if needsOnline, session.offline { return false }
        if self == .save { return session.saving == nil }
        return session.acting == nil && session.state?.running != true
    }

    @MainActor
    func perform(_ session: RemoteSession, _ w: Wallpaper, confirmDelete: Binding<Wallpaper?>) {
        switch self {
        case .save: Task { await session.saveOriginal(w) }
        case .remove: Task { await session.removeWallpaper(w, exclude: false) }
        case .exclude: Task { await session.removeWallpaper(w, exclude: true) }
        case .delete: confirmDelete.wrappedValue = w
        }
    }
}

/// 缩略图网格：概览里放前几行（rows），「全部壁纸」页放全部。点一张进大图预览，长按有三种操作。
struct WallGrid: View {
    let session: RemoteSession
    /// 只显示前几行（概览里用），nil 显示全部
    var rows: Int? = nil
    var minThumb: CGFloat = 104
    /// 点一张时由外面打开预览（概览页这样做，转屏不会丢）；nil 时自己弹
    var onOpen: ((Wallpaper) -> Void)? = nil
    /// 只显示这些（「全部壁纸」页搜索、目录筛选之后）；nil 显示壁纸文件夹里的全部
    var walls: [Wallpaper]? = nil
    /// 选择模式：格子上显示勾选圈，点一下照常交给 onOpen（由外面决定是勾选还是打开）
    var selecting = false
    var selected: Set<String> = []
    /// 长按菜单里的「批量选择」；nil 时不显示这一项
    var onSelect: ((Wallpaper) -> Void)? = nil
    @State private var previewing: Wallpaper?
    @State private var confirmDelete: Wallpaper?
    @State private var width: CGFloat = 0

    private static let gap: CGFloat = 6

    /// 列数按实际宽度算：每张不窄于 minThumb。概览里按整行取图，不会剩半行。
    private var columns: Int { max(2, Int((width + Self.gap) / (minThumb + Self.gap))) }

    private var list: [Wallpaper] { walls ?? session.walls }

    private var shown: ArraySlice<Wallpaper> {
        rows.map { list.prefix($0 * columns) } ?? list[...]
    }

    /// 编号按壁纸文件夹里的完整顺序算（筛选后也要和大图预览顶部的编号对得上）
    private func number(_ w: Wallpaper, _ offset: Int) -> Int {
        if walls == nil { return offset + 1 }
        return session.walls.firstIndex(of: w).map { $0 + 1 } ?? offset + 1
    }

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Self.gap), count: columns), spacing: Self.gap) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, w in
                if selecting {
                    cell(w, i)
                } else {
                    cell(w, i)
                        .contextMenu {
                            WallActionButtons(session: session, wall: w, confirmDelete: $confirmDelete)
                            if let onSelect {
                                Divider()
                                Button("批量选择", systemImage: "checkmark.circle") { onSelect(w) }
                            }
                        } preview: {
                            WallImage(session: session, wall: w, kind: .image, contentMode: .fit)
                                .frame(width: 320, height: 200)
                        }
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .fullScreenCoverCompat(item: $previewing) { w in
            WallPreview(session: session, startName: w.name)
        }
        .deleteOriginalDialog(session: session, wall: $confirmDelete)
    }

    private func cell(_ w: Wallpaper, _ i: Int) -> some View {
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
                        Text("\(number(w, i))")
                            .font(.caption2.monospacedDigit().weight(.medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 3))
                            .padding(3)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if selecting {
                        ZStack {
                            Circle().fill(selected.contains(w.name) ? Color.accentColor : .black.opacity(0.35))
                            if selected.contains(w.name) {
                                Image(systemName: "checkmark").font(.caption2.bold()).foregroundStyle(.white)
                            }
                        }
                        .frame(width: 22, height: 22)
                        .padding(6)
                    }
                }
                .overlay {
                    if selecting, selected.contains(w.name) {
                        RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 2)
                    }
                    if session.acting == w.name {
                        RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.4))
                        ProgressView().tint(.white)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(w.name)
        .accessibilityAddTraits(selecting && selected.contains(w.name) ? .isSelected : [])
    }
}

/// 长按菜单和预览底栏共用的四个操作按钮。
struct WallActionButtons: View {
    let session: RemoteSession
    let wall: Wallpaper
    @Binding var confirmDelete: Wallpaper?

    var body: some View {
        ForEach(WallActionKind.allCases, id: \.self) { kind in
            if !kind.needsSource || wall.hasSource {
                Button(role: kind.isDestructive ? .destructive : nil) {
                    kind.perform(session, wall, confirmDelete: $confirmDelete)
                } label: {
                    Label(kind.menuTitle, systemImage: kind.icon)
                }
                .disabled(!kind.isEnabled(session))
                .accessibilityHint(kind.hint)
                if kind == .save { Divider() }
            }
        }
    }
}

extension View {
    /// 删除原图前的二次确认：写清楚删的是哪个文件、不可撤销。
    func deleteOriginalDialog(session: RemoteSession, wall: Binding<Wallpaper?>) -> some View {
        confirmationDialog(
            "删除图库里的这张原图？",
            isPresented: Binding(get: { wall.wrappedValue != nil }, set: { if !$0 { wall.wrappedValue = nil } }),
            titleVisibility: .visible,
            presenting: wall.wrappedValue
        ) { w in
            Button("删除原图", role: .destructive) {
                Task { _ = await session.deleteOriginal(w) }
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

    @ViewBuilder
    func fullScreenCoverCompat<Content: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
        #if os(iOS)
        fullScreenCover(isPresented: isPresented, content: content)
        #else
        sheet(isPresented: isPresented, content: content)
        #endif
    }
}

/// 「全部壁纸」页：整个壁纸文件夹的网格。可以按文件名搜索、按原图所在目录筛选，
/// 也可以进「选择」模式一次移出 / 不再选几张（不做批量删除原图——不可撤销的操作一张一张来）。
struct AllWallpapersView: View {
    let session: RemoteSession
    @State private var query = ""
    @State private var folder: String?
    @State private var selecting = ProcessInfo.processInfo.arguments.contains("-demoSelect")
    @State private var selected: Set<String> = []
    @State private var previewing: Wallpaper?
    @State private var busy = false

    var body: some View {
        ScrollView {
            if !session.walls.isEmpty {
                HStack {
                    folderMenu
                    Spacer()
                }
                .padding(.horizontal)
            }
            if session.walls.isEmpty {
                ContentUnavailableView("壁纸文件夹是空的", systemImage: "photo.on.rectangle")
                    .padding(.top, 80)
            } else if filtered.isEmpty {
                ContentUnavailableView {
                    Label("没有符合的图片", systemImage: "magnifyingglass")
                } description: {
                    Text(query.isEmpty ? "这个目录里没有图片。" : "没有名字含「\(query)」的图片。")
                } actions: {
                    Button("清除筛选") {
                        query = ""
                        folder = nil
                    }
                }
                .padding(.top, 60)
            } else {
                WallGrid(
                    session: session,
                    minThumb: 120,
                    onOpen: { w in
                        if selecting {
                            toggle(w)
                        } else {
                            previewing = w
                        }
                    },
                    walls: filtered,
                    selecting: selecting,
                    selected: selected,
                    onSelect: { w in
                        selecting = true
                        selected = [w.name]
                    }
                )
                .padding(.horizontal)
            }
        }
        .navigationTitle(title)
        .iOSInlineTitle()
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索文件名")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if selecting {
                    Button("完成") { endSelection() }
                } else {
                    Button("选择", systemImage: "checkmark.circle") { selecting = true }
                        .disabled(session.walls.isEmpty)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if selecting { selectBar }
        }
        .fullScreenCoverCompat(item: $previewing) { w in
            WallPreview(session: session, startName: w.name)
        }
        #if DEBUG
        .onAppear {
            // 截图用：-demoSelect 直接摆出多选的样子
            if selecting, selected.isEmpty { selected = Set(session.walls.prefix(3).map(\.name)) }
        }
        #endif
    }

    private var title: String {
        if selecting { return selected.isEmpty ? "选择几张" : "已选 \(selected.count) 张" }
        if filtered.count != session.walls.count {
            return "全部壁纸（\(filtered.count) / \(session.walls.count)）"
        }
        return "全部壁纸（\(session.walls.count)）"
    }

    /// 原图所在的目录（去掉 /Volumes/xxx 挂载点，最多留两级，不然菜单里放不下）
    private func folderName(of w: Wallpaper) -> String? {
        guard let src = w.source, !src.isEmpty else { return nil }
        var comps = ((src as NSString).deletingLastPathComponent as NSString).pathComponents.filter { $0 != "/" }
        if comps.count >= 2, comps[0] == "Volumes" { comps.removeFirst(2) }
        if comps.count > 2 { comps = Array(comps.suffix(2)) }
        return comps.isEmpty ? "根目录" : comps.joined(separator: "/")
    }

    /// 每个目录有几张（按整个列表算，筛选菜单不跟着搜索词变）
    private var folderCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for w in session.walls {
            guard let f = folderName(of: w) else { continue }
            counts[f, default: 0] += 1
        }
        return counts
    }

    private var filtered: [Wallpaper] {
        var list = session.walls
        if let folder {
            list = list.filter { folderName(of: $0) == folder }
        }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            list = list.filter { $0.name.localizedCaseInsensitiveContains(q) }
        }
        return list
    }

    /// 目录筛选：搜索框下面那颗小胶囊，菜单里按目录挑（菜单里带每个目录的张数）。
    private var folderMenu: some View {
        Menu {
            Picker("目录", selection: $folder) {
                Text("全部目录（\(session.walls.count)）").tag(String?.none)
                ForEach(folderCounts.keys.sorted(), id: \.self) { f in
                    Text("\(f)（\(folderCounts[f] ?? 0)）").tag(String?.some(f))
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: folder == nil ? "folder" : "folder.fill")
                Text(folder ?? "全部目录").lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.thinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(session.walls.isEmpty)
        .accessibilityLabel("按目录筛选")
    }

    private var selectBar: some View {
        HStack(spacing: 10) {
            Button("取消") { endSelection() }
                .buttonStyle(.bordered)
            Spacer(minLength: 8)
            if busy {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else {
                Button {
                    Task { await apply(exclude: false) }
                } label: {
                    Label("移出 \(selected.count)", systemImage: "minus.circle")
                }
                .buttonStyle(.bordered)
                Button {
                    Task { await apply(exclude: true) }
                } label: {
                    Label("不再选 \(selected.count)", systemImage: "nosign")
                }
                .buttonStyle(.bordered)
            }
        }
        .disabled(selected.isEmpty)
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func toggle(_ w: Wallpaper) {
        if selected.contains(w.name) {
            selected.remove(w.name)
        } else {
            selected.insert(w.name)
        }
    }

    private func endSelection() {
        selecting = false
        selected = []
    }

    /// 按整个列表的顺序处理，和电脑上的整理顺序一致
    private func apply(exclude: Bool) async {
        guard !busy else { return }
        let items = session.walls.filter { selected.contains($0.name) }
        guard !items.isEmpty else { endSelection(); return }
        busy = true
        defer { busy = false }
        let done = await session.removeWallpapers(items, exclude: exclude)
        if done == items.count {
            session.showNotice(exclude ? "已移出并不再选 \(done) 张" : "已移出 \(done) 张")
        } else if done > 0 {
            session.showNotice("移出了 \(done) 张，后面的没能做完")
        }
        endSelection()
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

    var body: some View {
        if let name = session.undoName {
            Button {
                Task { _ = await session.undoRemove() }
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
    /// 当前分享出去的那份临时文件：分享面板收起后删掉，不然每分享一张就留一份原图
    @State private var shared: URL?

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
        .disabled(loading || session.offline) // 离线时下载不了原文件
        .accessibilityLabel("分享原图")
        .sheet(item: $file, onDismiss: cleanUp) { f in
            ActivitySheet(items: [f.url]).ignoresSafeArea()
        }
    }

    private func cleanUp() {
        if let u = shared { try? FileManager.default.removeItem(at: u) }
        shared = nil
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let url = try await session.client().downloadOriginal(wall.name)
            shared = url
            file = SharedFile(url: url)
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
