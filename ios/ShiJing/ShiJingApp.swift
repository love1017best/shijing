import SwiftUI

@main
struct ShiJingApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// 顶层：左栏是 Mac 列表，右栏是选中那台的遥控面板。
/// 窄屏（竖着拿的手机、折叠状态、分屏的窄半边）自动收成一栏导航栈，宽屏左右两栏。
struct RootView: View {
    @State private var store = MacStore()
    @State private var discovery = Discovery()
    @State private var session: RemoteSession?
    @State private var compactColumn = NavigationSplitViewColumn.detail
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $compactColumn) {
            MacListView(store: store, discovery: discovery)
                .navigationTitle("拾景")
        } detail: {
            if let session {
                DashboardView(session: session, store: store)
                    .id(session.macID)
            } else {
                ContentUnavailableView {
                    Label("选一台 Mac", systemImage: "desktopcomputer")
                } description: {
                    Text("在电脑上的拾景里打开「设置 › 手机遥控」，这台 Mac 会出现在列表里，点它配对。")
                }
            }
        }
        .onAppear {
            discovery.start()
            syncSession()
            if store.selected == nil { compactColumn = .sidebar }
        }
        .onChange(of: store.selectedID) {
            syncSession()
            if store.selectedID != nil { compactColumn = .detail }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                discovery.start()
                session?.start()
            case .background:
                discovery.stop()
                session?.pause()
            default:
                break
            }
        }
    }

    /// 选中的 Mac 变了：换一个连接。
    private func syncSession() {
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
