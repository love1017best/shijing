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
        case .delete: "从图库删除这张原图，不可撤销。无法连接电脑时会先记录，连接后再确认一次才会删除。"
        }
    }

    var isDestructive: Bool { self == .delete }

    /// 动的是图库里的原图：旧版本换上的没有原图路径，这两种就不显示
    var needsSource: Bool { self == .exclude || self == .delete }

    /// 这张壁纸是否支持此操作：仅采样目录的图片不可删除原图，只能移出或不再选。
    func isAvailable(for wall: Wallpaper) -> Bool {
        switch self {
        case .save, .remove: true
        case .exclude: wall.hasSource
        case .delete: wall.canDeleteOriginal
        }
    }
}

extension WallActionKind {
    /// 现在能不能点。换壁纸的过程中不能整理；存原图离线时只有手机上存过那张的原图才能点。
    /// 删除原图离线时也能点：只登记「想删」，连上电脑后还要再确认一次才真的删。
    /// 离线时「正在换壁纸」不拦整理（那份状态是断线前同步的，见下面）。
    @MainActor
    func isEnabled(_ session: RemoteSession, _ w: Wallpaper) -> Bool {
        if !isAvailable(for: w) { return false }
        if self == .save {
            if session.saving != nil { return false }
            return !session.offline || ImageStore.cachedOriginal(macID: session.macID.uuidString, name: w.name) != nil
        }
        // 离线时整理只是把操作记下来（连上后补），不用管电脑上是不是正在换壁纸：
        // 那份状态是断开前同步的，可能早就结束了，按它禁用会让人一直点不了
        if session.offline { return session.acting == nil }
        return session.acting == nil && session.state?.running != true
    }

    @MainActor
    func perform(_ session: RemoteSession, _ w: Wallpaper, confirmDelete: Binding<Wallpaper?>) {
        switch self {
        case .save: Task { await session.saveOriginal(w) }
        case .remove: Task { await session.removeWallpaper(w, exclude: false) }
        case .exclude:
            guard w.hasSource else { return }
            Task { await session.removeWallpaper(w, exclude: true) }
        case .delete:
            guard w.canDeleteOriginal else { return }
            confirmDelete.wrappedValue = w
        }
    }
}

/// 长按菜单和预览底栏共用的四个操作按钮。
struct WallActionButtons: View {
    let session: RemoteSession
    let wall: Wallpaper
    @Binding var confirmDelete: Wallpaper?

    var body: some View {
        ForEach(WallActionKind.allCases, id: \.self) { kind in
            if kind.isAvailable(for: wall) {
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
                Text("会从图库中删除 \(w.source ?? w.name)，并移出壁纸文件夹。删除不可撤销。现在无法连接电脑，会先记录，连接后在「设置 › 待处理操作」中再确认一次才会删除。")
            } else {
                Text("会从图库中删除 \(w.source ?? w.name)，并移出壁纸文件夹。删除不可撤销，会记进电脑上的删除记录。")
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
            .disabled(session.acting != nil || (!session.offline && session.state?.running == true))
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
    /// 这颗按钮在屏幕上的位置，弹分享面板时当锚点用（见 SharePresenter）
    @State private var anchor: CGRect = .zero

    /// 手机上存过这张的原图（离线时唯一能用的那份）
    private var cached: URL? {
        ImageStore.cachedOriginal(macID: session.macID.uuidString, name: wall.name)
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
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { anchor = $0 }
    }

    private var button: some View {
        Button {
            Task { await load() }
        } label: {
            if glass {
                icon.glassCircle(size: size)
            } else {
                icon.frame(width: 36, height: 36)
            }
        }
    }

    private var icon: some View {
        ZStack {
            Image(systemName: "square.and.arrow.up").opacity(loading ? 0 : 1)
            if loading { ProgressView() }
        }
        .font(.system(size: 20, weight: .semibold))
    }

    @MainActor
    private func load() async {
        loading = true
        defer { loading = false }
        do {
            if let cached {
                present(cached, deleteAfter: false) // 优先复用手机上缓存的原图，不能删
            } else {
                let url = try await session.request { try await $0.downloadOriginal(wall.name) }
                present(url, deleteAfter: true)
            }
        } catch {
            // 令牌失效转未配对；连不上电脑顺手转离线，别让界面停在「已连接」上
            session.handleRequestError(error)
        }
    }

    @MainActor
    private func present(_ url: URL, deleteAfter: Bool) {
        SharePresenter.present([url], anchor: anchor) {
            if deleteAfter { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        }
    }
}

/// 直接在最上层视图上弹出系统分享面板。用 SwiftUI 的 .sheet 包一层的话，面板得等 sheet 自己推上来才出现、
/// 收起时又跟着 sheet 一起走，两段动画叠着看很生涩。
@MainActor
enum SharePresenter {
    /// `anchor`：分享按钮在屏幕上的位置（全局坐标，和窗口原点一致）。iOS 18 及更早的 iPad、
    /// Duo 这类 regular 宽度上分享面板是 popover，指到按钮那一块才会贴着按钮弹出来。
    /// iOS 26 起系统把分享面板换成了自己居中的一块玻璃卡片，锚点会被它重置、指不过去（试过
    /// sourceView/sourceRect/sourceItem、单独包一层普通视图控制器，都是弹在屏幕中间），只能这样。
    static func present(_ items: [Any], anchor: CGRect? = nil, onFinish: (() -> Void)? = nil) {
        #if os(iOS)
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              let top = topmost(scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
                                ?? scene.windows.first?.rootViewController) else {
            onFinish?()
            return
        }
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        vc.completionWithItemsHandler = { _, _, _, _ in
            DispatchQueue.main.async { onFinish?() }
        }
        if let pop = vc.popoverPresentationController {
            pop.sourceView = top.view
            if let anchor, anchor != .zero, let window = top.view.window {
                // SwiftUI 量到的是窗口坐标，换成最上层这个视图自己的坐标
                pop.sourceRect = top.view.convert(anchor, from: window)
                pop.permittedArrowDirections = .any // 让系统按按钮在屏幕上下的位置挑箭头方向
            } else {
                pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
                pop.permittedArrowDirections = []
            }
        }
        top.present(vc, animated: true)
        #else
        _ = (items, anchor)
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
