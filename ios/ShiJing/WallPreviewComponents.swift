import SwiftUI
import UIKit

/// 预览里的一页：位置（-1 左 / 0 当前 / 1 右）和那张壁纸。身份是文件名，翻页时图不会被重建。
struct PageSlot: Identifiable {
    let d: Int
    let w: Wallpaper
    var id: String { w.name }
}

/// 预览里的一页：按屏幕形状决定铺满还是完整显示，再叠上缩放和平移。
struct PreviewPage: View {
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
                    Text(session.offline ? "这张图片尚未缓存" : "无法读取这张图片").font(.headline)
                    if session.offline {
                        Text("连接电脑后整批图片会自动保存到手机上").font(.footnote).foregroundStyle(.secondary)
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
                Text("离线 · 大图尚未缓存，当前显示缩略图")
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
struct FilmStrip: View {
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
    /// 延时解除 following 的任务：连续翻页时取消上一次，避免过早复位引发回跳
    @State private var followTask: Task<Void, Never>?

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
            followTask?.cancel()
            followTask = Task {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                following = false
            }
        }
        .onDisappear {
            followTask?.cancel()
            followTask = nil
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

/// 报告窗口的安全区和大小。大图预览整页 `ignoresSafeArea` 铺满屏幕，页面里的安全区是 0，
/// 顶栏底栏的留白得按窗口的安全区自己算；版式的宽窄、横竖也按窗口大小判断
/// （页面上当场量到的尺寸在弹提示框、弹键盘时会变一下，见 layoutSize）。
/// 窗口布局（首次出现、转屏）时读一次、再 `async` 回主线程报出去——在布局过程中直接改 SwiftUI 的状态会报「during view update」。
struct WindowMetrics: UIViewRepresentable {
    let onChange: (UIEdgeInsets, CGSize) -> Void

    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ probe: Probe, context: Context) { probe.onChange = onChange }

    final class Probe: UIView {
        var onChange: ((UIEdgeInsets, CGSize) -> Void)?

        override func didMoveToWindow() { super.didMoveToWindow(); report() }
        override func layoutSubviews() { super.layoutSubviews(); report() }
        override func safeAreaInsetsDidChange() { super.safeAreaInsetsDidChange(); report() }

        /// 在下一轮主线程循环里再读窗口：布局进行中读到的可能还是转屏前的大小和安全区。
        /// 转屏动画结束后再读一次，外屏从横放转回竖放时，只读一次偶尔停在横放的尺寸上，
        /// 整列按横放贴顶、压到状态栏和摄像头上（v0.4.18 用户反馈）。
        private func report() {
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in self?.send() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.send() }
        }

        private func send() {
            guard let window else { return }
            onChange?(window.safeAreaInsets, window.bounds.size)
        }
    }
}
