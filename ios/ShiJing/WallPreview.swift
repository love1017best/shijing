import SwiftUI

/// 大图预览：左右滑翻看壁纸文件夹里的全部图片（首尾相接，和桌面一样），双指缩放，
/// 底部缩略图条可以拖着快速找图，点顶部编号可以输入编号跳转。
/// 上下滑分两级（用户要求）：上滑一次拉出操作列表（顶栏和缩略图条都在），再上滑进入全屏（全部藏起来只剩图）；
/// 全屏下滑回到常态（顶栏和缩略图条回来），列表开着时下滑也是回到常态，常态下滑（图跟着手指）才关闭预览。
/// 缩略图条不会在收列表的时候莫名其妙消失。操作完停在原位置，看到的就是下一张。
///
/// 翻页是自己写的（只摆上一张、当前、下一张三页，跟着手指移动），不用 TabView(.page) / 分页 ScrollView：
/// 首尾循环、缩放后单指平移、往下拖关闭都要和翻页抢同一个拖动手势，放在一起判断方向最省事。
/// TabView 还会按扣掉安全区的宽度分页，iPhone Duo 内屏横放时侧边有传感器区，每页比屏幕窄（踩过）。
struct WallPreview: View {
    let session: RemoteSession
    @State private var current: String
    @State private var confirmDelete: Wallpaper?
    @State private var chrome = true
    /// 底部的操作列表（文件名、原图路径、存到相册 / 移出 / 不再选 / 删除）：上滑拉出，下滑收起
    @State private var panel = false

    // 拖动：一次拖动开头判断方向，之后不变
    /// levels：上下滑在三级之间移动——常态（顶栏 + 缩略图条）⇄ 操作列表 ⇄ 全屏，一次滑动走一级
    private enum Axis { case page, dismiss, levels, pan, ignore }
    @State private var axis: Axis?
    @State private var dragX: CGFloat = 0
    @State private var dragY: CGFloat = 0

    // 缩放：scale/offset 是当前显示的，base* 是上次手势结束时的
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero
    @State private var pinching = false
    /// 缩放后单指平移的起点（拖动中途从双指变单指时重新取）
    @State private var panStart: CGSize?
    /// 双击切换过「铺满 / 完整显示」（只对当前这张，翻页后恢复默认）
    @State private var flipped = false

    @State private var screenMidX: CGFloat?
    /// 顶栏下沿、底栏上沿（全局坐标）：竖屏完整显示时图片放在两者之间，不被底栏挡住
    @State private var topBarBottom: CGFloat = 0
    /// 顶部安全区：横屏时状态栏不占地方（几乎是 0），顶栏按钮要自己离上边缘远一点
    @State private var topSafe: CGFloat = 0
    @State private var bottomBarTop: CGFloat?
    @State private var jumping = false
    @State private var jumpText = ""
    @Environment(\.dismiss) private var dismiss

    private static let pageGap: CGFloat = 16
    private static let dismissDistance: CGFloat = 120
    /// 翻页至少要拖的距离上限（见 finishPage）
    private static let pageDistance: CGFloat = 80
    private static let maxScale: CGFloat = 5
    /// 上滑拉出 / 下滑收起操作列表要拖的距离
    private static let panelDistance: CGFloat = 40
    /// 操作列表开着还是收着：关预览时记住，下次打开还是上次的样子（用户要求，别每次都要再上滑一次）
    private static let panelOpenKey = "previewPanelOpen"

    init(session: RemoteSession, startName: String) {
        self.session = session
        _current = State(initialValue: startName)
        let remembered = UserDefaults.standard.bool(forKey: Self.panelOpenKey)
        _panel = State(initialValue: remembered)
        #if DEBUG
        // 截图用：-demoPanel 打开时直接拉出操作列表，-demoFullscreen 直接进全屏
        if ProcessInfo.processInfo.arguments.contains("-demoPanel") {
            _panel = State(initialValue: true)
        }
        if ProcessInfo.processInfo.arguments.contains("-demoFullscreen") {
            _chrome = State(initialValue: false)
        }
        #endif
    }

    private var walls: [Wallpaper] { session.walls }
    private var index: Int? { walls.firstIndex { $0.name == current } }
    private var wall: Wallpaper? { index.map { walls[$0] } }
    private var dragProgress: CGFloat { min(max(dragY, 0) / 400, 1) }
    private var zoomed: Bool { scale > 1.01 }
    private var organizeDisabled: Bool { session.acting != nil || session.state?.running == true }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                Color.black.opacity(1 - dragProgress * 0.85)
                pages(size)
                    .scaleEffect(1 - dragProgress * 0.25)
                    .offset(y: max(dragY, 0))
            }
            .frame(width: size.width, height: size.height)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).midX } action: { screenMidX = $0 }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { doubleTap() }
            .onTapGesture {
                // 点一下藏起 / 显示顶栏和底栏。底部的操作列表开着的话，再点回来还是开着（别顺手收掉）
                withAnimation(.easeOut(duration: 0.2)) { chrome.toggle() }
            }
            .simultaneousGesture(dragGesture(size))
            .simultaneousGesture(magnifyGesture(size))
        }
        .ignoresSafeArea()
        .overlay {
            if chrome {
                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    if let wall { bottomBar(wall) }
                }
                .opacity(axis == .dismiss ? 0 : 1)
                .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { topSafe = $0 }
                .ignoresSafeArea(.keyboard) // 输入编号时底栏别被键盘顶上去
                .transition(.opacity)
            }
        }
        .overlay(alignment: .top) { NoticeBubble(text: session.notice).padding(.top, 60) }
        .presentationBackground(.clear)
        .preferredColorScheme(.dark)
        .statusBarHiddenCompat(!chrome || axis == .dismiss)
        .deleteOriginalDialog(session: session, wall: $confirmDelete)
        .alert("跳到第几张", isPresented: $jumping) {
            TextField("1–\(walls.count)", text: $jumpText).iOSKeyboard(.numberPad)
            Button("跳转") {
                if let n = Int(jumpText), (1...walls.count).contains(n) { go(to: walls[n - 1].name) }
            }
            Button("取消", role: .cancel) {}
        }
        .onChange(of: session.walls) { old, new in
            // 当前这张被移出了：停在原来的位置（就是下一张），删光了就关掉
            guard !new.contains(where: { $0.name == current }) else { return }
            if new.isEmpty {
                dismiss()
                return
            }
            let oldIdx = old.firstIndex { $0.name == current } ?? 0
            go(to: new[min(oldIdx, new.count - 1)].name)
        }
        .sensoryFeedback(.success, trigger: session.walls.count) { old, new in new < old }
        // 关掉预览：记住操作列表是开着还是收着，下次打开还是这个样子
        .onDisappear { UserDefaults.standard.set(panel, forKey: Self.panelOpenKey) }
    }

    // MARK: 翻页

    /// 只摆当前和左右相邻的两页（首尾相接）。按文件名做标识，翻页后视图不重建，大图不会闪一下。
    @ViewBuilder
    private func pages(_ size: CGSize) -> some View {
        let n = walls.count
        if let i = index {
            let slots: [Int] = n == 1 ? [0] : n == 2 ? [0, dragX <= 0 ? 1 : -1] : [-1, 0, 1]
            ZStack {
                ForEach(slots, id: \.self) { d in
                    let w = walls[(i + d + n) % n]
                    PreviewPage(session: session, wall: w, size: size,
                                fitInsets: fitInsets(size),
                                flipped: d == 0 && flipped,
                                scale: d == 0 ? scale : 1,
                                offset: d == 0 ? offset : .zero)
                        .offset(x: CGFloat(d) * (size.width + Self.pageGap) + dragX)
                        .id(w.name)
                }
            }
        }
    }

    /// 完整显示时要让开的上下边距（顶栏底栏显示着的时候）。
    private func fitInsets(_ size: CGSize) -> (top: CGFloat, bottom: CGFloat) {
        guard chrome, let b = bottomBarTop, axis != .dismiss else { return (0, 0) }
        return (topBarBottom, max(0, size.height - b))
    }

    private func step(_ d: Int) {
        guard let i = index, !walls.isEmpty else { return }
        let n = walls.count
        go(to: walls[(i + d + n) % n].name)
    }

    private func go(to name: String) {
        current = name
        resetZoom()
        flipped = false
    }

    private func resetZoom() {
        scale = 1
        baseScale = 1
        offset = .zero
        baseOffset = .zero
    }

    private func doubleTap() {
        withAnimation(.spring(duration: 0.3)) {
            if zoomed {
                resetZoom()
            } else {
                flipped.toggle()
            }
        }
    }

    private func dragGesture(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { v in
                let t = v.translation
                if axis == nil {
                    if zoomed || pinching {
                        axis = .pan
                    } else if abs(t.width) > abs(t.height) {
                        axis = .page
                    } else if t.height < 0 {
                        axis = chrome ? .levels : .ignore // 上滑：常态化拉出列表，列表再上滑进全屏；已经全屏就没得上了
                    } else if chrome && !panel {
                        axis = .dismiss // 常态下滑：关闭预览（图跟着手指）
                    } else {
                        axis = .levels // 列表 / 全屏下滑：退回上一级
                    }
                }
                switch axis {
                case .page:
                    dragX = t.width
                case .dismiss:
                    dragY = t.height
                case .pan:
                    guard !pinching else { return } // 双指时由缩放手势管位置
                    if panStart == nil {
                        panStart = t
                        baseOffset = offset
                    }
                    let s = panStart ?? .zero
                    offset = CGSize(width: baseOffset.width + t.width - s.width,
                                    height: baseOffset.height + t.height - s.height)
                default:
                    break
                }
            }
            .onEnded { v in
                let ended = axis
                axis = nil
                panStart = nil
                switch ended {
                case .page:
                    finishPage(v, size)
                case .dismiss:
                    if v.translation.height > Self.dismissDistance || v.predictedEndTranslation.height > Self.dismissDistance * 3 {
                        axis = .dismiss // 留着：关闭动画里不再闪出顶栏底栏
                        dismiss()
                    } else {
                        withAnimation(.spring(duration: 0.3)) { dragY = 0 }
                    }
                case .levels:
                    let h = v.translation.height, p = v.predictedEndTranslation.height
                    let up = h < -Self.panelDistance || p < -Self.panelDistance * 3
                    let down = h > Self.panelDistance || p > Self.panelDistance * 3
                    withAnimation(.spring(duration: 0.35)) {
                        if up, chrome {
                            if panel {
                                panel = false
                                chrome = false // 列表再上滑：进全屏，全都藏起来
                            } else {
                                panel = true // 常态化上滑：拉出操作列表
                            }
                        } else if down, !chrome || panel {
                            chrome = true // 全屏 / 列表下滑：回常态，顶栏和缩略图条都在
                            panel = false
                        }
                    }
                case .pan:
                    guard !pinching else { return }
                    withAnimation(.spring(duration: 0.3)) { offset = clamped(offset, size) }
                    baseOffset = clamped(offset, size)
                default:
                    break
                }
            }
    }

    /// 横向拖动松手：拖过五分之一屏或甩得够快就翻页（首尾相接），否则弹回。
    /// 门槛按屏宽算但有上限：竖着的手机五分之一屏约 80pt，展开的内屏横着有 900 多 pt 宽，
    /// 按比例要拖 190pt 才翻，用户嫌太费劲，所以和竖屏手机取一样的距离。
    private func finishPage(_ v: DragGesture.Value, _ size: CGSize) {
        let w = size.width
        let moved = v.translation.width
        let flung = v.predictedEndTranslation.width
        let need = min(w * 0.2, Self.pageDistance)
        let fling = min(w * 0.6, Self.pageDistance * 3)
        var d = 0
        if walls.count > 1 {
            if moved < -need || flung < -fling { d = 1 }
            if moved > need || flung > fling { d = -1 }
        }
        guard d != 0 else {
            withAnimation(.spring(duration: 0.3)) { dragX = 0 }
            return
        }
        withAnimation(.easeOut(duration: 0.2)) {
            dragX = -CGFloat(d) * (w + Self.pageGap)
        } completion: {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                step(d)
                dragX = 0
            }
        }
    }

    // MARK: 缩放

    /// 双指缩放：以双指开始的位置为中心放大，松手时小于原大就弹回。
    private func magnifyGesture(_ size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { v in
                if !pinching {
                    pinching = true
                    if axis == .page { withAnimation(.spring(duration: 0.2)) { dragX = 0 } }
                    axis = .pan
                    baseOffset = offset
                    baseScale = scale
                }
                let s = min(max(baseScale * v.magnification, 0.8), Self.maxScale * 1.2)
                let k = s / baseScale
                let p = CGPoint(x: v.startLocation.x - size.width / 2, y: v.startLocation.y - size.height / 2)
                scale = s
                offset = CGSize(width: baseOffset.width * k + p.x * (1 - k),
                                height: baseOffset.height * k + p.y * (1 - k))
                panStart = nil
            }
            .onEnded { _ in
                pinching = false
                withAnimation(.spring(duration: 0.3)) {
                    if scale < 1.05 {
                        resetZoom()
                    } else {
                        scale = min(scale, Self.maxScale)
                        offset = clamped(offset, size)
                    }
                }
                baseScale = scale
                baseOffset = offset
            }
    }

    /// 平移不超出图片边缘。
    private func clamped(_ o: CGSize, _ size: CGSize) -> CGSize {
        guard let wall, let img = PreviewPage.image(session, wall) else { return .zero }
        let fill = PreviewPage.prefersFill(img.size, in: size) != flipped
        let base = PreviewPage.fitted(img.size, in: PreviewPage.box(size, fill: fill, insets: fitInsets(size)), fill: fill)
        let mx = max(0, (base.width * scale - size.width) / 2)
        let my = max(0, (base.height * scale - size.height) / 2)
        return CGSize(width: min(max(o.width, -mx), mx), height: min(max(o.height, -my), my))
    }

    // MARK: 顶栏、底栏

    /// 顶栏：左边关闭、撤销移出，右边分享原图，编号在正中（不管两边有几个按钮）。
    private var topBar: some View {
        HStack(spacing: 10) {
            circleButton("xmark", label: "关闭") { dismiss() }
            if let undo = session.undoName {
                circleButton("arrow.uturn.backward", label: "撤销移出 \(undo)") {
                    Task {
                        if let n = await session.undoRemove(), walls.contains(where: { $0.name == n }) { go(to: n) }
                    }
                }
                .disabled(session.acting != nil || session.state?.running == true)
            }
            Spacer()
            if let wall {
                ShareOriginalButton(session: session, wall: wall)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
            }
        }
        .overlay {
            if let index {
                Button {
                    jumpText = ""
                    jumping = true
                } label: {
                    Text("\(index + 1) / \(walls.count)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("第 \(index + 1) 张，共 \(walls.count) 张")
                .accessibilityHint("输入编号跳转")
            }
        }
        .padding(.horizontal, 20)
        // 竖屏有状态栏垫着，离安全区 8 就够；横屏安全区几乎为 0，按钮离屏幕上边缘至少留 20
        .padding(.top, max(8, 20 - topSafe))
        .padding(.bottom, 8)
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { topBarBottom = $0 }
    }

    private func circleButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.body.weight(.semibold)).frame(width: 36, height: 36)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .accessibilityLabel(label)
    }

    private func bottomBar(_ w: Wallpaper) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // 把手：提示可以上滑，点它也能开关（VoiceOver 用户没法靠滑动）
            Button {
                withAnimation(.spring(duration: 0.35)) { panel.toggle() }
            } label: {
                Capsule().fill(.secondary).frame(width: 36, height: 5)
                    .frame(maxWidth: .infinity).padding(.vertical, 2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.bottom, -6)
            .accessibilityLabel(panel ? "收起操作" : "显示操作")
            FilmStrip(session: session, current: current, screenMidX: screenMidX) { go(to: $0) }
                .padding(.horizontal, -16) // 缩略图条撑满整行
            if panel {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(w.name).font(.subheadline.bold()).lineLimit(1).truncationMode(.middle)
                        Text(w.hasSource ? "原图：\(w.source ?? "")" : "原图：没有记录（之前的版本换上的），只能移出")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                    }
                    if session.state?.running == true {
                        Label("正在换壁纸，等换完再整理", systemImage: "hourglass").font(.footnote).foregroundStyle(.secondary)
                    }
                    // 按宽度挑：一排普通按钮 → 一排小号按钮 → 工具栏式（图标在上、小字在下，四列平分，和相册底栏一样）。
                    // 不再竖着排成四行（竖屏时太占高度，用户嫌）：底栏越矮，完整显示的图越大
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { actionButtons(w) }.buttonStyle(.bordered)
                        HStack(spacing: 6) { actionButtons(w) }.buttonStyle(.bordered).controlSize(.small)
                        HStack(spacing: 0) { actionButtons(w, toolbar: true) }
                            .buttonStyle(.borderless)
                            .labelStyle(ToolbarLabelStyle())
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, ignoresSafeAreaEdges: [.bottom, .horizontal])
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { bottomBarTop = $0 }
    }

    /// toolbar：工具栏式，每个按钮平分宽度、文字可以缩小
    @ViewBuilder
    private func actionButtons(_ w: Wallpaper, toolbar: Bool = false) -> some View {
        Button {
            Task { await session.saveOriginal(w) }
        } label: {
            Label(session.saving == w.name ? "正在下载…" : "存到相册", systemImage: "square.and.arrow.down").actionLabel(toolbar)
        }
        .disabled(session.saving != nil || session.offline) // 要从电脑下载原文件，离线时做不了
        .accessibilityHint(WallAction.saveHint)
        Button {
            Task { await session.removeWallpaper(w, exclude: false) }
        } label: {
            Label("移出", systemImage: "minus.circle").actionLabel(toolbar)
        }
        .disabled(organizeDisabled)
        .accessibilityHint(WallAction.removeHint)
        if w.hasSource {
            Button {
                Task { await session.removeWallpaper(w, exclude: true) }
            } label: {
                Label("不再选它", systemImage: "nosign").actionLabel(toolbar)
            }
            .disabled(organizeDisabled)
            .accessibilityHint(WallAction.excludeHint)
            Button(role: .destructive) {
                confirmDelete = w
            } label: {
                Label("删除原图…", systemImage: "trash").actionLabel(toolbar)
            }
            .disabled(organizeDisabled || session.offline) // 离线时不排队删原图，等连上再做
        }
        if session.acting == w.name {
            ProgressView()
        }
    }
}

/// 预览里的一页：按屏幕形状决定铺满还是完整显示，再叠上缩放和平移。
private struct PreviewPage: View {
    let session: RemoteSession
    let wall: Wallpaper
    let size: CGSize
    /// 完整显示时上下要让开的距离（顶栏、底栏）；铺满时不让，图片铺到整屏
    var fitInsets: (top: CGFloat, bottom: CGFloat) = (0, 0)
    var flipped = false
    var scale: CGFloat = 1
    var offset: CGSize = .zero
    @State private var image: PlatformImage?
    /// 加载过了（成功或失败）：失败时给一句明确的话，不再一直转圈
    @State private var tried = false

    var body: some View {
        ZStack {
            if let img = image ?? Self.image(session, wall) {
                let fill = Self.prefersFill(img.size, in: size) != flipped
                let s = Self.fitted(img.size, in: Self.box(size, fill: fill, insets: fitInsets), fill: fill)
                let shift = fill ? 0 : (fitInsets.top - fitInsets.bottom) / 2
                Image(platformImage: img)
                    .resizable()
                    .frame(width: s.width * scale, height: s.height * scale)
                    .offset(x: offset.width, y: offset.height + shift)
            } else if tried {
                VStack(spacing: 8) {
                    Image(systemName: session.offline ? "icloud.slash" : "photo.badge.exclamationmark")
                        .font(.largeTitle)
                    Text(session.offline ? "这张还没缓存" : "读不了这张图").font(.headline)
                    if session.offline {
                        Text("连上电脑后整批图片会自动存到手机上").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .overlay(alignment: .bottom) {
            // 离线、大图还没缓存，但缩略图在：先拿缩略图垫着，顺便说明一下（不然看着像糊了）
            if tried, session.offline, bigImage == nil, thumbImage != nil {
                Text("离线 · 大图还没缓存，显示的是缩略图")
                    .font(.caption2)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 12)
            }
        }
        .task(id: wall.name + (session.offline ? "|offline" : "|online")) {
            tried = false
            if bigImage == nil {
                image = await ImageStore.shared.load(session, wall.name, .image)
            }
            tried = true
        }
    }

    /// 内存里或磁盘上的大图（离线时可能是上次看过的）。
    private var bigImage: PlatformImage? {
        image ?? ImageStore.shared.cached(session, wall.name, .image)
    }

    private var thumbImage: PlatformImage? {
        ImageStore.shared.cached(session, wall.name, .thumb)
    }

    /// 内存里已有的图：大图优先，没有就先用缩略图垫着。
    @MainActor
    static func image(_ session: RemoteSession, _ wall: Wallpaper) -> PlatformImage? {
        ImageStore.shared.cached(session, wall.name, .image) ?? ImageStore.shared.cached(session, wall.name, .thumb)
    }

    /// 屏幕横着（iPhone Duo 内屏、手机横放）时铺满，看着更有冲击力；
    /// 但要裁掉超过三成（比如超宽图）就还是完整显示。竖屏（外屏）一律完整显示。
    static func prefersFill(_ img: CGSize, in box: CGSize) -> Bool {
        guard box.width > box.height, img.width > 0, img.height > 0, box.height > 0 else { return false }
        let a = img.width / img.height, b = box.width / box.height
        return 1 - min(a / b, b / a) <= 0.3
    }

    /// 图片可用的区域：完整显示时扣掉上下让开的部分。
    static func box(_ size: CGSize, fill: Bool, insets: (top: CGFloat, bottom: CGFloat)) -> CGSize {
        fill ? size : CGSize(width: size.width, height: max(size.height - insets.top - insets.bottom, size.height / 3))
    }

    /// 按图片比例放进 box：fill 时铺满（多出的部分裁掉），否则完整显示。
    static func fitted(_ img: CGSize, in box: CGSize, fill: Bool) -> CGSize {
        guard img.width > 0, img.height > 0 else { return box }
        let k = fill ? max(box.width / img.width, box.height / img.height)
                     : min(box.width / img.width, box.height / img.height)
        return CGSize(width: img.width * k, height: img.height * k)
    }
}

/// 底部缩略图条：拖动时当前大图跟着变（像「照片」底部那条），点一张直接跳过去。
private struct FilmStrip: View {
    let session: RemoteSession
    let current: String
    /// 屏幕正中的横坐标（全局坐标）
    let screenMidX: CGFloat?
    let onSelect: (String) -> Void
    @State private var pos: String?
    /// 正在跟着大图滚动（不是手指拖的），这段时间里滚过的缩略图不算选中
    @State private var following = false

    private static let thumb = CGSize(width: 44, height: 30)

    var body: some View {
        // 用 GeometryReader 在第一次布局时就拿到位置：两边留白要靠它算，否则一打开当前那张不在正中间
        GeometryReader { geo in
            // 当前那张对齐屏幕正中（不是这条自己的正中：内屏侧边有传感器区，这条会让开一块）
            let f = geo.frame(in: .global)
            let mid = min(max((screenMidX ?? f.midX) - f.minX, Self.thumb.width / 2), max(f.width - Self.thumb.width / 2, Self.thumb.width / 2))
            strip(width: f.width, mid: mid)
        }
        .frame(height: Self.thumb.height + 8)
        .onAppear { pos = current }
        .onChange(of: current) { _, new in
            guard pos != new else { return }
            following = true
            withAnimation(.easeOut(duration: 0.25)) { pos = new }
            Task {
                try? await Task.sleep(for: .milliseconds(350))
                following = false
            }
        }
        .onChange(of: pos) { _, new in
            if let new, new != current, !following { onSelect(new) }
        }
        .sensoryFeedback(.selection, trigger: current)
        .accessibilityHidden(true) // 读屏用顶部的编号和左右滑就够了
    }

    private func strip(width: CGFloat, mid: CGFloat) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 3) {
                ForEach(session.walls) { w in
                    WallImage(session: session, wall: w)
                        .frame(width: Self.thumb.width, height: Self.thumb.height)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay {
                            if w.name == current {
                                RoundedRectangle(cornerRadius: 4).strokeBorder(.white, lineWidth: 2)
                            }
                        }
                        .scaleEffect(w.name == current ? 1.12 : 1)
                        .onTapGesture { onSelect(w.name) }
                        .id(w.name)
                }
            }
            .scrollTargetLayout()
            .padding(.vertical, 3)
        }
        .scrollIndicators(.hidden)
        .contentMargins(.leading, mid - Self.thumb.width / 2, for: .scrollContent)
        .contentMargins(.trailing, width - mid - Self.thumb.width / 2, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $pos, anchor: UnitPoint(x: width > 0 ? mid / width : 0.5, y: 0.5))
    }
}

/// 工具栏式按钮的标签：图标在上、小字在下。
struct ToolbarLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 4) {
            configuration.icon.font(.title3)
            configuration.title.font(.caption2).lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(.vertical, 4)
    }
}

private extension View {
    /// 一排按钮时标签保持原宽（不换行）；工具栏式时撑满平分的那一列
    @ViewBuilder
    func actionLabel(_ toolbar: Bool) -> some View {
        if toolbar {
            frame(maxWidth: .infinity).contentShape(Rectangle())
        } else {
            fixedSize()
        }
    }
}
