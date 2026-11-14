import SwiftUI

/// 「记录」页的三栏（电脑上分别在日志区、「删除记录」页、图库页）。
enum RecordsGroup: String, CaseIterable {
    case log, deletions, excluded

    var title: String {
        switch self {
        case .log: "运行日志"
        case .deletions: "删除记录"
        case .excluded: "不再选"
        }
    }
}

/// 「记录」页：运行日志、删除记录、不再选名单。和设置页一样用一条分段控件切三栏（左右滑也能切），
/// 选过哪一栏会记住——原来是指向三个二级页的菜单，用户觉得没必要多这一层（v0.3.171）。
struct RecordsPage: View {
    let session: RemoteSession
    @AppStorage("recordsGroup") private var groupRaw = RecordsGroup.log.rawValue
    /// 显示过的栏：没显示过的不构建、也不发请求（三页各有各的）
    @State private var seenGroups: Set<String> = []

    var body: some View {
        Group {
            if let state = session.state {
                if state.settings != nil { // 第 3 期的接口，旧版桌面端没有
                    pager
                } else {
                    List {
                        Section {
                            Text("电脑上的拾景版本较旧，升级后才能看到记录。")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentWidthCap(max: 680)
                }
            } else {
                ConnectionFallback(session: session)
            }
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("记录")
        .navigationBarTitleDisplayMode(.inline)
        // 切换栏放在导航栏下面一条整宽的栏里，和设置页同一个做法：导航栏中间放不下三个中文标签
        .safeAreaInset(edge: .top, spacing: 0) {
            if showsPager { picker }
        }
        .connectionToolbar(session)
        .onAppear {
            #if DEBUG
            // 截图用：-demoLog / -demoDeletions / -demoExcluded 直接打开那一栏
            let args = ProcessInfo.processInfo.arguments
            for g in RecordsGroup.allCases where args.contains("-demo" + g.rawValue.capitalized) {
                groupRaw = g.rawValue
            }
            #endif
        }
    }

    private var showsPager: Bool {
        guard let state = session.state else { return false }
        return state.settings != nil
    }

    private var picker: some View {
        Picker("记录分类", selection: $groupRaw) {
            ForEach(RecordsGroup.allCases, id: \.rawValue) { g in
                Text(g.title).tag(g.rawValue)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 680)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    /// 三栏并排，左右滑也能切换（分段控件和翻页用同一个 selection）。
    private var pager: some View {
        TabView(selection: $groupRaw) {
            page(.log) { LogView(session: session) }
            page(.deletions) { DeletionsView(session: session) }
            page(.excluded) { ExcludedView(session: session) }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .onChange(of: groupRaw) { _, new in seenGroups.insert(new) }
    }

    /// 当前栏和左右邻居先构建好（滑过去不会空一帧），更远的、也从没显示过的先留空。
    private var builtGroups: Set<String> {
        var s = seenGroups
        if let i = RecordsGroup.allCases.firstIndex(where: { $0.rawValue == groupRaw }) {
            s.insert(groupRaw)
            if i > 0 { s.insert(RecordsGroup.allCases[i - 1].rawValue) }
            if i + 1 < RecordsGroup.allCases.count { s.insert(RecordsGroup.allCases[i + 1].rawValue) }
        }
        return s
    }

    private func page<Content: View>(_ g: RecordsGroup, @ViewBuilder content: () -> Content) -> some View {
        Group {
            if builtGroups.contains(g.rawValue) { content() }
        }
        .contentWidthCap(max: 680)
        .tag(g.rawValue)
    }
}

// MARK: - 三个记录页共用的取数

/// 一次取数的结果：拿到的是电脑上的新数据，还是手机上存的那份（`syncedAt` 非空）。
struct RecordLoad<T> {
    var value: T?
    var syncedAt: Date?
    var error: String?
}

/// 三个记录页的取数逻辑是一样的：连得上就取电脑上的；取不到（或者离线）读手机上存的那份；
/// 都没有时给一句说明。日志、删除记录、不再选只是接口和文案不同。
@MainActor
func loadRecord<T: Codable>(
    _ session: RemoteSession,
    _ kind: RecordsKind,
    offlineNote: String,
    online: (APIClient) async throws -> T
) async -> RecordLoad<T> {
    if !session.offline {
        do {
            return RecordLoad(value: try await online(session.client()), syncedAt: nil, error: nil)
        } catch {
            // 刚连不上：接着看有没有存下来的副本
            if let c: OfflineStore.Cached<T> = await OfflineStore.shared.loadRecord(session.macID.uuidString, kind) {
                return RecordLoad(value: c.value, syncedAt: c.at, error: nil)
            }
            return RecordLoad(value: nil, syncedAt: nil, error: RemoteSession.describe(error))
        }
    }
    if let c: OfflineStore.Cached<T> = await OfflineStore.shared.loadRecord(session.macID.uuidString, kind) {
        return RecordLoad(value: c.value, syncedAt: c.at, error: nil)
    }
    return RecordLoad(value: nil, syncedAt: nil, error: offlineNote)
}

/// 记录页顶部的一行：显示的是手机上存的副本时，说明那份是什么时候同步的。
struct RecordsCacheNote: View {
    let session: RemoteSession
    let at: Date

    var body: some View {
        Label {
            Text(session.offline
                 ? "离线 · \(DashboardView.ago(at))同步，下面是手机上存的副本"
                 : "连不上电脑 · 显示的是 \(DashboardView.ago(at))同步的副本")
        } icon: {
            Image(systemName: "wifi.slash").foregroundStyle(.orange)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
}

/// 不在 List 里的页面（日志、空状态）用的顶部说明：一行提示 + 分隔线。
struct RecordsCacheHeader: View {
    let session: RemoteSession
    let at: Date?

    var body: some View {
        if let at {
            RecordsCacheNote(session: session, at: at)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal).padding(.vertical, 8)
            Divider()
        }
    }
}

extension View {
    /// List 里的版本：把「显示的是副本」作为一个分组放在最上面。
    @ViewBuilder
    func recordsCacheSection(_ session: RemoteSession, _ at: Date?) -> some View {
        if let at {
            Section {
                RecordsCacheNote(session: session, at: at)
            }
        }
    }
}

// MARK: - 运行日志

/// 电脑上的运行日志（最近 400 行），运行中每 2 秒刷新、自动滚到底。
/// 连不上电脑时显示手机上存的那份（连上时、换完一批后自动更新）。
struct LogView: View {
    let session: RemoteSession
    @State private var lines: [String]?
    @State private var error: String?
    /// 显示的是存下来的副本时，那份是什么时候同步的
    @State private var syncedAt: Date?

    var body: some View {
        Group {
            if let lines {
                if lines.isEmpty {
                    VStack(spacing: 0) {
                        RecordsCacheHeader(session: session, at: syncedAt)
                        ContentUnavailableView("还没有日志", systemImage: "text.alignleft",
                                               description: Text("电脑上的拾景这次启动后还没运行过。"))
                    }
                } else {
                    VStack(spacing: 0) {
                        RecordsCacheHeader(session: session, at: syncedAt)
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 3) {
                                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                                        Text(line)
                                            .font(.footnote.monospaced())
                                            .foregroundStyle(Self.color(line))
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .id(i)
                                    }
                                }
                                .textSelection(.enabled)
                                .padding()
                            }
                            .onAppear { proxy.scrollTo(lines.count - 1, anchor: .bottom) }
                            .onChange(of: lines.count) { _, n in
                                withAnimation { proxy.scrollTo(n - 1, anchor: .bottom) }
                            }
                        }
                    }
                }
            } else if let error {
                ContentUnavailableView("读不到日志", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView()
            }
        }
        .task(id: "\(session.state?.running ?? false)|\(session.offline)") {
            repeat {
                await load()
                try? await Task.sleep(for: .seconds(2))
            } while session.state?.running == true && !session.offline && !Task.isCancelled
        }
        .refreshable { await load() }
    }

    private func load() async {
        let r = await loadRecord(session, .log,
                                 offlineNote: "现在连不上电脑，手机上还没存过日志。连上电脑后会自动存一份，断线时就能看。") {
            try await $0.log()
        }
        lines = r.value
        syncedAt = r.syncedAt
        error = r.error
    }

    static func color(_ line: String) -> Color {
        if line.contains("❌") || line.contains("失败") { return .red }
        if line.contains("🔥") || line.contains("🗑") { return .orange }
        return .primary
    }
}

// MARK: - 删除记录

/// 删除记录：从图库里删掉的原图，按天分组（可以折叠），新的在前；
/// 顶上的标签可以只看筛选删的、只看手动删的，也可以两个都选（等于全看）。
/// 连不上电脑时显示手机上存的那份（连上时、换完一批后自动更新）。
struct DeletionsView: View {
    let session: RemoteSession
    @State private var list: DeletionList?
    @State private var error: String?
    /// 显示的是存下来的副本时，那份是什么时候同步的
    @State private var syncedAt: Date?
    /// 选中的标签：空着就是全部
    @State private var kinds: Set<Kind> = []
    /// 折叠起来的日期（默认都展开）
    @State private var collapsedDays: Set<Date> = []

    /// 记录的类型标签（两个可以同时选）
    enum Kind: Hashable { case filter, manual }
    /// 桌面端 core.ReasonManual 写的就是这个词，其余（包括没有原因的旧日志）都算筛选删的
    private static let manualReason = "手动删除"

    var body: some View {
        Group {
            if let list {
                let items = shown(list.items)
                if list.items.isEmpty {
                    VStack(spacing: 0) {
                        RecordsCacheHeader(session: session, at: syncedAt)
                        ContentUnavailableView("没有删除过原图", systemImage: "trash.slash")
                    }
                } else {
                    List {
                        recordsCacheSection(session, syncedAt)
                        Section {
                            HStack(spacing: 8) {
                                chip(.filter, "筛选删除", count: list.filter ?? counted(list.items, .filter))
                                chip(.manual, "手动删除", count: list.manual ?? counted(list.items, .manual))
                                Spacer()
                            }
                        } footer: {
                            Text(note(list))
                        }
                        if items.isEmpty {
                            Text("没有符合筛选的记录。").foregroundStyle(.secondary)
                        }
                        ForEach(groups(items), id: \.day) { g in
                            let open = !collapsedDays.contains(g.day)
                            Section {
                                if open {
                                    ForEach(g.items) { d in
                                        row(d)
                                    }
                                }
                            } header: {
                                // 标题自己画箭头、自己收合：Section(isExpanded:) 在这个样式下不显示箭头，看不出来能折
                                Button {
                                    withAnimation(.easeInOut(duration: 0.18)) {
                                        if open { collapsedDays.insert(g.day) } else { collapsedDays.remove(g.day) }
                                    }
                                } label: {
                                    HStack(spacing: 6) {
                                        Text("\(g.day.formatted(.dateTime.year().month().day().weekday())) · \(g.items.count) 张")
                                        Spacer()
                                        Image(systemName: open ? "chevron.down" : "chevron.right")
                                            .font(.caption.weight(.semibold))
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        if list.total > list.items.count {
                            Text("只显示最近 \(list.items.count) 条，共 \(list.total) 条；完整记录在电脑上的「删除记录」页。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            } else if let error {
                ContentUnavailableView("读不到删除记录", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView()
            }
        }
        // 连上 / 断开、以及电脑换完一批（last.at 变了）都重新取一次
        .task(id: "\(session.offline)|\(session.state?.last?.at ?? 0)") { await load() }
        .refreshable { await load() }
    }

    private func row(_ d: Deletion) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(d.name).font(.subheadline).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(d.date, format: .dateTime.hour().minute())
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            if let r = d.reason, !r.isEmpty {
                Text(r).font(.caption).foregroundStyle(.orange)
            }
            Text(d.dir).font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.head)
        }
    }

    /// 一个类型标签：点一下选中，再点取消；两个都选等于全看。
    private func chip(_ k: Kind, _ title: String, count: Int) -> some View {
        let on = kinds.contains(k)
        return Button {
            if on { kinds.remove(k) } else { kinds.insert(k) }
        } label: {
            HStack(spacing: 6) {
                Text(title).font(.subheadline.weight(.medium))
                Text("\(count)").font(.caption).monospacedDigit()
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .foregroundStyle(on ? Color.white : Color.primary)
            .background(on ? Color.accentColor : Color.secondary.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) \(count) 张")
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    /// 旧版桌面端没推两类张数时，按已经拿到的记录数
    private func counted(_ items: [Deletion], _ k: Kind) -> Int {
        items.reduce(0) { $0 + (kindsOf($1) == k ? 1 : 0) }
    }

    private func kindsOf(_ d: Deletion) -> Kind {
        d.reason == Self.manualReason ? .manual : .filter
    }

    /// 顶上的说明：两类的数量（旧版桌面端没推就没有）和各自的含义
    private func note(_ list: DeletionList) -> String {
        var head = ""
        if let f = list.filter, let m = list.manual {
            head = "记录里筛选删除 \(f) 张、手动删除 \(m) 张。"
        }
        return head + "筛选删除是竖屏、接近正方形、分辨率不够的图；手动删除是在预览或手机上点「删除图库里的原图」的。"
    }

    /// 把标签的选择套到记录上：没选标签就全看，选了的类型都留下。
    /// 没有原因的旧日志算筛选删的，和电脑上的计数一致。
    private func shown(_ items: [Deletion]) -> [Deletion] {
        guard !kinds.isEmpty else { return items }
        return items.filter { kinds.contains(kindsOf($0)) }
    }

    private func groups(_ items: [Deletion]) -> [(day: Date, items: [Deletion])] {
        let cal = Calendar.current
        var out: [(day: Date, items: [Deletion])] = []
        for d in items {
            let day = cal.startOfDay(for: d.date)
            if out.last?.day == day { out[out.count - 1].items.append(d) } else { out.append((day, [d])) }
        }
        return out
    }

    private func load() async {
        let r = await loadRecord(session, .deletions,
                                 offlineNote: "现在连不上电脑，手机上还没存过删除记录。连上电脑后会自动存一份，断线时就能看。") {
            try await $0.deletions()
        }
        list = r.value
        syncedAt = r.syncedAt
        error = r.error
    }
}

// MARK: - 不再选

/// 「不再选」名单：以后采样会跳过的原图。左滑恢复一张，或者全部恢复。
struct ExcludedView: View {
    let session: RemoteSession
    @State private var items: [ExcludedItem]?
    @State private var error: String?
    @State private var confirmAll = false
    /// 显示的是存下来的副本时，那份是什么时候同步的
    @State private var syncedAt: Date?

    var body: some View {
        Group {
            if let items {
                if items.isEmpty {
                    VStack(spacing: 0) {
                        RecordsCacheHeader(session: session, at: syncedAt)
                        ContentUnavailableView("没有不再选的图片", systemImage: "checkmark.circle",
                                               description: Text("在大图预览里点「不再选它」的原图会出现在这里。"))
                    }
                } else {
                    List {
                        recordsCacheSection(session, syncedAt)
                        Section {
                            ForEach(items) { it in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(it.name).font(.subheadline).lineLimit(1).truncationMode(.middle)
                                    Text(it.folder).font(.caption2).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.head)
                                }
                                .swipeActions {
                                    Button("恢复") { Task { await restore([it.path]) } }.tint(.accentColor)
                                }
                                .contextMenu {
                                    Button("恢复，以后可以再选到", systemImage: "arrow.uturn.backward") {
                                        Task { await restore([it.path]) }
                                    }
                                }
                                .disabled(session.offline) // 恢复要改电脑上的名单，离线时只能看
                            }
                        } footer: {
                            Text(session.offline
                                 ? "离线时只能查看，连上电脑后再恢复。"
                                 : "恢复后，以后换一批时这些原图又可能被选上。左滑一张可以单独恢复。")
                        }
                        // 「全部恢复」放在列表末尾：原来在导航栏右下角，三栏并排后 tab 页的 toolbar
                        // 会叠到别的栏上，放在这里也更容易看见
                        Section {
                            Button {
                                confirmAll = true
                            } label: {
                                Label("全部恢复", systemImage: "arrow.uturn.backward")
                            }
                            .disabled(session.offline)
                        }
                    }
                }
            } else if let error {
                ContentUnavailableView("读不到名单", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView()
            }
        }
        .confirmationDialog("恢复全部 \(items?.count ?? 0) 张？", isPresented: $confirmAll, titleVisibility: .visible) {
            Button("全部恢复") { Task { await restore(nil) } }
            Button("取消", role: .cancel) {}
        }
        // 连上 / 断开、以及电脑换完一批（last.at 变了）都重新取一次
        .task(id: "\(session.offline)|\(session.state?.last?.at ?? 0)") { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        let r = await loadRecord(session, .excluded,
                                 offlineNote: "现在连不上电脑，手机上还没存过「不再选」名单。连上电脑后会自动存一份，断线时就能看。") {
            try await $0.excluded()
        }
        items = r.value
        syncedAt = r.syncedAt
        error = r.error
    }

    private func restore(_ paths: [String]?) async {
        guard !session.offline else {
            session.actionError = "连不上电脑时不能恢复，连上后再试。"
            return
        }
        do {
            withAnimation { items = nil == paths ? [] : items?.filter { !paths!.contains($0.path) } }
            items = try await session.client().restoreExcluded(paths)
            Task { await session.refreshRecordsCache() } // 名单变了，离线时看的那份也跟着更新
        } catch {
            session.actionError = RemoteSession.describe(error)
            await load()
        }
    }
}
