import Foundation

#if DEBUG
// MARK: - 演示模式（只在 Debug 构建里）：启动参数带 -demo / -demoRunning 时不连真的 Mac，
// 直接显示一份假状态，用来在模拟器里截图检查布局。
extension RemoteSession {
    static var demoMode: String? {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-demoRunning") { return "running" }
        return args.contains("-demo") || args.contains("-demoPreview") ? "idle" : nil
    }

    static func demo(_ mode: String, store: MacStore) -> RemoteSession {
        let mac = SavedMac(name: "演示 Mac", serviceName: nil, host: "192.168.1.20", port: 52819)
        let s = RemoteSession(mac: mac, store: store)
        let running = mode == "running"
        let now = Date().timeIntervalSince1970
        s.state = RemoteState(
            version: "0.3.7", eyebrow: running ? "正在换壁纸" : "当前壁纸 · 11月11日 15:04 换上",
            title: running ? "正在拾一批新风景…" : "已换上 300 张新壁纸",
            running: running, stopping: false, steps: ["filter", "scan", "copy", "refresh"],
            stage: running ? "copy" : nil, done: running ? 128 : 0, total: running ? 300 : 0,
            fraction: running ? 128.0 / 300 : -1, label: running ? "复制 128 / 300 张 · 还剩约 1 分钟" : nil,
            lastLine: running ? "[风景/冰岛] ✅ 已复制: 风景-冰岛-0423.jpg" : nil,
            runDelete: true, rejected: 3, deleted: 3, deleteFailed: 0,
            blocked: nil, unmounted: 0, willDelete: true,
            deleteNote: "会先检查「筛选 + 采样」里的 2 个目录，把竖屏、正方形和低于 3840×2160 的图片从图库里直接删除，不可撤销。",
            last: running ? nil : LastRun(at: now - 3600, status: "ok", error: nil, selected: 300, copied: 300, failed: 0,
                                         elapsed: 73, brief: "重合 4% · 删 3 张",
                                         detail: "和上一轮相比：新换上 288 张，重复 12 张（重合率 4%）\n筛选删除 3 张\n覆盖 300 / 415 个文件夹"),
            nextAuto: now + 6 * 3600, wallpapers: 300, wallsRev: "demo", dest: "~/Pictures/Wallpapers0", sampleCount: 300, libraryDirs: 3)
        s.state?.settings = RemoteSettings(sampleCount: 300, autoRunHours: 6, autoOptions: [0, 6, 12, 24, 168],
                                           deleteDuringFilter: true, preferUnseen: true, refreshWallpaper: true)
        s.state?.undoName = running ? nil : "风景-京都-0012.jpg"
        s.state?.excluded = 12
        // 截图用：-demoPending 摆出「图库没连上，删除原图在电脑上排队」的样子
        if ProcessInfo.processInfo.arguments.contains("-demoPending") { s.state?.pending = 2 }
        s.connection = .live
        let places = ["冰岛", "阿尔卑斯", "京都", "黄石", "新西兰", "巴塔哥尼亚", "挪威", "托斯卡纳", "大理", "落基山"]
        s.walls = (0..<300).map { i in
            Wallpaper(name: "风景-\(places[i % places.count])-\(String(format: "%04d", i)).jpg",
                      source: i % 7 == 6 ? nil : "/Volumes/Media0/风景/\(places[i % places.count])/\(String(format: "%04d", i)).jpg")
        }
        s.wallsRev = "demo"
        s.heroName = s.walls.first?.name // 和真的桌面一样给一张横幅图
        // 截图用：-demoQueue 在连着的状态下摆出「待补操作」（含待确认删除原图）和概览上的提醒
        if ProcessInfo.processInfo.arguments.contains("-demoQueue") { s.seedQueuedForDemo() }
        // 截图用：-demo -demoOffline 显示「离线，显示的是上次同步的壁纸」的样子
        if ProcessInfo.processInfo.arguments.contains("-demoOffline") {
            s.connection = .offline("连不上这台 Mac：确认它没有睡眠、拾景开着并打开了「允许手机遥控」，手机和电脑在同一个网络里。")
            s.snapshotAt = Date().addingTimeInterval(-3 * 3600 - 2400)
            // 顺便把演示图写进磁盘缓存，让「离线也能看图」这条路径真的走一遍（读的是磁盘，不是内存里的演示图）
            ImageStore.shared.seedDiskCache(rev: "demo", names: s.walls.prefix(24).map(\.name), hero: s.heroName)
            s.seedQueuedForDemo()
            // 记录页：存一份演示数据，断线时记录页显示的就是它
            let at = Date().addingTimeInterval(-3 * 3600 - 2400)
            OfflineStore.shared.saveRecord(mac.id.uuidString, .log, [
                "[风景/冰岛] ✅ 已复制: 风景-冰岛-0423.jpg",
                "[风景/京都] ✅ 已复制: 风景-京都-0011.jpg",
                "[筛选] 风景/落基山 没有变化，跳过 12 个文件夹",
            ], at: at)
            OfflineStore.shared.saveRecord(mac.id.uuidString, .deletions, DeletionList(
                total: 3, filter: 2, manual: 1,
                items: [
                    Deletion(at: now - 3600, name: "0163.jpg", dir: "/Volumes/Media0/风景/京都", reason: "竖屏"),
                    Deletion(at: now - 4000, name: "0288.jpg", dir: "/Volumes/Media0/风景/冰岛", reason: "分辨率不足"),
                    Deletion(at: now - 86400, name: "0512.jpg", dir: "/Volumes/Media0/风景/阿尔卑斯", reason: "手动删除"),
                ]), at: at)
            OfflineStore.shared.saveRecord(mac.id.uuidString, .excluded, [
                ExcludedItem(path: "/Volumes/Media0/风景/京都/0163.jpg", display: "~/Media0/风景/京都/0163.jpg"),
                ExcludedItem(path: "/Volumes/Media0/风景/大理/0077.jpg", display: "~/Media0/风景/大理/0077.jpg"),
            ], at: at)
        } else {
            ImageStore.shared.demo = true
        }
        return s
    }
}
#endif
