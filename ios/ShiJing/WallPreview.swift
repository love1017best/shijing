import SwiftUI
import UIKit

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
    /// 文件名（和原图路径）：上滑显示，下滑收起。四个整理操作和关闭、分享常驻在底部，不用上滑
    @State private var showsInfo = false

    // 拖动：一次拖动开头判断方向，之后不变
    /// levels：上下滑切文件名（常态上滑显示、下滑收起；全屏下滑回到常态）
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
    /// 窗口的安全区：整页 `ignoresSafeArea` 铺满之后，页面里量到的安全区是 0，所以从窗口上取。
    /// 靠一层探针视图（`WindowSafeInsets`）在窗口布局完时报告——直接在 SwiftUI 的
    /// `onGeometryChange` 里读窗口 insets，转屏时读到的是转屏前那一份（SwiftUI 先布局、
    /// UIKit 后更新窗口 insets），横屏会一直用竖屏的 82pt（踩过）。
    @State private var windowSafe = UIEdgeInsets.zero
    @State private var bottomBarTop: CGFloat?
    @State private var jumping = false
    @State private var jumpText = ""
    /// 当前这张的模糊底：图片没铺满屏幕时（竖屏看横图）显示在上下留白里，顶栏底栏浮在它上面
    @State private var backdrop: PlatformImage?
    @Environment(\.dismiss) private var dismiss

    private static let pageGap: CGFloat = 16
    private static let dismissDistance: CGFloat = 120
    /// 翻页至少要拖的距离上限（见 finishPage）
    private static let pageDistance: CGFloat = 80
    private static let maxScale: CGFloat = 5
    /// 上滑显示 / 下滑收起文件名要拖的距离
    private static let panelDistance: CGFloat = 40
    /// 文件名开着还是收着：关预览时记住，下次打开还是上次的样子
    private static let infoOpenKey = "previewInfoOpen"

    init(session: RemoteSession, startName: String) {
        self.session = session
        _current = State(initialValue: startName)
        let remembered = UserDefaults.standard.bool(forKey: Self.infoOpenKey)
        _showsInfo = State(initialValue: remembered)
        #if DEBUG
        // 截图用：-demoInfo 打开时直接显示文件名，-demoFullscreen 直接进全屏
        if ProcessInfo.processInfo.arguments.contains("-demoInfo") {
            _showsInfo = State(initialValue: true)
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

    var body: some View {
        ZStack(alignment: .top) {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                Color.black
                if let backdrop {
                    Image(platformImage: backdrop)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size.width, height: size.height)
                        .blur(radius: 40)
                        .overlay(Color.black.opacity(0.45))
                        .clipped()
                        .opacity(1 - dragProgress)
                } else {
                    Color.black.opacity(1 - dragProgress * 0.85)
                }
                pages(size)
                    .scaleEffect(1 - dragProgress * 0.25)
                    .offset(y: max(dragY, 0))
            }
            .frame(width: size.width, height: size.height)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).midX } action: { screenMidX = $0 }
            .contentShape(Rectangle())
            // 双击和单击要互斥：分开挂两个 onTapGesture 的话，双击的第一下会先触发一次单击，
            // 切「铺满 / 完整」时顶栏底栏也跟着闪一下。
            .gesture(
                ExclusiveGesture(
                    TapGesture(count: 2).onEnded { doubleTap() },
                    TapGesture().onEnded {
                        // 点一下藏起 / 显示顶栏和底栏。文件名开着的话，再点回来还是开着（别顺手收掉）
                        withAnimation(.easeOut(duration: 0.2)) { chrome.toggle() }
                    }
                )
            )
            .simultaneousGesture(dragGesture(size))
            .simultaneousGesture(magnifyGesture(size))
        }
        // 顶栏底栏浮在图上
        if chrome {
            VStack(spacing: 0) {
                topBar
                Spacer()
                if let wall { bottomBar(wall) }
            }
            // 底部让开小横条（整页铺满了，安全区得自己留）
            .padding(.bottom, max(24, windowSafe.bottom + 12))
            .opacity(axis == .dismiss ? 0 : 1)
            .ignoresSafeArea(.keyboard) // 输入编号时底栏别被键盘顶上去
            .transition(.opacity)
        }
        }
        // 整页铺满：全屏页的内容区会被首页那条浮动标签栏挤窄 84pt（只有 382 宽），
        // 顶栏底栏跟着一起缩的话编号不在屏幕正中、按钮整排偏左
        .ignoresSafeArea()
        // 窗口的安全区（转屏后会自己重报，见 WindowSafeInsets）
        .background(WindowSafeInsets { if $0 != windowSafe { windowSafe = $0 } }.allowsHitTesting(false))
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
        .onDisappear { UserDefaults.standard.set(showsInfo, forKey: Self.infoOpenKey) }
        .task(id: current) {
            let store = ImageStore.shared
            if let img = store.cached(session, current, .thumb) {
                backdrop = img
            } else {
                backdrop = await store.load(session, current, .thumb)
            }
        }
    }

    // MARK: 翻页

    /// 只摆当前和左右相邻的两页（首尾相接）。身份按文件名算：翻页时相邻页只是换了位置，
    /// 视图（连同已经解好的图）不用重建，滑动时也不会闪一下。
    @ViewBuilder
    private func pages(_ size: CGSize) -> some View {
        let n = walls.count
        if let i = index {
            let slots: [Int] = n == 1 ? [0] : n == 2 ? [0, dragX <= 0 ? 1 : -1] : [-1, 0, 1]
            let pages = slots.map { PageSlot(d: $0, w: walls[(i + $0 + n) % n]) }
            ZStack {
                ForEach(pages) { p in
                    let d = p.d
                    PreviewPage(session: session, wall: p.w, size: size,
                                fitInsets: fitInsets(size),
                                flipped: d == 0 && flipped,
                                scale: d == 0 ? scale : 1,
                                offset: d == 0 ? offset : .zero)
                        .offset(x: CGFloat(d) * (size.width + Self.pageGap) + dragX)
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
                        axis = chrome && !showsInfo ? .levels : .ignore // 上滑：显示文件名（全屏、已经显示着就没得上了）
                    } else if chrome && !showsInfo {
                        axis = .dismiss // 常态下滑：关闭预览（图跟着手指）
                    } else {
                        axis = .levels // 文件名 / 全屏下滑：收起文件名、回到常态
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
                        if up, chrome, !showsInfo {
                            showsInfo = true // 上滑：显示文件名
                        } else if down {
                            if showsInfo {
                                showsInfo = false // 下滑：收起文件名
                            } else {
                                chrome = true // 全屏下滑：回到常态
                            }
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
                // 方向锁复位：不然缩放完再单指滑，会一直走平移分支，不翻页也不关闭
                axis = nil
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

    /// 顶栏：左边撤销移出，编号在正中。关闭和分享挪到了底部，和四个整理操作一起常驻。
    private var topBar: some View {
        HStack(spacing: 10) {
            if let undo = session.undoName {
                circleButton("arrow.uturn.backward", label: "撤销移出 \(undo)") {
                    Task {
                        if let n = await session.undoRemove(), walls.contains(where: { $0.name == n }) { go(to: n) }
                    }
                }
                .disabled(session.acting != nil || session.state?.running == true)
            }
            Spacer()
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
                        .glassBackground(in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("第 \(index + 1) 张，共 \(walls.count) 张")
                .accessibilityHint("输入编号跳转")
            }
        }
        .padding(.horizontal, 20)
        // 铺满全屏后 padding 是从屏幕边缘算的，安全区得自己加：竖屏状态栏 / 灵动岛下面再留 8，
        // 横屏（安全区几乎为 0）离上边缘至少 28，不然编号贴着屏幕边
        .padding(.top, max(windowSafe.top + 8, 28))
        .padding(.bottom, 8)
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { topBarBottom = $0 }
    }

    /// 圆形的玻璃按钮（关闭、撤销、分享）。
    private func circleButton(_ icon: String, label: String, size: CGFloat = 44,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.body.weight(.semibold))
                .frame(width: size, height: size)
                .glassBackground(in: Circle(), interactive: true)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func bottomBar(_ w: Wallpaper) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // 把手：上滑 / 点它显示、收起文件名（VoiceOver 用户没法靠滑动）
            Button {
                withAnimation(.spring(duration: 0.35)) { showsInfo.toggle() }
            } label: {
                Capsule().fill(.secondary).frame(width: 36, height: 5)
                    .frame(maxWidth: .infinity).padding(.vertical, 2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showsInfo ? "收起文件名" : "显示文件名")

            FilmStrip(session: session, current: current, screenMidX: screenMidX) { go(to: $0) }
                .padding(.horizontal, -20) // 缩略图条撑满整行

            if showsInfo {
                VStack(alignment: .leading, spacing: 2) {
                    Text(w.name).font(.subheadline.bold()).lineLimit(1).truncationMode(.middle)
                    Text(w.hasSource ? "原图：\(w.source ?? "")" : "原图：没有记录（之前的版本换上的），只能移出")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassBackground(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if session.state?.running == true {
                Label("正在换壁纸，等换完再整理", systemImage: "hourglass")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            actionBar(w)
        }
        .padding(.horizontal, 20).padding(.top, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { bottomBarTop = $0 }
    }

    /// 常驻的一排悬浮按钮：关闭、分享，右边是四个整理操作。每块都是独立的液态玻璃。
    /// 用 GeometryReader 拿这一行分到的宽度（466 宽的 Duo 外屏放不下宽松的那套，约 452，
    /// 要换成紧凑的 56pt 方块）。不能用 ViewThatFits 猜：按钮里的文字可以缩，
    /// 它量出来的宽度偏乐观，会挑到放不下的那种，画到屏幕外面去。
    private func actionBar(_ w: Wallpaper) -> some View {
        GeometryReader { g in
            let compact = g.size.width < 460 // 宽松那套约 452 宽，放不下就换 56pt 的方块
            HStack(spacing: compact ? 6 : 10) {
                circleButton("xmark", label: "关闭", size: compact ? 40 : 44) { dismiss() }
                ShareOriginalButton(session: session, wall: w, glass: true, size: compact ? 40 : 44)
                Spacer(minLength: compact ? 6 : 12)
                actionButtons(w, width: compact ? 56 : 78)
            }
        }
        .frame(height: 52)
    }

    @ViewBuilder
    private func actionButtons(_ w: Wallpaper, width: CGFloat) -> some View {
        ForEach(WallActionKind.allCases, id: \.self) { kind in
            if !kind.needsSource || w.hasSource {
                let enabled = kind.isEnabled(session, w)
                Button(role: kind.isDestructive ? .destructive : nil) {
                    kind.perform(session, w, confirmDelete: $confirmDelete)
                } label: {
                    actionLabel(kind, w, width: width)
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.45)
                .accessibilityLabel(kind == .save && session.saving == w.name ? "正在下载" : kind.barTitle)
                .accessibilityHint(kind.hint)
            }
        }
    }

    /// 一块玻璃里图标在上、小字在下（和相册底栏一样），窄屏和宽屏只差一点宽度。
    private func actionLabel(_ kind: WallActionKind, _ w: Wallpaper, width: CGFloat) -> some View {
        VStack(spacing: 3) {
            if kind == .save, session.saving == w.name {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: kind.icon).font(.system(size: 17, weight: .semibold))
            }
            Text(kind.barTitle)
                .font(.caption2)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(width: width, height: 52)
        .foregroundStyle(kind.isDestructive ? Color.red : Color.primary)
        .glassBackground(in: RoundedRectangle(cornerRadius: 16, style: .continuous), interactive: true)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// 预览里的一页：位置（-1 左 / 0 当前 / 1 右）和那张壁纸。身份是文件名，翻页时图不会被重建。
private struct PageSlot: Identifiable {
    let d: Int
    let w: Wallpaper
    var id: String { w.name }
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
    /// 重新加载一次（切到后台再回来时，正在下载的这次会被系统掐断，回来要重试）
    @State private var retry = 0
    @Environment(\.scenePhase) private var scenePhase

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
                    .glassBackground(in: Capsule())
                    .padding(.bottom, 12)
            }
        }
        .task(id: wall.name + (session.offline ? "|offline" : "|online") + "|\(retry)") {
            tried = false
            if bigImage == nil {
                image = await ImageStore.shared.load(session, wall.name, .image)
            }
            tried = true
        }
        .onChange(of: scenePhase) { _, phase in
            // 切回前台：上次正在下载的话可能被系统掐断、落成「读不了这张图」，重试一次
            if phase == .active, tried, bigImage == nil { retry += 1 }
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
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 1) // 直接浮在图上，给一点阴影
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


/// 报告窗口的安全区。大图预览整页 `ignoresSafeArea` 铺满屏幕，页面里的安全区是 0，
/// 顶栏底栏的留白得按窗口的安全区自己算。窗口布局（首次出现、转屏）时读一次、
/// 再 `async` 回主线程报出去——在布局过程中直接改 SwiftUI 的状态会报「during view update」。
private struct WindowSafeInsets: UIViewRepresentable {
    let onChange: (UIEdgeInsets) -> Void

    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ probe: Probe, context: Context) { probe.onChange = onChange }

    final class Probe: UIView {
        var onChange: ((UIEdgeInsets) -> Void)?

        override func didMoveToWindow() { super.didMoveToWindow(); report() }
        override func layoutSubviews() { super.layoutSubviews(); report() }
        override func safeAreaInsetsDidChange() { super.safeAreaInsetsDidChange(); report() }

        private func report() {
            guard let insets = window?.safeAreaInsets else { return }
            DispatchQueue.main.async { [weak self] in self?.onChange?(insets) }
        }
    }
}
