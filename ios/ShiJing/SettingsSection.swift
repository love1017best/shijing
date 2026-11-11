import SwiftUI

/// 概览里的「设置」：电脑上常调的几项在手机上直接改（改完电脑上的设置页同步变，和在电脑上改一样自动保存）。
/// 旧版桌面端不推 settings，就只读显示。
struct SettingsSection: View {
    let session: RemoteSession
    let state: RemoteState
    /// 每次张数的草稿：步进器连点时先改这里，停手 0.8 秒再发给电脑
    @State private var draftCount: Int?
    @State private var countTask: Task<Void, Never>?

    var body: some View {
        Section {
            LabeledContent("壁纸文件夹", value: state.dest)
            LabeledContent("现在有", value: "\(state.wallpapers) 张")
            if let set = state.settings {
                editable(set)
            } else {
                LabeledContent("每次换", value: "\(state.sampleCount) 张")
            }
            LabeledContent("图库目录", value: "\(state.libraryDirs) 个")
            if let next = state.nextAutoDate {
                LabeledContent("下次自动换") {
                    Text(next, format: .dateTime.month().day().hour().minute())
                }
            }
        } header: {
            HStack {
                Text("设置")
                if session.savingSettings { ProgressView().controlSize(.mini) }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if state.settings == nil {
                    Text("电脑上的拾景版本较旧，要改设置请在电脑上改。")
                }
                Text(versionNote)
            }
        }
    }

    /// 「电脑上拾景 v0.3.101，这台手机上 v0.3.101（11月18日 09:20 到期）。」两边版本不一样时提醒一下。
    private var versionNote: String {
        let mac = state.version.isEmpty ? "开发版" : "v" + state.version
        var text = "电脑上拾景 \(mac)，这台手机上 \(AppVersion.text)"
        if let exp = SigningExpiry.text { text += "（\(exp)）" }
        text += "。"
        if !state.version.isEmpty, state.version != AppVersion.short {
            text += "两边版本不一样，有的功能可能用不了，建议都升到最新。"
        }
        return text
    }

    @ViewBuilder
    private func editable(_ set: RemoteSettings) -> some View {
        let disabled = state.running || session.connection != .live
        Stepper(value: Binding(
            get: { draftCount ?? set.sampleCount },
            set: { setCount($0) }
        ), in: 1...9999, step: (draftCount ?? set.sampleCount) < 50 ? 5 : 10) {
            LabeledContent("每次换", value: "\(draftCount ?? set.sampleCount) 张")
        }
        .disabled(disabled)
        Picker("自动换", selection: Binding(
            get: { set.autoRunHours },
            set: { h in Task { await session.updateSettings(["auto_run_hours": h]) } }
        )) {
            // 配置里是不在选项里的值（手动改过配置文件）时也显示出来，免得选中项为空
            ForEach(set.autoOptions.contains(set.autoRunHours) ? set.autoOptions : set.autoOptions + [set.autoRunHours], id: \.self) {
                Text(RemoteSettings.autoLabel($0)).tag($0)
            }
        }
        .disabled(disabled)
        toggle("优先选没换上过的", set.preferUnseen, key: "prefer_unseen")
        toggle("换完刷新系统壁纸", set.refreshWallpaper, key: "refresh_wallpaper")
        toggle("删除不合格的原图", set.deleteDuringFilter, key: "delete_during_filter", tint: .red)
    }

    private func toggle(_ title: String, _ value: Bool, key: String, tint: Color? = nil) -> some View {
        Toggle(title, isOn: Binding(
            get: { value },
            set: { v in Task { await session.updateSettings([key: v]) } }
        ))
        .tint(tint)
        .disabled(state.running || session.connection != .live)
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

/// 「记录」分组：运行日志、删除记录、不再选名单。
struct RecordsSection: View {
    let session: RemoteSession
    let state: RemoteState

    var body: some View {
        if state.settings != nil { // 第 3 期的接口，旧版桌面端没有
            Section("记录") {
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
