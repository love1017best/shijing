import SwiftUI

@main
struct ShiJingApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// 顶层：没配对过任何 Mac 时整屏是「找 Mac / 配对」；配对过之后只有遥控面板，
/// 切换、添加、移除 Mac 收在标题菜单里（点顶部的 Mac 名字）——这些只在第一次装的时候用，不值得常驻一个侧栏。
struct RootView: View {
    @State private var store = MacStore()
    @State private var discovery = Discovery()
    @State private var session: RemoteSession?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let session {
                NavigationStack {
                    DashboardView(session: session, store: store)
                        .macTitleMenu(store: store, discovery: discovery)
                }
                .id(session.macID)
            } else {
                SetupView(store: store, discovery: discovery)
            }
        }
        .onAppear { syncSession() }
        .onChange(of: store.selectedID) { syncSession() }
        .onChange(of: scenePhase) { _, phase in
            #if DEBUG
            if RemoteSession.demoMode != nil { return }
            #endif
            switch phase {
            case .active:
                discovery.setPaused(false)
                session?.start()
            case .background:
                discovery.setPaused(true)
                session?.pause()
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
    }
}
