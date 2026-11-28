import SwiftUI
#if os(iOS)
import UIKit
#endif

/// 全屏幻灯片模式：从概览横幅点击进入，纯黑背景配交叉淡入淡出切图，
/// 左下角常驻液态玻璃时钟与文件名卡片（点击跳转到常规大图预览进行整理），
/// 底部自动隐藏的液态玻璃控制条提供播放控制、间隔、随机、填充方式与防息屏开关。
/// HUD 浮层组件拆在 `SlideshowChrome.swift`，纯切图/顺序/格式化规则在 `Shared/CoreLogic.swift` 的 `SlideshowLogic`。
struct SlideshowView: View {
    let session: RemoteSession
    let startName: String
    /// 点击时钟/文件名卡片或「整理」按钮时调用：关闭幻灯片并打开当前图的常规大图预览。
    let onOpenPreview: (Wallpaper) -> Void

    private static let hudHideDelay: TimeInterval = 3.5

    @AppStorage("slideshowIntervalSec") var intervalSec = SlideshowLogic.defaultInterval
    @AppStorage("slideshowShuffle") var shuffle = false
    /// 0 = 自动（横屏铺满、竖屏完整显示），1 = 始终铺满，2 = 始终完整显示
    @AppStorage("slideshowFitMode") var fitMode = 0
    @AppStorage("slideshowShowInfo") var showInfo = true
    @AppStorage("slideshowKeepAwake") var keepAwake = true

    @State var current: String
    @State private var shownImage: PlatformImage?
    @State private var order: [String] = []
    @State var playing = true
    @State private var showHUD = true
    @State private var hudToken = 0
    @State private var playToken = 0
    /// 物理全屏画布尺寸（用于铺满图片与在窗口尺寸尚未回传前兜底）
    @State private var canvasSize = CGSize.zero
    /// 窗口安全区与窗口尺寸：整页 ignoresSafeArea 后，安全区靠 WindowMetrics 从窗口精确读取，
    /// 避免 Duo 外屏 fullScreenCover 受首页浮动标签栏影响把内容区挤偏，也避免转屏读到旧安全区。
    @State var windowSafe = UIEdgeInsets.zero
    @State private var windowSize = CGSize.zero
    /// 系统报告的四向遮挡区（iOS 27.1+）：覆盖 Duo 外屏竖屏/内屏横屏竖排状态栏、
    /// 内屏竖屏灵动岛实时活动、以及横屏落在角上的前置摄像头挖孔。
    struct OcclusionInsets: Equatable {
        var topRightWidth: CGFloat = 0
        var topRightBottom: CGFloat = 0
        var topLeftWidth: CGFloat = 0
        var topCenterBottom: CGFloat = 0
        var bottomLeftWidth: CGFloat = 0
        var bottomRightWidth: CGFloat = 0
    }
    @State var occlusion = OcclusionInsets()
    @Environment(\.dismiss) var dismiss
    @Environment(\.scenePhase) private var scenePhase

    init(session: RemoteSession, startName: String, onOpenPreview: @escaping (Wallpaper) -> Void) {
        self.session = session
        self.startName = startName
        self.onOpenPreview = onOpenPreview
        _current = State(initialValue: startName)
    }

    var walls: [Wallpaper] { session.walls }
    var activeList: [String] {
        SlideshowLogic.activeList(all: walls.map(\.name), shuffle: shuffle, order: order)
    }
    var currentIndex: Int {
        activeList.firstIndex(of: current) ?? 0
    }
    var currentWall: Wallpaper? {
        walls.first { $0.name == current } ?? walls.first
    }
    private var layoutSize: CGSize {
        windowSize != .zero ? windowSize : canvasSize
    }
    private var isLandscape: Bool {
        layoutSize.width > layoutSize.height
    }
    var shouldFill: Bool {
        SlideshowLogic.shouldFill(fitMode: fitMode, isLandscape: isLandscape)
    }
    private var bottomLeading: CGFloat {
        max(20, windowSafe.left + 20, occlusion.bottomLeftWidth + 12)
    }
    private var bottomTrailing: CGFloat {
        max(20, windowSafe.right + 20, occlusion.bottomRightWidth + 12)
    }
    private var bottomPadding: CGFloat {
        max(16, windowSafe.bottom + 12)
    }
    /// 底部内容区实际可用宽度（已扣掉左右安全区、角落摄像头遮挡和外边距）
    private var bottomAvailableWidth: CGFloat {
        max(0, layoutSize.width - bottomLeading - bottomTrailing)
    }
    var isWide: Bool { bottomAvailableWidth >= 640 }
    /// 小屏横放（Duo 外屏横屏、普通 iPhone 横屏）时系统本身不显示状态栏，保持隐藏避免闪动或压到顶部胶囊。
    /// Duo 内屏横屏（高 669 ≥ 640）除外，显示控制条时保留右上角竖排状态栏。
    private var hideStatusBarInLandscape: Bool {
        isLandscape && layoutSize.height > 0 && layoutSize.height < 640
    }

    /// 右上角状态胶囊的上、右外边距：避开窗口顶/右安全区，并在与 Duo 竖排状态栏或灵动岛实时活动
    /// 纵向重叠时优先向左让开；若右侧遮挡过宽放不下胶囊，则落到其下方。
    var topPillInsets: (top: CGFloat, trailing: CGFloat) {
        let baseTop = max(windowSafe.top + 8, occlusion.topCenterBottom + 8, 20)
        let baseTrailing = max(20, windowSafe.right + 20)
        if occlusion.topRightWidth > 0, baseTop < occlusion.topRightBottom + 4 {
            let besideTrailing = max(baseTrailing, occlusion.topRightWidth + 12)
            let leftClear = max(20, windowSafe.left + 20, occlusion.topLeftWidth + 12)
            if layoutSize.width - leftClear - besideTrailing >= 180 {
                return (baseTop, besideTrailing)
            }
            return (max(baseTop, occlusion.topRightBottom + 8), baseTrailing)
        }
        return (baseTop, baseTrailing)
    }

    var body: some View {
        ZStack {
            // 1. 物理全屏纯黑底 + 交叉淡入淡出图片画布 + 遮挡区探测
            GeometryReader { geo in
                ZStack {
                    Color.black
                    if let img = shownImage {
                        platformImageView(img)
                            .resizable()
                            .aspectRatio(contentMode: shouldFill ? .fill : .fit)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                            .id(current)
                            .transition(.opacity)
                    } else {
                        ProgressView().tint(.white)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .contentShape(Rectangle())
                // 双击和单击互斥：避免双击切换填充方式时第一下触发单击造成控制条闪烁
                .gesture(
                    ExclusiveGesture(
                        TapGesture(count: 2).onEnded {
                            toggleFit()
                            pokeHUD()
                        },
                        TapGesture().onEnded {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                showHUD.toggle()
                            }
                            if showHUD { hudToken += 1 }
                        }
                    )
                )
                .simultaneousGesture(swipeGesture)
                .onGeometryChange(for: CGSize.self) { $0.size } action: {
                    if $0 != canvasSize { canvasSize = $0 }
                }
                .onGeometryChange(for: OcclusionInsets.self) { proxy in
                    guard #available(iOS 27.1, *) else { return OcclusionInsets() }
                    let w = proxy.size.width, h = proxy.size.height
                    guard w > 0, h > 0 else { return OcclusionInsets() }
                    var out = OcclusionInsets()
                    for rect in proxy.reservedRegions(kind: .occlusion).map(\.frame) {
                        guard !rect.isEmpty, rect.width < w * 0.85, rect.height < h * 0.85 else { continue }
                        let rightBiased = rect.maxX > w * 0.75 && rect.minX > (w - rect.maxX) + 20
                        let leftBiased = rect.minX < w * 0.25 && (w - rect.maxX) > rect.minX + 20
                        // 顶部遮挡：区分靠右（Duo 竖排状态栏/灵动岛/右上角摄像头）、靠左和居中（普通 iPhone 灵动岛）
                        if rect.minY < 120 {
                            if rightBiased {
                                out.topRightWidth = max(out.topRightWidth, max(0, w - rect.minX))
                                out.topRightBottom = max(out.topRightBottom, rect.maxY)
                            } else if leftBiased {
                                out.topLeftWidth = max(out.topLeftWidth, max(0, rect.maxX))
                            } else {
                                out.topCenterBottom = max(out.topCenterBottom, rect.maxY)
                            }
                        }
                        // 底部角落遮挡：如 Duo 外屏横屏落在左下角或右下角的前置摄像头
                        if rect.maxY > h - 160 {
                            if leftBiased {
                                out.bottomLeftWidth = max(out.bottomLeftWidth, max(0, rect.maxX))
                            } else if rightBiased {
                                out.bottomRightWidth = max(out.bottomRightWidth, max(0, w - rect.minX))
                            }
                        }
                    }
                    return out
                } action: { o in
                    if o != occlusion { occlusion = o }
                }
            }

            // 2. 右上角状态与页码胶囊（按窗口安全区与遮挡区动态避让，随 HUD 显示/隐藏）
            if showHUD {
                statusPill
                    .transition(.opacity)
            }

            // 3. 底部液态玻璃信息卡（时钟 + 文件名）与自动隐藏控制胶囊
            VStack(spacing: 12) {
                Spacer()
                if bottomAvailableWidth >= 800 {
                    // 足够宽（Duo 内屏横屏、iPad）：信息卡靠左、控制条同排不重叠
                    // 分层 layoutPriority 避免 HStack 与 Spacer 平分提议宽度把按钮或文件名压扁
                    HStack(alignment: .bottom, spacing: 12) {
                        if showInfo {
                            infoCard
                                .layoutPriority(1)
                        } else {
                            Spacer(minLength: 0)
                        }
                        if showInfo {
                            Spacer(minLength: 0)
                        }
                        if showHUD {
                            wideControlBar
                                .layoutPriority(2)
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                        if !showInfo {
                            Spacer(minLength: 0)
                        }
                    }
                } else {
                    // 中等与窄屏（Duo 内屏竖屏、外屏横竖屏、普通 iPhone）：上下分层排布，绝不遮挡
                    VStack(alignment: .leading, spacing: 12) {
                        if showInfo {
                            infoCard
                        }
                        if showHUD {
                            Group {
                                if bottomAvailableWidth >= 480 {
                                    wideControlBar
                                } else {
                                    compactControlBar
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                    }
                }
            }
            .padding(.leading, bottomLeading)
            .padding(.trailing, bottomTrailing)
            .padding(.bottom, bottomPadding)
        }
        .ignoresSafeArea()
        .background(WindowMetrics { insets, size in
            if insets != windowSafe { windowSafe = insets }
            if size != windowSize { windowSize = size }
        }.allowsHitTesting(false))
        .preferredColorScheme(.dark)
        .statusBarHiddenCompat(!showHUD || hideStatusBarInLandscape)
        #if os(iOS)
        .persistentSystemOverlays(showHUD ? .automatic : .hidden)
        #endif
        .onAppear {
            rebuildOrderIfNeeded(keeping: current)
            syncIdleTimer()
            hudToken += 1
        }
        .onDisappear {
            setIdleTimerDisabled(false)
        }
        .onChange(of: playing) { syncIdleTimer() }
        .onChange(of: keepAwake) { syncIdleTimer() }
        .onChange(of: scenePhase) {
            syncIdleTimer()
            if scenePhase != .active {
                playing = false
            }
        }
        .onChange(of: session.state?.running) {
            if session.state?.running == true { dismiss() }
        }
        .onChange(of: session.walls.map(\.name)) {
            if session.walls.isEmpty {
                dismiss()
                return
            }
            rebuildOrderIfNeeded(keeping: current)
        }
        // 首张图片载入
        .task {
            await loadAndShow(name: current, animated: false)
            await prefetchNext(from: current)
        }
        // 自动播放循环：间隔 / 播放状态 / 手动切图变化时重置倒计时
        .task(id: "\(playing)|\(intervalSec)|\(shuffle)|\(playToken)|\(scenePhase == .active)") {
            guard playing, scenePhase == .active else { return }
            let sec = SlideshowLogic.normalizedInterval(intervalSec)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(sec))
                if Task.isCancelled || !playing || scenePhase != .active { return }
                await step(1)
            }
        }
        // 控制条自动隐藏倒计时（暂停时保持可见）
        .task(id: "\(showHUD)|\(playing)|\(hudToken)") {
            guard showHUD, playing else { return }
            try? await Task.sleep(for: .seconds(Self.hudHideDelay))
            if Task.isCancelled || !playing { return }
            withAnimation(.easeInOut(duration: 0.3)) {
                showHUD = false
            }
        }
    }

    // MARK: - 手势与切图逻辑

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { v in
                let dx = v.translation.width
                let dy = v.translation.height
                if abs(dx) > abs(dy) && abs(dx) > 45 {
                    Task { await step(dx < 0 ? 1 : -1) }
                    pokeHUD()
                } else if dy > 110 && abs(dy) > abs(dx) * 1.4 {
                    dismiss()
                }
            }
    }

    func openCurrentForOrganize() {
        setIdleTimerDisabled(false)
        if let w = currentWall {
            onOpenPreview(w)
        } else {
            dismiss()
        }
    }

    func pokeHUD() {
        if !showHUD {
            withAnimation(.easeInOut(duration: 0.25)) { showHUD = true }
        }
        hudToken += 1
    }

    func toggleFit() {
        fitMode = SlideshowLogic.toggledFitMode(currentlyFilled: shouldFill)
    }

    func cycleInterval() {
        intervalSec = SlideshowLogic.nextInterval(after: intervalSec)
    }

    func rebuildOrderIfNeeded(keeping name: String) {
        order = SlideshowLogic.buildOrder(all: walls.map(\.name), shuffle: shuffle, keeping: name)
    }

    /// 向前或向后切图：离线遇到未缓存图片时自动跳过，载入完成后再平滑淡入淡出。
    func step(_ delta: Int) async {
        for candidate in SlideshowLogic.stepCandidates(in: activeList, current: current, delta: delta) {
            if await loadAndShow(name: candidate, animated: true) {
                playToken += 1
                await prefetchNext(from: candidate)
                return
            }
        }
    }

    @discardableResult
    private func loadAndShow(name: String, animated: Bool) async -> Bool {
        var img = await ImageStore.shared.load(session, name, .image)
        if img == nil {
            img = await ImageStore.shared.load(session, name, .hero)
        }
        guard let img else { return false }
        if Task.isCancelled { return false }
        if animated {
            withAnimation(.easeInOut(duration: 0.7)) {
                current = name
                shownImage = img
            }
        } else {
            current = name
            shownImage = img
        }
        return true
    }

    private func prefetchNext(from name: String) async {
        guard let next = SlideshowLogic.nextName(in: activeList, after: name) else { return }
        _ = await ImageStore.shared.load(session, next, .image)
    }

    // MARK: - 防息屏与图片桥接

    private func syncIdleTimer() {
        #if os(iOS)
        let active = playing && keepAwake && scenePhase == .active && !ProcessInfo.processInfo.isLowPowerModeEnabled
        setIdleTimerDisabled(active)
        #endif
    }

    private func setIdleTimerDisabled(_ disabled: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = disabled
        #endif
    }

    private func platformImageView(_ img: PlatformImage) -> Image {
        #if os(iOS)
        Image(uiImage: img)
        #else
        Image(nsImage: img)
        #endif
    }
}
