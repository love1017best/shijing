import SwiftUI

/// 概览里的「状态」：只读，和电脑概览顶部的摘要条对应（壁纸文件夹、张数、图库、下次自动换）。改设置去「设置」页。
struct StatusSection: View {
    let state: RemoteState

    var body: some View {
        Section("状态") {
            LabeledContent("壁纸文件夹", value: state.dest)
            LabeledContent("现在有", value: "\(state.wallpapers) 张")
            LabeledContent("每次换", value: "\(state.settings?.sampleCount ?? state.sampleCount) 张")
            LabeledContent("图库目录", value: "\(state.libraryDirs) 个")
            if let next = state.nextAutoDate {
                LabeledContent("下次自动换") {
                    Text(next, format: .dateTime.month().day().hour().minute())
                }
            }
        }
    }
}

/// 设置页和记录页共用的外壳：还没拿到状态时显示连接中 / 连不上，拿到了再显示内容（列表收窄到适合阅读的宽度）。
struct MacPage<Content: View>: View {
    let session: RemoteSession
    let title: String
    @ViewBuilder let content: (RemoteState) -> Content
    @State private var width: CGFloat = 0

    var body: some View {
        Group {
            if let state = session.state {
                List { content(state) }
                    // 内屏、iPad 上别拉得太宽（和电脑上设置页的单栏最宽一样的思路）
                    .contentMargins(.horizontal, max(0, (width - 680) / 2), for: .scrollContent)
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
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { ConnectionBadge(connection: session.connection) }
        }
    }
}

/// 「设置」页：电脑上常调的几项在手机上直接改（改完电脑上的设置页同步变，和在电脑上改一样自动保存）。
/// 分组和电脑上的设置页一致：采样、筛选、自动换壁纸、系统，最后是关于。旧版桌面端不推 settings，就只读显示。
struct SettingsPage: View {
    let session: RemoteSession
    /// 每次张数的草稿：步进器连点时先改这里，停手 0.8 秒再发给电脑
    @State private var draftCount: Int?
    @State private var countTask: Task<Void, Never>?

    var body: some View {
        MacPage(session: session, title: "设置") { state in
            if let set = state.settings {
                editable(set, state)
            } else {
                Section {
                    LabeledContent("每次换", value: "\(state.sampleCount) 张")
                } footer: {
                    Text("电脑上的拾景版本较旧，要改设置请在电脑上改。")
                }
            }
            aboutSection(state)
        }
        .toolbar {
            if session.savingSettings {
                ToolbarItem(placement: .automatic) { ProgressView() } // 正在把改动发给电脑
            }
        }
    }

    @ViewBuilder
    private func editable(_ set: RemoteSettings, _ state: RemoteState) -> some View {
        let disabled = state.running || session.connection != .live
        Section {
            Stepper(value: Binding(
                get: { draftCount ?? set.sampleCount },
                set: { setCount($0) }
            ), in: 1...9999, step: (draftCount ?? set.sampleCount) < 50 ? 5 : 10) {
                LabeledContent("每次张数", value: "\(draftCount ?? set.sampleCount) 张")
            }
            .disabled(disabled)
            toggle("优先选没换上过的", set.preferUnseen, key: "prefer_unseen", disabled: disabled)
        } header: {
            Text("采样")
        } footer: {
            Text("优先选没换上过的：这一轮里还没换上过的图片先选，都换上过一遍再从头开始。")
        }
        Section {
            toggle("删除不合格的原图", set.deleteDuringFilter, key: "delete_during_filter", tint: .red, disabled: disabled)
        } header: {
            Text("筛选")
        } footer: {
            Text("打开后，换一批时会删除图库里竖屏、分辨率不够的原图，不能撤销。从手机换一批时会先确认，也可以选这次只模拟。")
        }
        Section {
            Picker("间隔", selection: Binding(
                get: { set.autoRunHours },
                set: { h in Task { await session.updateSettings(["auto_run_hours": h]) } }
            )) {
                // 配置里是不在选项里的值（手动改过配置文件）时也显示出来，免得选中项为空
                ForEach(set.autoOptions.contains(set.autoRunHours) ? set.autoOptions : set.autoOptions + [set.autoRunHours], id: \.self) {
                    Text(RemoteSettings.autoLabel($0)).tag($0)
                }
            }
            .disabled(disabled)
            if let next = state.nextAutoDate {
                LabeledContent("下一次") {
                    Text(next, format: .dateTime.month().day().hour().minute())
                }
            }
        } header: {
            Text("自动换壁纸")
        } footer: {
            Text("电脑上的拾景开着时按这个间隔自动换一批。自动运行不会删除原图。")
        }
        Section {
            toggle("刷新系统壁纸", set.refreshWallpaper, key: "refresh_wallpaper", disabled: disabled)
        } header: {
            Text("系统")
        } footer: {
            Text("换完一批后重启 macOS 的壁纸服务，不然系统会继续轮换已经删掉的旧图。\n输出方式、画质要求、图库目录、归档等其他设置在电脑上改。")
        }
    }

    /// 关于：两边的版本，版本不一样时提醒一下。
    private func aboutSection(_ state: RemoteState) -> some View {
        Section {
            LabeledContent("电脑上的拾景", value: state.version.isEmpty ? "开发版" : "v" + state.version)
            LabeledContent("这台手机上", value: AppVersion.text)
            if let exp = SigningExpiry.text {
                LabeledContent("签名", value: exp)
            }
            LabeledContent("壁纸文件夹", value: state.dest)
        } header: {
            Text("关于")
        } footer: {
            if !state.version.isEmpty, state.version != AppVersion.short {
                Text("两边版本不一样，有的功能可能用不了，建议都升到最新。")
            }
        }
    }

    private func toggle(_ title: String, _ value: Bool, key: String, tint: Color? = nil, disabled: Bool) -> some View {
        Toggle(title, isOn: Binding(
            get: { value },
            set: { v in Task { await session.updateSettings([key: v]) } }
        ))
        .tint(tint)
        .disabled(disabled)
    }

    private func setCount(_ n: Int) {
        draftCount = n
        countTask?.cancel()
        countTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            await session.updateSettings(["sample_count": n])
            draftCount = nil
        }
    }
}

/// 「记录」页：运行日志、删除记录、不再选名单（电脑上分别在日志区、「删除记录」页、图库页）。
struct RecordsPage: View {
    let session: RemoteSession

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
    }
}

/// 电脑上的运行日志（最近 400 行），运行中每 2 秒刷新、自动滚到底。
struct LogView: View {
    let session: RemoteSession
    @State private var lines: [String]?
    @State private var error: String?

    var body: some View {
        Group {
            if let lines {
                if lines.isEmpty {
                    ContentUnavailableView("还没有日志", systemImage: "text.alignleft",
                                           description: Text("电脑上的拾景这次启动后还没运行过。"))
                } else {
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
            } else if let error {
                ContentUnavailableView("读不到日志", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView()
            }
        }
        .navigationTitle("运行日志")
        .iOSInlineTitle()
        .task(id: session.state?.running) {
            repeat {
                await load()
                try? await Task.sleep(for: .seconds(2))
            } while session.state?.running == true && !Task.isCancelled
        }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            lines = try await session.client().log()
            error = nil
        } catch {
            self.error = RemoteSession.describe(error)
        }
    }

    static func color(_ line: String) -> Color {
        if line.contains("❌") || line.contains("失败") { return .red }
        if line.contains("🔥") || line.contains("🗑") { return .orange }
        return .primary
    }
}

/// 删除记录：从图库里删掉的原图，按天分组，新的在前。
struct DeletionsView: View {
    let session: RemoteSession
    @State private var list: DeletionList?
    @State private var error: String?

    var body: some View {
        Group {
            if let list {
                if list.items.isEmpty {
                    ContentUnavailableView("没有删除过原图", systemImage: "trash.slash")
                } else {
                    List {
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
        .task { await load() }
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
        do {
            list = try await session.client().deletions()
            error = nil
        } catch {
            self.error = RemoteSession.describe(error)
        }
    }
}

/// 「不再选」名单：以后采样会跳过的原图。左滑恢复一张，或者全部恢复。
struct ExcludedView: View {
    let session: RemoteSession
    @State private var items: [ExcludedItem]?
    @State private var error: String?
    @State private var confirmAll = false

    var body: some View {
        Group {
            if let items {
                if items.isEmpty {
                    ContentUnavailableView("没有不再选的图片", systemImage: "checkmark.circle",
                                           description: Text("在大图预览里点「不再选它」的原图会出现在这里。"))
                } else {
                    List {
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
                            }
                        } footer: {
                            Text("恢复后，以后换一批时这些原图又可能被选上。左滑一张可以单独恢复。")
                        }
                    }
                    .toolbar {
                        Button("全部恢复") { confirmAll = true }
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
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            items = try await session.client().excluded()
            error = nil
        } catch {
            self.error = RemoteSession.describe(error)
        }
    }

    private func restore(_ paths: [String]?) async {
        do {
            withAnimation { items = nil == paths ? [] : items?.filter { !paths!.contains($0.path) } }
            items = try await session.client().restoreExcluded(paths)
        } catch {
            session.actionError = RemoteSession.describe(error)
            await load()
        }
    }
}

/// 这台手机上拾景的版本号（和电脑端同一套，见 project.yml 的 MARKETING_VERSION）。
enum AppVersion {
    static let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    static var text: String { short.isEmpty ? "开发版" : "v" + short }
}
