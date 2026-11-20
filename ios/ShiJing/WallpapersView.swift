import SwiftUI

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
                                        .id(w.id)
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
    }

    private var rowCount: Int {
        max(1, (shown.count + columns - 1) / columns)
    }

    /// 一个格子（带长按菜单、选择模式的处理）。
    /// 删除确认挂在格子上而不是整张网格上：iPad、Duo 这种 regular 宽度上确认框是 popover，
    /// 挂在网格上会飘到网格正中，和长按的那个格子差很远。每格都挂一份，只有被点的那格生效。
    @ViewBuilder
    private func tile(_ w: Wallpaper, number: Int) -> some View {
        Group {
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
        .deleteOriginalDialog(session: session, wall: Binding(
            get: { confirmDelete?.id == w.id ? confirmDelete : nil },
            set: { if $0 == nil { confirmDelete = nil } }))
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
        let counts = folderCounts
        let folders = counts.keys.sorted()
        return Menu {
            Picker("目录", selection: $folder) {
                Text("全部目录（\(session.walls.count)）").tag(String?.none)
                ForEach(folders, id: \.self) { f in
                    Text("\(f)（\(counts[f] ?? 0)）").tag(String?.some(f))
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
