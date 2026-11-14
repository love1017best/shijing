import SwiftUI
import UIKit

/// 大图预览：左右滑翻看壁纸文件夹里的全部图片（首尾相接，和桌面一样），双指缩放，
/// 底部缩略图条可以拖着快速找图，点顶部编号可以输入编号跳转。
/// 上下滑分两级（用户要求）：上滑一次显示文件名（顶栏和缩略图条都在），再上滑进入全屏（全部藏起来只剩图）；
/// 全屏下滑回到常态（顶栏和缩略图条回来），文件名开着时下滑也是回到常态，常态下滑（图跟着手指）才关闭预览。
/// 缩略图条不会在收文件名的时候莫名其妙消失。操作完停在原位置，看到的就是下一张。
///
/// 按钮照各设备的系统相册（v0.3.163，对着 Duo、iPad、iPhone 上的相册截图定的）：只有图标、不带文字。
/// 宽屏（Duo 内屏、iPad）放在顶部一排——左边关闭、撤销、编号，右边分享和整理操作；宽屏横放（Duo 内屏、
/// 外屏）时按钮收到右边一竖列，像相册横放那样。普通 iPhone 和 Duo 外屏放不下这一排，还是底部一排：
/// 左边分享、中间一块玻璃装三个整理操作、右边红色的删除。
///
/// 翻页是自己写的（只摆上一张、当前、下一张三页，跟着手指移动），不用 TabView(.page) / 分页 ScrollView：
/// 首尾循环、缩放后单指平移、往下拖关闭都要和翻页抢同一个拖动手势，放在一起判断方向最省事。
/// TabView 还会按扣掉安全区的宽度分页，iPhone Duo 内屏横放时侧边有传感器区，每页比屏幕窄（踩过）。
struct WallPreview: View {
    let session: RemoteSession
    @State private var current: String
    @State private var confirmDelete: Wallpaper?
    @State private var chrome = true
    /// 文件名（和原图路径）：上滑显示，下滑收起。关闭、分享和四个整理操作常驻，不用上滑
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
    /// 整页的尺寸（判断宽屏横放用，见 sideColumn）
    @State private var screenSize = CGSize.zero
    /// 前置摄像头（被占用的那块玻璃）在页面里的位置：iPhone Duo 外屏竖放时在右上，横放时跟着设备转到左边或右边。
    /// 右边那一列按钮就放在这同一侧，和摄像头、状态栏对齐（`reservedRegions(kind: .occlusion)`，iOS 27.1 起）
    @State private var cameraFrame: CGRect = CGRect(x: 0, y: 0, width: 0, height: 0)
    /// 按钮列放右边还是左边（见 cameraFrame）
    @State private var columnOnRight = true
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

    /// 宽屏（Duo 内屏、iPad）：按钮照系统相册放到顶部一排。普通 iPhone（402 宽）放不下
    /// 一排按钮加编号，还是底部一排。
    private var wide: Bool { screenSize.width >= 640 }

    /// 右边一竖列（照系统相册）：Duo 内屏横放、外屏横放和竖放都是这样（外屏系统报的是 regular 尺寸类，
    /// 但系统相册在它上面照样用右侧一列）。只有高度够的宽屏才用顶部一排（iPad、Duo 内屏竖放），
    /// 所以按高度分：约 700 以下收成一列。按屏幕形状判断，不按机型。
    /// 宽度门槛取 420：真机 Duo 外屏量到 457×678、模拟器是 466×678，普通 iPhone 竖屏只有 402 宽
    /// 且高都 ≥ 700，420 两边都不卡（v0.3.165 踩过：先前写 460，真机差 3pt 落空，外屏还是底部一排）。
    private var sideColumn: Bool {
        screenSize.height < 700 && screenSize.width >= 420
    }

    /// 侧列放不下常规尺寸时的小一号。门槛按「整列（含撤销）放不放得下」算：常规尺寸整列约 44×4 + 48 + 8×4 ≈ 316，
    /// 加上离边距的一点留白，屏幕高 380 以下的才需要缩（iPhone SE 横放 375）；Duo 外屏横放 466、
    /// iPhone 15 Pro 横放 402 都用常规寸（v0.3.166：以前按 520 分，Duo 外屏横放被当成小屏，按钮 38 比系统相册小一号）。
    private var tightColumn: Bool { sideColumn && screenSize.height < 380 }

    /// 横放、右边一竖列，屏幕小（Duo 外屏、普通手机横放）。这些形状下系统自己就不画状态栏，
    /// 我们也不显示。Duo 内屏横放例外（屏幕高 669）：系统相册在那里保留右上角那块状态栏
    /// （时间、电量、信号竖着排），按钮列从它下面开始排——所以不能一律藏掉。
    private var hideStatusBarInLandscape: Bool {
        sideColumn && screenSize.width > screenSize.height && screenSize.height < 640
    }

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
            .onGeometryChange(for: CGSize.self) { $0.size } action: { if $0 != screenSize { screenSize = $0 } }
            // 前置摄像头在哪一侧（iPhone Duo 外屏的挖孔，横放时跟着设备换边）
            .onGeometryChange(for: CGRect.self) { proxy in
                if #available(iOS 27.1, *) {
                    return proxy.reservedRegions(kind: .occlusion).first?.frame ?? .zero
                }
                return .zero
            } action: { f in
                if f != cameraFrame { cameraFrame = f }
                let onRight = cameraFrame == .zero || cameraFrame.midX > screenSize.width / 2
                if onRight != columnOnRight { columnOnRight = onRight }
            }
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
            // 顶栏、底栏、右边那一列都放进同一个 ZStack：overlay 给子视图的高度提案不一定等于整屏，
            // 侧列想贴顶时被压到中间偏下（v0.3.168 内屏横放踩过，改了 `.frame(alignment:)` 也不动）。
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    if let wall { bottomBar(wall) }
                }
                // 底部让开小横条（整页铺满了，安全区得自己留）
                .padding(.bottom, max(24, windowSafe.bottom + 12))

                // 宽屏横放：按钮照系统相册收到一竖列，放在前置摄像头那一侧（和状态栏对齐）
                if sideColumn, let wall {
                    HStack(spacing: 0) {
                        if !columnOnRight {
                            sideButtons(wall)
                            Spacer(minLength: 0)
                        } else {
                            Spacer(minLength: 0)
                            sideButtons(wall)
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
            }
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
        // 隐藏顶栏底栏时状态栏也藏掉；小屏横放（外屏、普通手机）也一样：系统本来就不显示，
        // 留着会压到右边那一列上。Duo 内屏横放不藏——系统相册在那里照样显示，列从它下面开始。
        .statusBarHiddenCompat(!chrome || axis == .dismiss || hideStatusBarInLandscape)
        // 删除确认不挂在这一层：iPad、Duo 这种 regular 宽度上确认框是 popover，挂整页会飘到屏幕中间，
        // 和按下那颗删除按钮差很远。改挂在每个版式的删除按钮上（见 topActions / sideButtons / actionRow）。
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
        .onAppear(perform: demoOpenDialogs)
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

    /// 截图用：模拟器里点不动按钮，用启动参数直接把删除确认框弹出来，看它弹在哪
    private func demoOpenDialogs() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-demoConfirmDelete") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { confirmDelete = wall }
        }
        #endif
    }

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

    /// 编号胶囊，点开输入编号跳转。
    private func numberPill(_ i: Int) -> some View {
        Button {
            jumpText = ""
            jumping = true
        } label: {
            Text("\(i + 1) / \(walls.count)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.primary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .glassBackground(in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("第 \(i + 1) 张，共 \(walls.count) 张")
        .accessibilityHint("输入编号跳转")
    }

    /// 顶栏。关闭和撤销在左、编号跟在后面；宽屏照系统相册把分享和整理操作放顶部右边一排；
    /// 右边一列的时候顶部只剩编号，按钮都在列里（见 sideButtons）。
    /// 编号以前是 `.overlay` 挂在整条顶栏正中间，Duo 内屏竖放右边那组按钮一宽（分享 + 三个图标的胶囊 + 删除
    /// 约 260pt）就顶到编号右缘上了（v0.3.168 用户反馈「跳转按钮和编号重叠」）。现在编号是这一行里的
    /// 普通一项，右边靠 Spacer 撑开，不会再叠；窄屏（普通 iPhone）还是要居中，用两个 Spacer 夹住。
    private var topBar: some View {
        HStack(spacing: 8) {
            if !sideColumn {
                circleButton("xmark", label: "关闭", size: topButtonSize) { dismiss() }
                if let undo = session.undoName { undoButton(undo, size: topButtonSize) }
            }
            if sideColumn || !wide {
                Spacer(minLength: 8)
                if let index { numberPill(index) }
                Spacer(minLength: 8)
            } else {
                if let index { numberPill(index) }
                Spacer(minLength: 8)
                if let wall { topActions(wall) }
            }
        }
        .padding(.horizontal, 20)
        // Duo 内屏竖放：系统相册把按钮行和右上角的时间、信号放在同一行（v0.3.167）
        .padding(.trailing, topRowBesideStatusBar ? 120 : 0)
        // 铺满全屏后 padding 是从屏幕边缘算的，安全区得自己加：竖屏状态栏 / 灵动岛下面再留 8，
        // 横屏（安全区几乎为 0）离上边缘至少 28，不然编号贴着屏幕边。
        // Duo 内屏竖放例外：状态栏本来就占着顶上一整行（安全区 82），按钮行要跟它并排、不能落到下面
        // （21 让 38 高的按钮中心落在 40，量系统相册同一行的按钮中心就是 40，见 topBarTopPadding）。
        .padding(.top, topBarTopPadding)
        .padding(.bottom, 8)
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { topBarBottom = $0 }
    }

    /// 顶栏这一排的按钮直径。Duo 内屏竖放那种和状态栏并排的排法，系统相册用 38（量过），
    /// 一直用 44 会比状态栏那一行明显大一号（v0.3.168 用户反馈「按钮大小还是不对」）。
    private var topButtonSize: CGFloat { topRowBesideStatusBar ? 38 : 44 }
    /// 整理操作那块胶囊的高度，跟着圆钮一起收。
    private var topPillSize: CGFloat { topRowBesideStatusBar ? 42 : 48 }

    /// 顶栏离上边缘多远。右边一列时顶部只剩编号：
    /// 横放时状态栏在右上角竖着排（内屏）或者根本不显示（外屏），编号照系统相册那条日期卡贴顶放 28；
    /// 竖放时状态栏是竖着排在右上角的，编号比它再往下一点（用户嫌贴着屏幕边，v0.3.168 从 28 提到 40）。
    private var topBarTopPadding: CGFloat {
        // 21 让 38 高的按钮中心落在 40，和系统相册那一行、状态栏（安全区 82 的一半）同一个高度
        if topRowBesideStatusBar { return 21 }
        if sideColumn {
            if screenSize.width > screenSize.height { return 28 }
            return max(windowSafe.top + 12, 40)
        }
        return max(windowSafe.top + 8, 28)
    }

    /// 顶部那一排按钮要不要和状态栏并排：只有 Duo 内屏竖放是这样（系统相册里关闭、分享、日期、
    /// 滑块、删除排成一行，最右边才是时间和信号）。按屏幕形状认：宽屏竖放、宽度不到 iPad 那档
    /// （Duo 内屏竖放 669×951，iPad 竖放最窄的 mini 也有 744 宽）。以前按窗口顶安全区 > 60 认，
    /// 真机上读到的值和模拟器不一样，按钮行就掉到状态栏下面去了（v0.3.168）。
    /// 右边的按钮组要让开状态栏那一块（实测内屏竖放状态栏从 558pt 起、屏宽 669），留 120。
    private var topRowBesideStatusBar: Bool {
        wide && !sideColumn && screenSize.height > screenSize.width && screenSize.width < 700
    }

    private func undoButton(_ name: String, size: CGFloat = 44) -> some View {
        circleButton("arrow.uturn.backward", label: "撤销移出 \(name)", size: size) {
            Task {
                if let n = await session.undoRemove(), walls.contains(where: { $0.name == n }) { go(to: n) }
            }
        }
        .disabled(session.acting != nil || session.state?.running == true)
    }

    /// 宽屏竖屏时顶栏右边这一组（照系统相册）：分享、一块玻璃里三个整理操作、红色的删除。
    private func topActions(_ w: Wallpaper) -> some View {
        HStack(spacing: 8) {
            ShareOriginalButton(session: session, wall: w, glass: true, size: topButtonSize)
            actionPill(w, size: topPillSize)
            actionCircle(.delete, w, size: topButtonSize)
                .deleteOriginalDialog(session: session, wall: $confirmDelete)
        }
    }

    /// 那一竖列（照系统相册）：撤销、关闭、分享各自一颗，中间一列整理操作，最下面删除。
    /// 放摄像头那一侧（见 columnOnRight）。竖放时整列垂直居中，避开右上角竖排的状态栏
    /// （Duo 外屏竖放时那排时间和 Wi‑Fi 竖着排在右边，一直画到 150pt 左右）；横放时状态栏在顶部横排，
    /// 整列跟着贴顶，起点和编号胶囊、状态栏同一行。
    /// **横放时还要避开前置摄像头**（v0.3.166）：整页 `ignoresSafeArea` 铺满，系统不会替我们让开，
    /// 摄像头在左上角时关闭按钮正好压在挖孔上、点不到。摄像头在这一侧的上半部分时，
    /// 整列从它的下沿（+8）开始；在下半部分（右下角）时不冲突，照常贴顶。
    /// 普通 iPhone 横放屏幕高 380 以下时才用小一号（圆钮 38、胶囊里 42、间距 6）。
    private func sideButtons(_ w: Wallpaper) -> some View {
        let tight = tightColumn
        let landscape = screenSize.width > screenSize.height
        let button: CGFloat = tight ? 38 : 44
        let pill: CGFloat = tight ? 42 : 48
        let camNearTop = cameraFrame != .zero && cameraFrame.midY < screenSize.height / 2
        // 只有外屏 / 手机这种小屏才可能让摄像头压到这一列上（Duo 外屏横放时挖孔在角上，和列同一条竖线）。
        // 摄像头压在列上才让开，而且只在列位于左侧时检查：Duo 外屏横放「圆角朝下」那一向摄像头在左上角，
        // 跟这一列同一条竖线（v0.3.166 用户反馈关闭按钮点不到就是这一向）；另一向摄像头在右下角，不冲突。
        // Duo 内屏横放不走这条路：那块挖孔和右上角的状态栏是同一块，见下面的 tallScreen。
        let camOnColumn = !columnOnRight && cameraFrame != .zero && cameraFrame.minX < 60
        // 内屏横放：系统相册保留右上角那块状态栏（时间、电量、信号竖着排），按钮列紧贴着它下面开始——
        // 那块就是前置摄像头的遮挡区（模拟器上量到 951 宽的屏上到 y 124.5），系统相册第一颗按钮顶边
        // 也是 124。外屏、手机横放：状态栏不显示，贴顶 28，摄像头压在同一侧时往下让开。
        let tallScreen = screenSize.height >= 640
        let camOnColumnSide = cameraFrame != .zero
            && (columnOnRight ? cameraFrame.midX > screenSize.width / 2 : cameraFrame.midX < screenSize.width / 2)
        let topInset: CGFloat = landscape
            ? (tallScreen
                ? (camNearTop && camOnColumnSide ? cameraFrame.maxY : max(windowSafe.top + button, 28))
                : (camNearTop && camOnColumn ? max(cameraFrame.maxY + 8, 28) : max(windowSafe.top + 8, 28)))
            : 0
        // 竖放：上下两个 Spacer 夹住，整列垂直居中；横放：上面不留、下面用 Spacer 撑开，贴顶。
        // 不用 `.frame(maxHeight: .infinity, alignment: .top)`：overlay 里给的高度提案不一定是整屏，
        // 横向那一版对齐偶尔没生效、整列被顶到中间偏下（v0.3.168 内屏横放踩过）。
        return VStack(spacing: 0) {
            if !landscape { Spacer(minLength: 0) }
            VStack(spacing: tight ? 6 : 8) {
                if let undo = session.undoName { undoButton(undo, size: button) }
                circleButton("xmark", label: "关闭", size: button) { dismiss() }
                ShareOriginalButton(session: session, wall: w, glass: true, size: button)
                actionPill(w, vertical: true, size: pill)
                actionCircle(.delete, w, size: button)
                    .deleteOriginalDialog(session: session, wall: $confirmDelete)
            }
            .padding(.top, topInset)
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
        // 离屏幕边 24：和状态栏同一条竖线（对着系统相册量的：外屏竖放 457 宽时按钮中心 408.5、
        // 时间也在这条线上；内屏横放 951 宽时按钮中心 903）。列里最宽的是胶囊 48，所以 951−24−24=903。
        // 以前给 20 整列偏右、给 26/32 又偏左 2~6pt
        .padding(columnOnRight ? .trailing : .leading, 24)
    }

    /// 圆形的玻璃按钮（关闭、撤销、分享）。
    private func circleButton(_ icon: String, label: String, size: CGFloat = 44,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 20, weight: .semibold))
                .frame(width: size, height: size)
                .glassBackground(in: Circle(), interactive: true)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// 操作图标（不带玻璃）：存到相册正在下载时换成一个转圈。
    private func actionIcon(_ kind: WallActionKind, _ w: Wallpaper) -> some View {
        Group {
            if kind == .save, session.saving == w.name {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: kind.icon).font(.system(size: 20, weight: .semibold))
            }
        }
        .foregroundStyle(kind.isDestructive ? Color.red : Color.primary)
    }

    /// 单独一颗圆的整理操作（右上角那一排、竖屏右边的删除）。
    private func actionCircle(_ kind: WallActionKind, _ w: Wallpaper, size: CGFloat = 44) -> some View {
        let enabled = kind.isEnabled(session, w)
        return Button(role: kind.isDestructive ? .destructive : nil) {
            kind.perform(session, w, confirmDelete: $confirmDelete)
        } label: {
            actionIcon(kind, w)
                .frame(width: size, height: size)
                .glassBackground(in: Circle(), interactive: true)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityLabel(kind == .save && session.saving == w.name ? "正在下载" : kind.barTitle)
        .accessibilityHint(kind.hint)
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

            // 缩略图条撑满整行，当前那张对齐屏幕正中（内屏侧边的传感器区会让这条变窄，不能用它自己的正中）；
            // 宽屏横放时右边让开按钮那一列（直接缩窄这条，加 padding 挡不住滚动内容画到屏幕边上），
            // 条按自己的正中（照系统相册）
            FilmStrip(session: session, current: current, screenMidX: sideColumn ? nil : screenMidX,
                      inset: sideColumn ? 84 : 0, insetOnRight: columnOnRight) { go(to: $0) }
                .padding(.horizontal, -20)

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

            if !wide && !sideColumn { actionRow(w) } // 宽屏的按钮在顶栏，右边一列时在右列里
        }
        .padding(.horizontal, 20).padding(.top, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { bottomBarTop = $0 }
    }

    /// 窄屏底部这一排（照系统相册的 iPhone 版）：左边分享，中间一块玻璃里排三个整理操作，右边红色的删除。
    /// 不写文字，只说给 VoiceOver 听。
    private func actionRow(_ w: Wallpaper) -> some View {
        HStack(spacing: 0) {
            ShareOriginalButton(session: session, wall: w, glass: true, size: 44)
            Spacer(minLength: 12)
            actionPill(w)
            Spacer(minLength: 12)
            actionCircle(.delete, w)
                .deleteOriginalDialog(session: session, wall: $confirmDelete)
        }
        .frame(height: 52)
    }

    /// 存到相册、移出、不再选它三颗共用一层玻璃（相册里也是几个图标装在一个胶囊里）。
    /// `vertical`：宽屏横放时右边那一列是竖着的。
    private func actionPill(_ w: Wallpaper, vertical: Bool = false, size: CGFloat = 50) -> some View {
        let kinds = Self.pillKinds.filter { !$0.needsSource || w.hasSource }
        return Group {
            if vertical {
                VStack(spacing: 0) { contents(kinds, w, size: size) }.padding(.vertical, 3)
            } else {
                HStack(spacing: 0) { contents(kinds, w, size: size) }.padding(.horizontal, 3)
            }
        }
        .glassBackground(in: Capsule(), interactive: true)
    }

    private func contents(_ kinds: [WallActionKind], _ w: Wallpaper, size: CGFloat) -> some View {
        ForEach(kinds, id: \.self) { kind in pillButton(kind, w, size: size) }
    }

    private static let pillKinds: [WallActionKind] = [.save, .remove, .exclude]

    private func pillButton(_ kind: WallActionKind, _ w: Wallpaper, size: CGFloat) -> some View {
        let enabled = kind.isEnabled(session, w)
        return Button {
            kind.perform(session, w, confirmDelete: $confirmDelete)
        } label: {
            actionIcon(kind, w)
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityLabel(kind == .save && session.saving == w.name ? "正在下载" : kind.barTitle)
        .accessibilityHint(kind.hint)
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
    /// 让开的宽度和方向（右边一列按钮时给那一列腾地方；列在哪侧由摄像头位置决定，见 columnOnRight）
    let inset: CGFloat
    let insetOnRight: Bool
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
            let w = max(f.width - inset, 0)
            let start = f.minX + (insetOnRight ? 0 : inset)
            let mid = min(max(((screenMidX ?? f.midX) - start), Self.thumb.width / 2), max(w - Self.thumb.width / 2, Self.thumb.width / 2))
            strip(width: w, mid: mid)
                .frame(width: w)
                .clipped() // 水平 ScrollView 不自己裁掉越界的滚动内容，得手动裁到条的宽度
                .frame(maxWidth: .infinity, alignment: insetOnRight ? .leading : .trailing)
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
