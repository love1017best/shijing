import SwiftUI
#if os(iOS)
import UIKit
#endif

/// 全屏幻灯片模式：从概览横幅点击进入，纯黑背景配交叉淡入淡出切图，
/// 左下角常驻液态玻璃时钟与文件名卡片（点击跳转到常规大图预览进行整理），
/// 底部自动隐藏的液态玻璃控制条提供播放控制、间隔、随机、填充方式与防息屏开关。
struct SlideshowView: View {
    let session: RemoteSession
    let startName: String
    /// 点击时钟/文件名卡片或「整理」按钮时调用：关闭幻灯片并打开当前图的常规大图预览。
    let onOpenPreview: (Wallpaper) -> Void

    private static let intervals = [5, 10, 20, 30, 60]
    private static let hudHideDelay: TimeInterval = 3.5

    @AppStorage("slideshowIntervalSec") private var intervalSec = 10
    @AppStorage("slideshowShuffle") private var shuffle = false
    /// 0 = 自动（横屏铺满、竖屏完整显示），1 = 始终铺满，2 = 始终完整显示
    @AppStorage("slideshowFitMode") private var fitMode = 0
    @AppStorage("slideshowShowInfo") private var showInfo = true
    @AppStorage("slideshowKeepAwake") private var keepAwake = true

    @State private var current: String
    @State private var shownImage: PlatformImage?
    @State private var order: [String] = []
    @State private var playing = true
    @State private var showHUD = true
    @State private var hudToken = 0
    @State private var playToken = 0
    /// 安全区内的可用尺寸（用于排版信息卡和控制条）
    @State private var size = CGSize.zero
    /// 忽略安全区后的物理全屏尺寸（用于判断横竖屏和图片全屏铺满）
    @State private var canvasSize = CGSize.zero
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    init(session: RemoteSession, startName: String, onOpenPreview: @escaping (Wallpaper) -> Void) {
        self.session = session
        self.startName = startName
        self.onOpenPreview = onOpenPreview
        _current = State(initialValue: startName)
    }

    private var walls: [Wallpaper] { session.walls }
    private var activeList: [String] {
        let all = walls.map(\.name)
        if !shuffle { return all }
        return order.isEmpty ? all : order
    }
    private var currentIndex: Int {
        activeList.firstIndex(of: current) ?? 0
    }
    private var currentWall: Wallpaper? {
        walls.first { $0.name == current } ?? walls.first
    }
    private var isLandscape: Bool {
        let s = canvasSize == .zero ? size : canvasSize
        return s.width > s.height
    }
    private var shouldFill: Bool {
        switch fitMode {
        case 1: return true
        case 2: return false
        default: return isLandscape
        }
    }
    private var isWide: Bool { size.width >= 680 }

    var body: some View {
        ZStack {
            // 1. 物理全屏纯黑底 + 交叉淡入淡出图片画布（独立忽略安全区，避免 Duo 外屏右侧状态栏把图片挤偏）
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
            }
            .ignoresSafeArea()

            // 2. 右上角状态与页码胶囊（留在安全区内，随 HUD 显示/隐藏）
            if showHUD {
                VStack {
                    HStack {
                        Spacer()
                        HStack(spacing: 6) {
                            Image(systemName: playing ? "play.fill" : "pause.fill")
                                .font(.caption2)
                            Text("\(playing ? "播放中" : "已暂停") · \(currentIndex + 1) / \(max(activeList.count, 1))")
                                .font(.caption.monospacedDigit())
                                .lineLimit(1)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(.white.opacity(0.92))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .glassBackground(in: Capsule(), tint: .black.opacity(0.28))
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    Spacer()
                }
                .transition(.opacity)
            }

            // 3. 底部液态玻璃信息卡（时钟 + 文件名）与自动隐藏控制胶囊
            VStack(spacing: 12) {
                Spacer()
                if size.width >= 840 {
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
                                if size.width >= 520 {
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
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .statusBarHiddenCompat(!showHUD)
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
            let sec = Self.intervals.contains(intervalSec) ? intervalSec : 10
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

    // MARK: - 液态玻璃时钟与文件名卡片

    private var infoCard: some View {
        Button {
            openCurrentForOrganize()
        } label: {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(ctx.date, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                            .font(.system(size: isWide ? 36 : 30, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.35), radius: 6, y: 1)
                            .lineLimit(1)
                        Text(Self.dateText(ctx.date))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white.opacity(0.84))
                            .lineLimit(1)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    HStack(spacing: 5) {
                        Text(Self.displayTitle(currentWall?.name ?? current))
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.92))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                    .frame(maxWidth: isWide ? 280 : 260, alignment: .leading)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .glassBackground(in: RoundedRectangle(cornerRadius: 20, style: .continuous),
                             tint: .black.opacity(0.28), interactive: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("查看并整理当前壁纸：\(currentWall?.name ?? current)")
    }

    // MARK: - 液态玻璃控制条

    private var wideControlBar: some View {
        HStack(spacing: 4) {
            playbackButtons
            barDivider
            optionButtons
            barDivider
            organizeButton
            closeButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassBackground(in: Capsule(), tint: .black.opacity(0.32))
        .fixedSize(horizontal: true, vertical: false)
    }

    private var compactControlBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                optionButtons
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassBackground(in: Capsule(), tint: .black.opacity(0.3))
            .fixedSize(horizontal: true, vertical: false)

            HStack(spacing: 6) {
                playbackButtons
                barDivider
                organizeButton
                closeButton
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .glassBackground(in: Capsule(), tint: .black.opacity(0.34))
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    @ViewBuilder
    private var playbackButtons: some View {
        barIconButton("backward.fill", label: "上一张") {
            Task { await step(-1) }
            pokeHUD()
        }
        barIconButton(playing ? "pause.fill" : "play.fill", label: playing ? "暂停" : "播放", active: playing) {
            playing.toggle()
            pokeHUD()
        }
        barIconButton("forward.fill", label: "下一张") {
            Task { await step(1) }
            pokeHUD()
        }
    }

    @ViewBuilder
    private var optionButtons: some View {
        Button {
            cycleInterval()
            pokeHUD()
        } label: {
            Text(Self.intervalLabel(intervalSec))
                .font(.caption.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(.white.opacity(0.94))
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(.white.opacity(0.14), in: Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel("切图间隔：\(Self.intervalLabel(intervalSec))")

        barIconButton("shuffle", label: "随机播放", active: shuffle) {
            shuffle.toggle()
            rebuildOrderIfNeeded(keeping: current)
            pokeHUD()
        }
        barIconButton(shouldFill ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                      label: shouldFill ? "改为完整显示" : "改为铺满屏幕", active: shouldFill) {
            toggleFit()
            pokeHUD()
        }
        barIconButton("clock", label: showInfo ? "隐藏时钟与文件名" : "显示时钟与文件名", active: showInfo) {
            withAnimation(.easeInOut(duration: 0.2)) { showInfo.toggle() }
            pokeHUD()
        }
        barIconButton(keepAwake ? "sun.max.fill" : "sun.max",
                      label: keepAwake ? "关闭防息屏" : "开启防息屏", active: keepAwake) {
            keepAwake.toggle()
            pokeHUD()
        }
    }

    private var organizeButton: some View {
        Button {
            openCurrentForOrganize()
        } label: {
            Text("整理")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(.white)
                .padding(.horizontal, 11)
                .frame(height: 34)
                .background(.white.opacity(0.16), in: Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel("跳转到当前图片的大图预览进行整理")
    }

    private var closeButton: some View {
        barIconButton("xmark", label: "退出幻灯片") {
            dismiss()
        }
    }

    private func barIconButton(_ systemName: String, label: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(active ? 1 : 0.85))
                .frame(width: 34, height: 34)
                .background(active ? .white.opacity(0.22) : .clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var barDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.2))
            .frame(width: 1, height: 18)
            .padding(.horizontal, 2)
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

    private func openCurrentForOrganize() {
        setIdleTimerDisabled(false)
        if let w = currentWall {
            onOpenPreview(w)
        } else {
            dismiss()
        }
    }

    private func pokeHUD() {
        if !showHUD {
            withAnimation(.easeInOut(duration: 0.25)) { showHUD = true }
        }
        hudToken += 1
    }

    private func toggleFit() {
        fitMode = shouldFill ? 2 : 1
    }

    private func cycleInterval() {
        if let idx = Self.intervals.firstIndex(of: intervalSec) {
            intervalSec = Self.intervals[(idx + 1) % Self.intervals.count]
        } else {
            intervalSec = Self.intervals[0]
        }
    }

    private func rebuildOrderIfNeeded(keeping name: String) {
        let all = walls.map(\.name)
        guard shuffle else {
            order = []
            return
        }
        var next = all.shuffled()
        if let i = next.firstIndex(of: name), i > 0 {
            next.swapAt(0, i)
        }
        order = next
    }

    /// 向前或向后切图：离线遇到未缓存图片时自动跳过，载入完成后再平滑淡入淡出。
    private func step(_ delta: Int) async {
        let list = activeList
        guard list.count > 1 else { return }
        let start = list.firstIndex(of: current) ?? 0
        let maxTries = min(12, list.count - 1)
        for offset in 1...maxTries {
            let idx = (start + delta * offset + list.count * maxTries) % list.count
            let candidate = list[idx]
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
        let list = activeList
        guard list.count > 1, let idx = list.firstIndex(of: name) else { return }
        let next = list[(idx + 1) % list.count]
        _ = await ImageStore.shared.load(session, next, .image)
    }

    // MARK: - 防息屏与格式辅助

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

    private static func intervalLabel(_ sec: Int) -> String {
        if sec >= 60 && sec % 60 == 0 { return "\(sec / 60)分" }
        return "\(sec)秒"
    }

    private static func displayTitle(_ name: String) -> String {
        let stem = (name as NSString).deletingPathExtension
        return stem.isEmpty ? name : stem
    }

    private static func dateText(_ date: Date) -> String {
        let cal = Calendar.current
        let m = cal.component(.month, from: date)
        let d = cal.component(.day, from: date)
        let wd = cal.component(.weekday, from: date)
        let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        let w = (1...7).contains(wd) ? names[wd - 1] : ""
        return "\(m)月\(d)日 \(w)"
    }
}
