import SwiftUI
#if os(iOS)
import UIKit
#endif

// 三种操作的说法和桌面端 preview.go 的 act* 一致：「移出」只删壁纸文件夹里那份，「删除原图」才动图库。
enum WallAction {
    static let remove = "移出壁纸文件夹"
    static let exclude = "移出并不再选它"
    static let delete = "删除图库里的原图…"
    static let save = "存到相册"
    static let saveHint = "存的是图库里的原图，不是手机上的预览图。离线时用手机上存过的那份。"
    static let removeHint = "只删壁纸文件夹里的这一份，图库里的原图不动。"
    static let excludeHint = "以后采样不会再选这张原图，可以在电脑上的「图库」页恢复。"
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
        case .delete: "从图库删除这张原图，不可撤销。连不上电脑时先记下来，连上后再确认一次才会删。"
        }
    }

    var isDestructive: Bool { self == .delete }

    /// 动的是图库里的原图：旧版本换上的没有原图路径，这两种就不显示
    var needsSource: Bool { self == .exclude || self == .delete }
}

extension WallActionKind {
    /// 现在能不能点。换壁纸的过程中不能整理；存原图离线时只有手机上存过那张的原图才能点。
    /// 删除原图离线时也能点：只登记「想删」，连上电脑后还要再确认一次才真的删。
    @MainActor
    func isEnabled(_ session: RemoteSession, _ w: Wallpaper) -> Bool {
        if self == .save {
            if session.saving != nil { return false }
            return !session.offline || ImageStore.cachedOriginal(name: w.name) != nil
        }
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

    /// 编号按壁纸文件夹里的完整顺序算（筛选后也要和大图预览顶部的编号对得上）。
    /// 一次排好查表的字典，别在每个格子里去 `firstIndex` 从头找。
    private var numbering: [String: Int]? {
        guard walls != nil else { return nil }
        var m = [String: Int](minimumCapacity: session.walls.count)
        for (i, w) in session.walls.enumerated() { m[w.id] = i + 1 }
        return m
    }

    var body: some View {
        let order = numbering
        Group {
            if rows != nil {
                // 概览只显示前几行：用固定的 VStack 排，不进 LazyVGrid。
                // LazyVGrid 放在 List 行里时，滚进来的格子会按上一轮布局的高度画，个别图缩成一小块、
                // 浮在网格外面（Duo 外屏概览踩过，v0.3.168）。这里行数本来就不多，用不着懒加载。
                VStack(spacing: Self.gap) {
                    ForEach(0..<rowCount, id: \.self) { r in
                        HStack(spacing: Self.gap) {
                            ForEach(0..<columns, id: \.self) { c in
                                let i = r * columns + c
                                if i < shown.count {
                                    let w = shown[shown.startIndex + i]
                                    tile(w, number: order?[w.id] ?? i + 1)
                                } else {
                                    Color.clear // 最后一行的空位，撑住列宽
                                }
                            }
                        }
                    }
                }
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Self.gap), count: columns), spacing: Self.gap) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { i, w in
                        tile(w, number: order?[w.id] ?? i + 1)
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

    private var rowCount: Int {
        max(1, (shown.count + columns - 1) / columns)
    }

    /// 一个格子（带长按菜单、选择模式的处理）。
    @ViewBuilder
    private func tile(_ w: Wallpaper, number: Int) -> some View {
        if selecting {
            cell(w, number: number)
        } else {
            cell(w, number: number)
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

    private func cell(_ w: Wallpaper, number: Int) -> some View {
        Button {
            if let onOpen { onOpen(w) } else { previewing = w }
        } label: {
            // 格子尺寸只由 16:10 这个比例定，图片放在 overlay 里填满、超出裁掉。
            // 以前把 aspectRatio(.fill) 直接挂在 WallImage 上，格子高矮跟着图片自身比例和
            // 加载状态走：加载完的图和占位块不一样高，同一行里有的格子矮一截、有的图浮在网格外面
            // （Duo 外屏概览上踩过）。
            Color.clear
                .aspectRatio(16 / 10, contentMode: .fit)
                .overlay { WallImage(session: session, wall: w) }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .bottomTrailing) {
                    // 「全部壁纸」页标上编号，和大图预览顶部的编号一致，方便对照着找
                    if rows == nil {
                        Text("\(number)")
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
                .disabled(!kind.isEnabled(session, wall))
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
            if session.offline {
                Text("会从图库里删除 \(w.source ?? w.name)，并移出壁纸文件夹。删除不可撤销。现在连不上电脑，会先记下来，连上后在「设置 › 待补操作」里再确认一次才会删除。")
            } else {
                Text("会从图库里删除 \(w.source ?? w.name)，并移出壁纸文件夹。删除不可撤销，会记进电脑上的删除记录。")
            }
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
        // 过滤只在每次渲染时算一遍（原来 body 和 title 各算一次）
        let list = filtered
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
            } else if list.isEmpty {
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
                    walls: list,
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
        .navigationTitle(title(count: list.count))
        .iOSInlineTitle()
        .searchableAlways(text: $query, prompt: "搜索文件名")
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

    private func title(count: Int) -> String {
        if selecting { return selected.isEmpty ? "选择几张" : "已选 \(selected.count) 张" }
        if count != session.walls.count {
            return "全部壁纸（\(count) / \(session.walls.count)）"
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
                // 目录名长的时候，Menu 的标签第一帧会按旧宽度量、先被截掉一截，
                // 下一帧才撑开：让它永远取文字本身的宽度，别被压
                Text(folder ?? "全部目录").lineLimit(1).fixedSize(horizontal: true, vertical: false)
                Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .glassBackground(in: Capsule())
            .transaction { $0.animation = nil } // 换目录时别做宽度动画
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
        .glassBackground(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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

/// 分享 / 存原图：先从电脑下载原文件（不是 2732 宽的预览图），下完弹系统分享面板（里面有「存储图像」）。
/// 离线时用手机上存过的那份原图（设置 › 离线 › 保存原图）。
struct ShareOriginalButton: View {
    let session: RemoteSession
    let wall: Wallpaper
    /// 预览底部那排悬浮按钮里用（一块圆形的液态玻璃），菜单里用默认的系统按钮
    var glass = false
    /// 预览底部那排的直径（窄屏上要和关闭按钮一起收窄）
    var size: CGFloat = 44
    @State private var loading = false

    /// 手机上存过这张的原图（离线时唯一能用的那份）
    private var cached: URL? {
        ImageStore.cachedOriginal(name: wall.name)
    }

    var body: some View {
        Group {
            if glass {
                button.buttonStyle(.plain)
            } else {
                button.buttonStyle(.bordered).buttonBorderShape(.circle)
            }
        }
        .disabled(loading || (session.offline && cached == nil)) // 离线、手机上又没存过：下载不了
        .accessibilityLabel("分享原图")
    }

    private var button: some View {
        Button {
            Task { await load() }
        } label: {
            ZStack {
                Image(systemName: "square.and.arrow.up").opacity(loading ? 0 : 1)
                if loading { ProgressView() }
            }
            .font(.system(size: 20, weight: .semibold))
            .frame(width: glass ? size : 36, height: glass ? size : 36)
            .modifier(ShareGlass(glass: glass))
        }
    }

    @MainActor
    private func load() async {
        loading = true
        defer { loading = false }
        do {
            if let cached, session.offline {
                present(cached, deleteAfter: false) // 手机上缓存的那份不能删
            } else {
                let url = try await session.client().downloadOriginal(wall.name)
                present(url, deleteAfter: true)
            }
        } catch {
            session.actionError = RemoteSession.describe(error)
        }
    }

    @MainActor
    private func present(_ url: URL, deleteAfter: Bool) {
        SharePresenter.present([url]) {
            if deleteAfter { try? FileManager.default.removeItem(at: url) }
        }
    }
}

/// 直接在最上层视图上弹出系统分享面板。用 SwiftUI 的 .sheet 包一层的话，面板得等 sheet 自己推上来才出现、
/// 收起时又跟着 sheet 一起走，两段动画叠着看很生涩。
@MainActor
enum SharePresenter {
    static func present(_ items: [Any], onFinish: (() -> Void)? = nil) {
        #if os(iOS)
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              let top = topmost(scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
                                ?? scene.windows.first?.rootViewController) else { return }
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        vc.completionWithItemsHandler = { _, _, _, _ in
            DispatchQueue.main.async { onFinish?() }
        }
        if let pop = vc.popoverPresentationController {
            // iPad 上分享面板是个 popover，得给个锚点；预览是全屏的，指屏幕中间
            pop.sourceView = top.view
            pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        top.present(vc, animated: true)
        #else
        _ = items
        onFinish?()
        #endif
    }

    #if os(iOS)
    /// 最上层那个视图控制器（预览、弹层可能已经叠了好几层）
    private static func topmost(_ vc: UIViewController?) -> UIViewController? {
        var top = vc
        while let p = top?.presentedViewController { top = p }
        return top
    }
    #endif
}

/// 预览底部的分享按钮：外面套一块圆形的液态玻璃
private struct ShareGlass: ViewModifier {
    let glass: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if glass {
            content.glassBackground(in: Circle(), interactive: true).contentShape(Circle())
        } else {
            content
        }
    }
}

/// 「已存到相册」这类一闪而过的提示。
struct NoticeBubble: View {
    let text: String?

    var body: some View {
        Group {
            if let text {
                Label(text, systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .glassBackground(in: Capsule())
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: text)
        .allowsHitTesting(false)
    }
}
