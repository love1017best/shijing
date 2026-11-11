import AppIntents

/// 不用自己建快捷指令就能用：Siri 说「用拾景换一批壁纸」、操作按钮、聚焦搜索里都能直接找到。
struct ShiJingShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: RunWallpaperIntent(), phrases: [
            "用\(.applicationName)换一批壁纸",
            "\(.applicationName)换一批",
            "\(.applicationName)换壁纸",
        ], shortTitle: "换一批壁纸", systemImageName: "shuffle")
        AppShortcut(intent: WallpaperStatusIntent(), phrases: [
            "\(.applicationName)壁纸状态",
            "\(.applicationName)现在怎么样",
        ], shortTitle: "壁纸状态", systemImageName: "photo.on.rectangle")
        AppShortcut(intent: StopWallpaperIntent(), phrases: [
            "\(.applicationName)停止换壁纸",
        ], shortTitle: "停止换壁纸", systemImageName: "stop.circle")
    }
}
