import SwiftUI
import UserNotifications

@main
struct ShiJingApp: App {
    init() {
        RunNotifier.isForeground = { UIApplication.shared.applicationState == .active }
        Notifications.setUp()
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-demoWidgets") {
                WidgetDemo()
            } else {
                RootView()
            }
            #else
            RootView()
            #endif
        }
    }
}

/// 顶层：没配对过任何 Mac 时整屏是「找 Mac / 配对」；配对过之后是三个标签——概览、设置、记录，
/// 对应电脑上侧边栏的概览 / 设置 / 删除记录（iPad、展开的内屏上系统把标签栏放在顶部，不占侧边）。
/// 切换、添加、移除 Mac 收在概览的标题菜单里（点顶部的 Mac 名字）——这些只在第一次装的时候用，不值得常驻一个侧栏。
enum RootTab: Hashable { case overview, settings, records }

struct RootView: View {
    @State private var store = MacStore()
    @State private var discovery = Discovery()
    @State private var session: RemoteSession?
    @State private var pendingWall: String?
    @State private var tab = RootTab.overview
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let session {
                TabView(selection: $tab) {
                    NavigationStack {
                        DashboardView(session: session, store: store)
                            .macTitleMenu(store: store, discovery: discovery)
                    }
                    .tabItem { Label("概览", systemImage: "photo.on.rectangle") }
                    .tag(RootTab.overview)
                    NavigationStack { SettingsPage(session: session) }
                        .tabItem { Label("设置", systemImage: "gearshape") }
                        .tag(RootTab.settings)
                    NavigationStack { RecordsPage(session: session) }
                        .tabItem { Label("记录", systemImage: "clock.arrow.circlepath") }
                        .tag(RootTab.records)
                }
                .id(session.macID)
            } else {
                SetupView(store: store, discovery: discovery)
            }
        }
        .onAppear {
            syncSession()
            #if DEBUG
            // 截图用：-demoSettings / -demoRecords 直接打开那个标签
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-demoSettings") { tab = .settings }
            if args.contains("-demoRecords") { tab = .records }
            #endif
        }
        // 小组件点进来：shijing://wall/<壁纸文件名>，打开那张的大图
        .onOpenURL { url in
            guard url.scheme == "shijing", url.host() == "wall" else { return }
            pendingWall = url.lastPathComponent
            tab = .overview // 大图预览挂在概览上
            deliverPendingWall()
        }
        .onChange(of: store.selectedID) { syncSession() }
        .onChange(of: scenePhase) { _, phase in
            #if DEBUG
            if RemoteSession.demoMode != nil { return }
            #endif
            switch phase {
            case .active:
                discovery.setPaused(false)
                session?.endBackground(disconnect: false)
                session?.start()
            case .background:
                discovery.setPaused(true)
                session?.enterBackground()
            default:
                break
            }
        }
    }

    /// 选中的 Mac 变了：换一个连接。
    private func syncSession() {
        #if DEBUG
        if let mode = RemoteSession.demoMode {
            if session == nil { session = RemoteSession.demo(mode, store: store) }
            return
        }
        #endif
        guard let mac = store.selected else {
            session?.pause()
            session = nil
            return
        }
        if session?.macID == mac.id { return }
        session?.pause()
        let s = RemoteSession(mac: mac, store: store)
        session = s
        s.start()
        deliverPendingWall()
    }

    private func deliverPendingWall() {
        guard let name = pendingWall, let session else { return }
        session.openRequest = name
        pendingWall = nil
    }
}

/// 本地通知：换完了、签名快到期。权限在第一次从手机换一批时再问（不一上来就弹）。
@MainActor
enum Notifications {
    private static let delegate = ForegroundDelegate()

    static func setUp() {
        UNUserNotificationCenter.current().delegate = delegate
        Task {
            // 已经允许过才排签名到期提醒；没问过的等第一次换一批时问
            let s = await UNUserNotificationCenter.current().notificationSettings()
            if s.authorizationStatus == .authorized { SigningExpiry.scheduleReminder() }
        }
    }

    static func requestOnce() {
        Task {
            let center = UNUserNotificationCenter.current()
            guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
            if (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) == true {
                SigningExpiry.scheduleReminder()
            }
        }
    }

    /// App 在前台时也显示通知横幅（签名到期提醒；换完的通知在前台本来就不发）。
    private final class ForegroundDelegate: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
            [.banner, .sound]
        }
    }
}

#if DEBUG
import WidgetKit

/// 演示页：各种尺寸的两种小组件摆在一起看排版（启动参数 -demoWidgets）。
struct WidgetDemo: View {
    var body: some View {
        let now = Date().timeIntervalSince1970
        let idle = RemoteState(
            version: "0.3.104", eyebrow: "", title: "已换上 300 张新壁纸", running: false, stopping: false,
            steps: [], stage: nil, done: 0, total: 0, fraction: -1, label: nil, lastLine: nil, runDelete: false,
            rejected: 0, deleted: 0, deleteFailed: 0, blocked: nil, unmounted: 0, willDelete: false, deleteNote: nil,
            last: LastRun(at: now - 3600, status: "ok", error: nil, selected: 300, copied: 300, failed: 0, elapsed: 73,
                          brief: "重合 4% · 删 3 张", detail: nil),
            nextAuto: now + 5 * 3600, wallpapers: 300, wallsRev: nil, dest: "", sampleCount: 300, libraryDirs: 3)
        var running = idle
        running.running = true
        running.title = "正在拾一批新风景…"
        running.fraction = 0.43
        running.label = "复制 128 / 300 张"
        let e1 = entry(idle, "风景-冰岛-0001.jpg")
        let e2 = entry(running, "风景-京都-0002.jpg")
        var off = entry(idle, "风景-挪威-0006.jpg")
        off.offlineSince = Date().addingTimeInterval(-1800)
        var named = entry(idle, "风景-大理-0014.jpg")
        named.showName = true
        return ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack(spacing: 20) {
                            tile(e1, .systemSmall, 170, 170)
                            tile(e2, .systemSmall, 170, 170)
                            tile(e1, .systemSmall, 170, 170, photo: true)
                        }
                        tile(off, .systemMedium, 364, 170)
                        tile(e2, .systemMedium, 364, 170)
                        tile(named, .systemMedium, 364, 170, photo: true)
                    }
                    tile(e1, .systemLarge, 364, 382)
                    tile(e1, .systemExtraLarge, 715, 382)
                }
                HStack(alignment: .top, spacing: 20) {
                    if #available(iOS 27.0, *) {
                        tile(e1, .systemExtraLargePortrait, 364, 760)
                        tile(named, .systemExtraLargePortrait, 364, 760, photo: true)
                    }
                    VStack(alignment: .leading, spacing: 20) {
                        tile(e1, .accessoryRectangular, 160, 72, lock: true)
                        tile(e2, .accessoryRectangular, 160, 72, lock: true)
                        tile(e1, .accessoryRectangular, 160, 72, photo: true, lock: true)
                        HStack(spacing: 20) {
                            tile(e1, .accessoryCircular, 72, 72, lock: true)
                            tile(e2, .accessoryCircular, 72, 72, lock: true)
                        }
                        tile(e1, .accessoryInline, 220, 24, lock: true)
                    }
                    .padding(20)
                    .background(Color.black, in: RoundedRectangle(cornerRadius: 22))
                }
            }
            .padding(30)
        }
        .background(Color.gray.opacity(0.3))
    }

    private func entry(_ s: RemoteState, _ name: String) -> Entry {
        let file = FileManager.default.temporaryDirectory.appending(path: "demo-\(name)")
        if !FileManager.default.fileExists(atPath: file.path) {
            try? ImageStore.demoImage(name, large: true)?.jpegData(compressionQuality: 0.8)?.write(to: file)
        }
        return Entry(mac: "演示 Mac", state: s, imageFile: file, wallName: name)
    }

    @ViewBuilder
    private func tile(_ e: Entry, _ f: WidgetFamily, _ w: CGFloat, _ h: CGFloat, photo: Bool = false, lock: Bool = false) -> some View {
        Group {
            if photo { PhotoView(entry: e, familyOverride: f) } else { StatusView(entry: e, familyOverride: f) }
        }
        .foregroundStyle(lock ? Color.white : Color.primary)
        .background(WidgetBackdrop(entry: e, dim: !photo, familyOverride: f))
        .frame(width: w, height: h)
        .clipShape(RoundedRectangle(cornerRadius: lock ? 0 : 22, style: .continuous))
    }
}
#endif
