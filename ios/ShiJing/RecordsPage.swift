import SwiftUI

/// 「记录」页：运行日志、删除记录、不再选名单（电脑上分别在日志区、「删除记录」页、图库页）。
struct RecordsPage: View {
    let session: RemoteSession
    #if DEBUG
    /// 截图用：-demoLog / -demoDeletions / -demoExcluded 直接打开对应的子页（模拟器里点不动时用）
    @State private var demoPage: String? = {
        let a = ProcessInfo.processInfo.arguments
        for k in ["Log", "Deletions", "Excluded"] where a.contains("-demo" + k) { return k.lowercased() }
        return nil
    }()
    #endif

    var body: some View {
        MacPage(session: session, title: "记录") { state in
            if state.settings != nil { // 第 3 期的接口，旧版桌面端没有
                Section {
                    NavigationLink { LogView(session: session) } label: {
                        Label("运行日志", systemImage: "text.alignleft")
                    }
                    NavigationLink { DeletionsView(session: session) } label: {
                        Label("删除记录", systemImage: "trash")
                    }
                    NavigationLink { ExcludedView(session: session) } label: {
                        LabeledContent {
                            Text("\(state.excluded ?? 0) 张")
                        } label: {
                            Label("不再选的图片", systemImage: "nosign")
                        }
                    }
                }
            } else {
                Section {
                    Text("电脑上的拾景版本较旧，没有记录可看。把电脑上的拾景升到最新就有了。")
                        .foregroundStyle(.secondary)
                }
            }
        }
        #if DEBUG
        .navigationDestination(isPresented: Binding(
            get: { demoPage != nil },
            set: { if !$0 { demoPage = nil } }
        )) {
            switch demoPage {
            case "log": LogView(session: session)
            case "deletions": DeletionsView(session: session)
            default: ExcludedView(session: session)
            }
        }
        #endif
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
            if let c: OfflineStore.Cached<T> = OfflineStore.shared.loadRecord(session.macID.uuidString, kind) {
                return RecordLoad(value: c.value, syncedAt: c.at, error: nil)
            }
            return RecordLoad(value: nil, syncedAt: nil, error: RemoteSession.describe(error))
        }
    }
    if let c: OfflineStore.Cached<T> = OfflineStore.shared.loadRecord(session.macID.uuidString, kind) {
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
        .navigationTitle("运行日志")
        .iOSInlineTitle()
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

/// 删除记录：从图库里删掉的原图，按天分组，新的在前。
/// 连不上电脑时显示手机上存的那份（连上时、换完一批后自动更新）。
struct DeletionsView: View {
    let session: RemoteSession
    @State private var list: DeletionList?
    @State private var error: String?
    /// 显示的是存下来的副本时，那份是什么时候同步的
    @State private var syncedAt: Date?

    var body: some View {
        Group {
            if let list {
                if list.items.isEmpty {
                    VStack(spacing: 0) {
                        RecordsCacheHeader(session: session, at: syncedAt)
                        ContentUnavailableView("没有删除过原图", systemImage: "trash.slash")
                    }
                } else {
                    List {
                        recordsCacheSection(session, syncedAt)
                        if let f = list.filter, let m = list.manual {
                            Section {
                                LabeledContent("按筛选规则删除", value: "\(f) 张")
                                LabeledContent("手动删除", value: "\(m) 张")
                            } footer: {
                                Text("筛选删的是竖屏、接近正方形、分辨率不足的图；手动删的是在预览或手机上点「删除图库里的原图」的。")
                            }
                        }
                        ForEach(groups(list.items), id: \.day) { g in
                            Section(g.day.formatted(.dateTime.year().month().day().weekday())) {
                                ForEach(g.items) { d in
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
        .navigationTitle(list.map { "删除记录（\($0.total)）" } ?? "删除记录")
        .iOSInlineTitle()
        // 连上 / 断开、以及电脑换完一批（last.at 变了）都重新取一次
        .task(id: "\(session.offline)|\(session.state?.last?.at ?? 0)") { await load() }
        .refreshable { await load() }
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
                    }
                    .toolbar {
                        if !session.offline { Button("全部恢复") { confirmAll = true } }
                    }
                }
            } else if let error {
                ContentUnavailableView("读不到名单", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView()
            }
        }
        .navigationTitle(items.map { "不再选（\($0.count)）" } ?? "不再选")
        .iOSInlineTitle()
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
