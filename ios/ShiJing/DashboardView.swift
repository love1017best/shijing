import SwiftUI

/// 一台 Mac 的遥控面板（「概览」标签）：当前状态、换一批 / 停止、当前壁纸、上次运行、状态摘要。设置和记录在另外两个标签里。
/// 窄的时候一栏从上往下排；宽的时候（横屏、展开的大屏、iPad）分成左右两栏：左边操作，右边结果。
struct DashboardView: View {
    let session: RemoteSession
    let store: MacStore
    @State private var width: CGFloat = 0
    @State private var confirmDelete = false
    /// 宽屏两栏的列表要自己让开左右安全区
    @State private var safe = EdgeInsets()
    /// 正在看的大图（横幅、概览里的缩略图、小组件点进来的都走这里）。
    /// 放在这一层而不是缩略图网格里：转屏时宽窄两种排版换来换去，网格会被重建，状态放在里面预览就被关掉了。
    @State private var previewing: Wallpaper?
    /// 「全部壁纸」页；同理用状态推页面，不用放在分组标题里的 NavigationLink（转屏时它被重建，推出去的页面会被弹回来）
    @State private var showAll = false

    /// 内容区宽于这个值时分两栏（按实际宽度判断，不按机型写死）
    private static let twoColumnWidth: CGFloat = 680

    var body: some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .navigationTitle(session.mac.name)
            .iOSInlineTitle()
            .toolbar {
                ToolbarItem(placement: .primaryAction) { ConnectionBadge(connection: session.connection) }
            }
            .overlay(alignment: .top) { NoticeBubble(text: session.notice).padding(.top, 8) }
            .fullScreenCoverCompat(item: $previewing) { w in
                WallPreview(session: session, startName: w.name)
            }
            .navigationDestination(isPresented: $showAll) { AllWallpapersView(session: session) }
            // 小组件点进来：要看的那张（壁纸列表可能还没拉到，拉到了再打开）
            .onChange(of: session.openRequest, initial: true) { openRequested() }
            .onChange(of: session.walls) { openRequested() }
            #if DEBUG
            .onAppear {
                // 演示模式截图用：启动参数带 -demoPreview 时直接打开第 3 张的大图预览
                if ProcessInfo.processInfo.arguments.contains("-demoPreview"), session.walls.count > 2 {
                    previewing = session.walls[2]
                }
            }
            #endif
            .alert("操作没有完成", isPresented: Binding(
                get: { session.actionError != nil },
                set: { if !$0 { session.actionError = nil } })
            ) {
                Button("好") {}
            } message: {
                Text(session.actionError ?? "")
            }
            .confirmationDialog("这次运行会删除不合格的原图", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("删除并换一批", role: .destructive) { Task { await session.run(deleteOriginals: true) } }
                Button("只模拟筛选，不删除") { Task { await session.run(deleteOriginals: false) } }
                Button("取消", role: .cancel) {}
            } message: {
                Text(session.state?.deleteNote ?? "")
            }
            .sensoryFeedback(.success, trigger: session.state?.last?.at) { old, new in
                old != nil && new != nil && session.state?.last?.status == "ok"
            }
    }

    @ViewBuilder private var content: some View {
        if case .unpaired(let msg) = session.connection {
            ContentUnavailableView {
                Label("配对已失效", systemImage: "lock.slash")
            } description: {
                Text(msg + "\n移除后重新配对。")
            } actions: {
                Button("移除这台 Mac", role: .destructive) { store.remove(session.macID) }
                    .buttonStyle(.borderedProminent)
            }
        } else if let state = session.state {
            if width >= Self.twoColumnWidth {
                wideLayout(state)
            } else {
                List {
                    connectionSection
                    Section {
                        heroCard(state, wide: false)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                    signingSection
                    wallsSection(rows: 3)
                    lastRunSection(state)
                    overviewSection(state)
                }
            }
        } else if case .offline(let msg) = session.connection {
            ContentUnavailableView {
                Label("连不上 \(session.mac.name)", systemImage: "wifi.exclamationmark")
            } description: {
                Text(msg)
            } actions: {
                Button("重试") { session.start() }.buttonStyle(.bordered)
            }
        } else {
            ProgressView("正在连接 \(session.mac.name)…")
        }
    }

    // MARK: 宽屏

    /// 宽屏（横屏、展开的内屏、iPad）：顶部一张横跨整行的状态卡（左边状态、右边换一批 / 停止，不滚动），
    /// 下面两栏：左边当前壁纸（占得宽、多放几张），右边上次运行和设置。两栏之间、左右两边的留白和顶部卡片对齐。
    private func wideLayout(_ s: RemoteState) -> some View {
        let gap = Self.wideGap
        return VStack(spacing: 0) {
            heroCard(s, wide: true)
                .padding(.horizontal, gap)
                .padding(.top, 8)
            HStack(alignment: .top, spacing: 0) {
                List {
                    connectionSection
                    signingSection
                    wallsSection(rows: 3)
                }
                // 列表的边距不算安全区（内屏横放时右边有传感器区），自己加上，和顶部卡片对齐
                .contentMargins(.leading, gap + safe.leading, for: .scrollContent)
                .contentMargins(.trailing, gap / 2, for: .scrollContent)
                .frame(maxWidth: .infinity)
                .layoutPriority(1)
                List {
                    lastRunSection(s)
                    overviewSection(s)
                }
                .contentMargins(.leading, gap / 2, for: .scrollContent)
                .contentMargins(.trailing, gap + safe.trailing, for: .scrollContent)
                .frame(width: max(300, width * 0.36) + safe.trailing)
            }
            .scrollContentBackground(.hidden)
            .ignoresSafeArea(.container, edges: .horizontal)
        }
        .background(Color.groupedBackground)
        .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { safe = $0 }
    }

    private static let wideGap: CGFloat = 20

    private func openRequested() {
        guard let name = session.openRequest, let w = session.walls.first(where: { $0.name == name }) else { return }
        session.openRequest = nil
        showAll = false
        previewing = w
    }

    /// 顶部的横幅卡：背景是当前壁纸里的一张（和电脑上概览顶部同一张），点图片看大图。
    /// 窄屏：上面露出图片，下面压一整块毛玻璃放状态和按钮。
    /// 宽屏：图片铺满整张卡，左下角浮一块毛玻璃放状态，右下角是按钮；运行中毛玻璃撑满整行放步骤和进度。
    @ViewBuilder
    private func heroCard(_ s: RemoteState, wide: Bool) -> some View {
        let hero = session.hero
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        if wide && !s.running {
            HStack(alignment: .bottom, spacing: 16) {
                heroPanel(s, wide: false, button: false)
                    .padding(14)
                    .frame(maxWidth: 520, alignment: .leading)
                    .background(glass(hero), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                Spacer(minLength: 0)
                runButton(s).frame(width: 220)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 230, alignment: .bottom)
            .background { heroBackground(hero) }
            .clipShape(shape)
        } else {
            VStack(spacing: 0) {
                // 露出图片的部分：点开大图
                Color.clear
                    .frame(height: wide ? 60 : (s.running ? 100 : 150))
                    .contentShape(Rectangle())
                    .onTapGesture { if let hero { previewing = hero } }
                    .accessibilityAddTraits(hero == nil ? [] : .isButton)
                    .accessibilityLabel(hero.map { "查看大图：\($0.name)" } ?? "")
                heroPanel(s, wide: wide)
                    .padding(wide ? 16 : 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(glass(hero))
            }
            .background { heroBackground(hero) }
            .clipShape(shape)
        }
    }

    /// 横幅背景图；点空白处看大图（宽屏空闲时整张卡都是图）。
    @ViewBuilder
    private func heroBackground(_ hero: Wallpaper?) -> some View {
        if let hero {
            WallImage(session: session, wall: hero, kind: session.heroName != nil ? .hero : .image)
                .contentShape(Rectangle())
                .onTapGesture { previewing = hero }
        } else {
            Color.groupedCell
        }
    }

    private func glass(_ hero: Wallpaper?) -> AnyShapeStyle {
        hero == nil ? AnyShapeStyle(Color.groupedCell) : AnyShapeStyle(.regularMaterial)
    }

    @ViewBuilder
    private func heroPanel(_ s: RemoteState, wide: Bool, button: Bool = true) -> some View {
        let text = VStack(alignment: .leading, spacing: 4) {
            Text(s.eyebrow).font(.subheadline).foregroundStyle(.secondary)
            Text(s.title).font(.title2.bold()).lineLimit(2)
            if !s.running, let note = runNote(s) {
                Text(note).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        VStack(alignment: .leading, spacing: 12) {
            if wide {
                HStack(alignment: .center, spacing: 20) {
                    text.frame(maxWidth: .infinity, alignment: .leading)
                    if s.running {
                        stopButton(s).buttonStyle(.bordered).controlSize(.large)
                    } else {
                        runButton(s).frame(width: 220)
                    }
                }
            } else {
                text
                if !s.running && button { runButton(s) }
            }
            if s.running {
                StepsView(state: s)
                progressBlock(s)
                if s.steps.contains(Step.filter.rawValue) {
                    deleteRow(s).font(.subheadline)
                }
                if !wide {
                    stopButton(s).buttonStyle(.bordered).frame(maxWidth: .infinity)
                }
            }
        }
    }

    // MARK: 各个分组

    /// 已经拿到过状态、之后断开了：顶部提示一下，下面显示的是断开前的样子。
    /// 显示的是磁盘上的快照（这次打开还没连上过）时说明数据是什么时候的。
    @ViewBuilder private var connectionSection: some View {
        if case .offline(let msg) = session.connection {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        if let at = session.snapshotAt {
                            Text("离线，显示的是上次同步的壁纸").font(.subheadline.bold())
                            Text("数据是 \(Self.ago(at))同步的，正在重连。图片只有缓存过的能看。")
                                .font(.footnote).foregroundStyle(.secondary)
                            if !session.queued.isEmpty {
                                Text("离线时记下的 \(session.queued.count) 项操作，连上电脑后自动补上（删除原图要等连上再做）。")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        } else {
                            Text("连接已断开，正在重连").font(.subheadline.bold())
                            Text(msg).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange)
                }
            }
        }
    }

    /// 「3 小时前」「刚刚」：快照有多旧。
    static func ago(_ at: Date) -> String {
        let s = Date().timeIntervalSince(at)
        switch s {
        case ..<90: return "刚刚"
        case ..<3600: return "\(max(1, Int(s / 60))) 分钟前"
        case ..<86400: return "\(Int(s / 3600)) 小时前"
        default: return "\(Int(s / 86400)) 天前"
        }
    }

    private func progressBlock(_ s: RemoteState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if s.fraction >= 0 {
                ProgressView(value: s.fraction) {
                    progressLabel(s)
                }
            } else {
                ProgressView { progressLabel(s) }
            }
            if let line = s.lastLine, !line.isEmpty {
                Text(line).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    private func stopButton(_ s: RemoteState) -> some View {
        Button(role: .destructive) {
            Task { await session.stop() }
        } label: {
            Label(s.stopping ? "正在停止…" : "停止", systemImage: "stop.circle")
        }
        .disabled(s.stopping || session.busy)
    }

    /// 「换一批」按钮下面的说明：点不了的原因、目录访问不了、会删原图。
    private func runNote(_ s: RemoteState) -> String? {
        if let b = s.blocked { return b }
        if s.unmounted > 0 { return "上次检查时有 \(s.unmounted) 个图库目录访问不了，换一批前会重新检查。" }
        if s.willDelete { return "会先删除图库里不合格的原图，点了之后可以选只模拟。" }
        return nil
    }

    private func runButton(_ s: RemoteState) -> some View {
                Button {
                    if s.willDelete {
                        confirmDelete = true
                    } else {
                        Task { await session.run(deleteOriginals: false) }
                    }
                } label: {
                    // 文字和图标整体在按钮里居中；忙的时候换成转圈，按钮宽度不变
                    ZStack {
                        // 列表行会把按钮里的图标染成强调色，和按钮底色一样就看不见了（文字因此看着偏右），显式用白色
                        Label("换一批壁纸", systemImage: "shuffle")
                            .labelStyle(.titleAndIcon)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .opacity(session.busy ? 0 : 1)
                        if session.busy { ProgressView() }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: 12))
                .controlSize(.large)
                .disabled(s.blocked != nil || session.busy || session.connection != .live)
    }

    /// 当前壁纸：前几张缩略图，点开看大图、长按整理；「全部」进整个网格。
    @ViewBuilder private func wallsSection(rows: Int) -> some View {
        if !session.walls.isEmpty || session.undoName != nil {
            Section {
                WallGrid(session: session, rows: rows, onOpen: { previewing = $0 })
                    .listRowInsets(EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10))
                UndoRemoveButton(session: session)
            } header: {
                // 「全部」放在缩略图上面：先看到入口再看到图
                HStack {
                    Text("当前壁纸")
                    Spacer()
                    Button {
                        showAll = true
                    } label: {
                        HStack(spacing: 2) {
                            Text("全部 \(session.walls.count) 张")
                            Image(systemName: "chevron.right").imageScale(.small)
                        }
                        .font(.subheadline)
                    }
                }
                .textCase(nil)
            } footer: {
                Text("点一张看大图，长按可以移出或删除原图。")
            }
        }
    }

    private func progressLabel(_ s: RemoteState) -> some View {
        HStack {
            Text(s.label ?? "").font(.subheadline.bold())
            Spacer()
            if s.fraction >= 0 {
                Text(s.fraction, format: .percent.precision(.fractionLength(0)))
                    .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    private func deleteRow(_ s: RemoteState) -> some View {
        let n = s.runDelete ? s.deleted : s.rejected
        let title = s.runDelete ? "已删除 \(n) 张不合格原图" : "发现 \(n) 张不合格（模拟，没有删除）"
        return Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if s.deleteFailed > 0 {
                    Text("\(s.deleteFailed) 张删除失败，详情看电脑上的日志").font(.footnote).foregroundStyle(.red)
                }
            }
        } icon: {
            Image(systemName: s.runDelete ? "trash" : "eye")
                .foregroundStyle(n == 0 ? Color.secondary : (s.runDelete ? Color.red : Color.orange))
        }
    }

    @ViewBuilder private func lastRunSection(_ s: RemoteState) -> some View {
        if let l = s.last {
            Section("上次运行") {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(lastHeadline(l)).font(.headline)
                        Text(l.date, format: .dateTime.month().day().hour().minute())
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: lastIcon(l)).foregroundStyle(lastColor(l))
                }
                if let e = l.error, l.status == "failed" {
                    Text(e).font(.callout).foregroundStyle(.red)
                }
                if let d = l.detail, !d.isEmpty {
                    Text(d).font(.callout).foregroundStyle(.secondary)
                }
                if l.failed > 0 {
                    LabeledContent("复制失败", value: "\(l.failed) 张")
                }
                LabeledContent("用时", value: Self.elapsedText(l.elapsed))
            }
        }
    }

    /// 「1 分 13 秒」这种说法（系统的时长格式跟着语言走，写死成中文更稳）。
    static func elapsedText(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        switch s {
        case ..<60: return "\(s) 秒"
        case ..<3600: return s % 60 == 0 ? "\(s / 60) 分钟" : "\(s / 60) 分 \(s % 60) 秒"
        default: return "\(s / 3600) 小时 \(s % 3600 / 60) 分"
        }
    }

    private func lastHeadline(_ l: LastRun) -> String {
        switch l.status {
        case "ok": "换上了 \(l.copied) 张新壁纸"
        case "stopped": l.copied > 0 ? "中途停止，换上了 \(l.copied) 张" : "中途停止"
        default: "没有换成"
        }
    }

    private func lastIcon(_ l: LastRun) -> String {
        switch l.status {
        case "ok": "checkmark.circle.fill"
        case "stopped": "stop.circle.fill"
        default: "exclamationmark.triangle.fill"
        }
    }

    private func lastColor(_ l: LastRun) -> Color {
        switch l.status {
        case "ok": .green
        case "stopped": .secondary
        default: .red
        }
    }

    private func overviewSection(_ s: RemoteState) -> some View {
        StatusSection(state: s)
    }

    /// 免费签名快到期（剩不到 2 天）时顶部提醒重新安装。
    @ViewBuilder private var signingSection: some View {
        if SigningExpiry.isSoon, let text = SigningExpiry.text {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(SigningExpiry.isExpired ? "签名已经到期" : "签名\(text)").font(.subheadline.bold())
                        Text("免费签名只有 7 天，到期后拾景就打不开了。连上电脑重新安装一次就能续上。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "clock.badge.exclamationmark").foregroundStyle(.orange)
                }
            }
        }
    }
}

/// 运行步骤：筛选 → 采样 → 复制 → 刷新，做完的打勾、正在做的高亮。
struct StepsView: View {
    let state: RemoteState

    var body: some View {
        let steps = state.steps.compactMap(Step.init(rawValue:))
        let current = steps.firstIndex { $0.rawValue == state.stage } ?? 0
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { items(steps, current, showLines: true) }
            HStack(spacing: 10) { items(steps, current, showLines: false) }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("第 \(current + 1) 步，共 \(steps.count) 步：\(steps.indices.contains(current) ? steps[current].title : "")")
    }

    @ViewBuilder
    private func items(_ steps: [Step], _ current: Int, showLines: Bool) -> some View {
        ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
            if i > 0 && showLines {
                Capsule().fill(i <= current ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(minWidth: 12, maxWidth: .infinity).frame(height: 2)
            }
            HStack(spacing: 4) {
                Image(systemName: i < current ? "checkmark.circle.fill" : (i == current ? "\(i + 1).circle.fill" : "\(i + 1).circle"))
                    .foregroundStyle(i <= current ? Color.accentColor : Color.secondary)
                Text(step.title)
                    .font(.subheadline.weight(i == current ? .semibold : .regular))
                    .foregroundStyle(i <= current ? .primary : .secondary)
                    .fixedSize()
            }
        }
    }
}

/// 工具栏上的连接状态小圆点。
struct ConnectionBadge: View {
    let connection: RemoteSession.Connection

    var body: some View {
        let (color, text): (Color, String) = switch connection {
        case .live: (.green, "已连接")
        case .connecting: (.orange, "正在连接")
        case .offline: (.orange, "重连中")
        case .unpaired: (.red, "未配对")
        }
        Label {
            Text(text)
        } icon: {
            Circle().fill(color).frame(width: 8, height: 8)
        }
        .labelStyle(.titleAndIcon)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8) // 工具栏会给它包一层玻璃气泡，不留边距的话字贴着边
        .fixedSize()
        .accessibilityLabel("连接状态：\(text)")
    }
}

extension Color {
    /// 分组列表的页面底色和卡片底色（宽屏顶部卡片要和下面的列表一致）。
    #if os(iOS)
    static let groupedBackground = Color(uiColor: .systemGroupedBackground)
    static let groupedCell = Color(uiColor: .secondarySystemGroupedBackground)
    #else
    static let groupedBackground = Color(nsColor: .windowBackgroundColor)
    static let groupedCell = Color(nsColor: .controlBackgroundColor)
    #endif
}
