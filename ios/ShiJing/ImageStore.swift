import ImageIO
import SwiftUI

#if os(iOS)
import UIKit
typealias PlatformImage = UIImage
#else
import AppKit
typealias PlatformImage = NSImage
#endif

/// 壁纸图片的内存缓存和加载：同一张同时只请求一次，缩略图和大图分开存。
///
/// 下载下来的图还会写到磁盘，连不上 Mac 时图片也还看得见。缓存**不分批次**：一个目录，
/// 每张壁纸按文件名存几份（`thumb-` 360 宽、`hero-` 1600、`image2732-` 2732、`original-` 原文件），
/// 壁纸列表变了就删掉不在这批里的——同一张图换了批还在，不用重下。
///
/// 后台缓存是一个队列：缩略图 → 横幅 → 整批大图 →（开了「保存原图」时）原图，一个「缓存上限」卡着。
@MainActor
@Observable
final class ImageStore {
    static let shared = ImageStore()

    private let cache = NSCache<NSString, PlatformImage>()
    private var inflight: [String: Task<PlatformImage?, Never>] = [:]
    private var task: Task<Void, Never>?
    /// 每一轮一个编号：旧的那轮被取消后收尾时，别把新一轮的「正在缓存」标志清掉
    private var gen = 0
    /// 正在删缓存的磁盘操作：补齐之前要等它做完，否则 `diskUsage()` 会把还没删掉的文件算进「已用」
    private var clearTask: Task<Void, Never>?
    /// 演示模式（Debug）：不请求网络，按文件名画一张渐变图
    var demo = false

    // 后台缓存的状态（设置页显示）
    private(set) var prefetching = false
    /// 这一批已经存下来的大图张数（也就是「离线可看」的张数）
    private(set) var prefetchDone = 0
    /// 这一批的总张数（大图和原图各算这么多，不翻倍——用户按「一批多少张」理解）
    private(set) var prefetchTotal = 0
    /// 原图存了多少张（开了「保存原图」才有）
    private(set) var prefetchOriginalDone = 0
    /// 这一轮因为到了上限提前停了
    private(set) var prefetchHitLimit = false
    /// 用户手动暂停了
    private(set) var prefetchPaused = false

    /// 缓存上限（GB），存在手机上，和电脑上的设置无关
    nonisolated static let cacheLimitKey = "offlineCacheLimitGB"
    nonisolated static let defaultCacheLimitGB = 10
    /// 设置里「保存原图」的开关：打开后后台队列最后会把原文件也存下来，离线能存相册、分享原图
    nonisolated static let cacheOriginalsKey = "cacheOriginals"

    /// 打开了「保存原图」。
    nonisolated static var originalsEnabled: Bool {
        UserDefaults.standard.bool(forKey: cacheOriginalsKey)
    }

    /// 上限换成字节；没设过就是默认的 10 GB。
    nonisolated static var cacheLimitBytes: Int64 {
        let gb = UserDefaults.standard.integer(forKey: cacheLimitKey)
        return Int64(gb > 0 ? gb : defaultCacheLimitGB) * 1_000_000_000
    }

    private init() {
        cache.countLimit = 400
        cache.totalCostLimit = 160 << 20
        Self.prepareDiskDir()
    }

    /// 缓存目录建好并排除出 iCloud / 电脑备份：这里可能有十几 GB 的图，不该进备份。
    private nonisolated static func prepareDiskDir() {
        guard let dir = diskDir else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var u = dir
        var v = URLResourceValues()
        v.isExcludedFromBackup = true
        try? u.setResourceValues(v)
    }

    /// 内存缓存的 key。用 Mac 的 id 而不是地址或客户端：`session.client()` 要读钥匙串，
    /// 而 `cached` 在缩略图网格和预览的 body 里每帧都会被调用。
    private func key(_ session: RemoteSession, _ name: String, _ kind: ImageKind) -> String {
        "\(session.macID.uuidString)|\(name)|\(kind.rawValue)"
    }

    /// 已经在内存里的图（不发请求）。
    func cached(_ session: RemoteSession, _ name: String, _ kind: ImageKind) -> PlatformImage? {
        cache.object(forKey: key(session, name, kind) as NSString)
    }

    /// 读一张图：内存 → 磁盘 →（有原图就本地缩）→ 在线时下载并写盘。
    /// 连不上电脑时只认磁盘上有的，不干等网络超时。
    func load(_ session: RemoteSession, _ name: String, _ kind: ImageKind) async -> PlatformImage? {
        let k = key(session, name, kind)
        if let img = cache.object(forKey: k as NSString) { return img }
        if let t = inflight[k] { return await t.value }
        let demo = demo
        let offline = session.offline
        let client = try? session.client()
        let t = Task<PlatformImage?, Never> {
            var data: Data?
            var original: URL?
            var originalWidth = 0
            if demo {
                data = nil
            } else if let d = await Task.detached(priority: .userInitiated, operation: { Self.readDisk(name, kind) }).value {
                data = d
            } else if let w = (offline || kind == .image) ? kind.targetWidth : nil,
                      let f = ImageStore.cachedOriginal(name: name) {
                // 手机上存过这张的原图：大图不用再下载（离线时缩略图、横幅也拿原图缩）。
                // 在线时网格的缩略图还是照常下载，一张才几十 KB，从几十 MB 的原图现缩反而拖慢滚动
                original = f
                originalWidth = w
            } else if offline {
                data = nil // 连不上电脑：只认磁盘上缓存过的
            } else {
                data = try? await client?.imageData(name, kind: kind)
                if let data, !offline {
                    await Task.detached(priority: .utility) { Self.writeDisk(name, kind, data) }.value
                }
            }
            return await Task.detached(priority: .userInitiated) {
                if demo { return Self.demoImage(name, large: kind.isLarge) }
                if let original { return Self.downsampleFile(original, maxPixel: originalWidth) }
                guard let data else { return nil }
                return Self.decode(data)
            }.value
        }
        inflight[k] = t
        let img = await t.value
        inflight[k] = nil
        if let img {
            cache.setObject(img, forKey: k as NSString, cost: kind.isLarge ? 8 << 20 : 300 << 10)
        }
        return img
    }

    // MARK: 后台缓存

    /// 把这一批壁纸存到手机上：缩略图（网格立刻有得看）→ 横幅 → 整批 2732 宽的大图 →（开关开着）原图。
    /// 一个队列、一个上限，超了就不再往后存。换批、重新连上时调用；已经存下的会跳过。
    func prefetch(_ session: RemoteSession) {
        #if DEBUG
        if demo { return }
        #endif
        guard let client = try? session.client(), !session.walls.isEmpty else { return }
        task?.cancel()
        gen += 1
        let g = gen
        prefetchPaused = false
        prefetchHitLimit = false
        let names = session.walls.map(\.name)
        let wantOriginals = Self.originalsEnabled
        // 进度按壁纸算：这一批多少张就是多少（缩略图、横幅很小，不算；大图和原图各走一遍这个数）
        prefetchTotal = names.count
        prefetchDone = 0
        prefetchOriginalDone = 0
        prefetching = true
        task = Task {
            // 先等还在跑的删缓存做完，再量磁盘：不然「已用」把马上要删的文件也算进去
            if let clear = clearTask { await clear.value; clearTask = nil }
            var used = await Task.detached(priority: .utility) { Self.diskUsage() }.value
            let limit = Self.cacheLimitBytes
            var queue: [(String, ImageKind)] = names.map { ($0, .thumb) }
            if let hero = session.heroName ?? names.first { queue.append((hero, .hero)) }
            queue.append(contentsOf: names.map { ($0, .image) })
            if wantOriginals { queue.append(contentsOf: names.map { ($0, .original) }) }
            var next = 0
            var hitLimit = false
            await withTaskGroup(of: (ImageKind, Int64).self) { group in
                // 同时最多 3 张，别把手机的网络和解码占满
                let workers = 3
                func addNext() -> Bool {
                    guard next < queue.count, !hitLimit else { return false }
                    let (n, kind) = queue[next]
                    next += 1
                    group.addTask { (kind, await Self.fetchOne(client, n, kind)) }
                    return true
                }
                for _ in 0..<workers where addNext() {}
                while let (kind, bytes) = await group.next() {
                    if Task.isCancelled {
                        group.cancelAll()
                        if g == gen { prefetching = false }
                        return
                    }
                    // 进度按壁纸算：大图、原图各数各的，缩略图和横幅不算
                    if kind == .image { prefetchDone += 1 }
                    if kind == .original { prefetchOriginalDone += 1 }
                    used += bytes
                    if used >= limit, next < queue.count {
                        // 到了上限：手上这几张存完就停，后面的不存了
                        hitLimit = true
                        prefetchHitLimit = true
                    }
                    _ = addNext()
                }
            }
            if g == gen { prefetching = false }
        }
    }

    /// 暂停后台缓存（设置页）。再点「补齐」会重新排队，已经存下的会跳过。
    func pausePrefetch() {
        task?.cancel()
        task = nil
        prefetching = false
        prefetchPaused = true
    }

    /// 换了一批：先停掉下载中的任务（别让属于上一批的图写进来），由调用方接着 `keepOnly`。
    func stopForNewBatch() {
        task?.cancel()
        task = nil
        prefetching = false
    }

    /// 下载一张存到磁盘；已经有了就不动。返回写下的字节数。
    private nonisolated static func fetchOne(_ client: APIClient, _ name: String, _ kind: ImageKind) async -> Int64 {
        if readDisk(name, kind) != nil { return 0 }
        if kind == .image, cachedOriginal(name: name) != nil { return 0 } // 有原图能本地缩，不用再下
        if kind == .original, let f = diskFile(name, .original),
           FileManager.default.fileExists(atPath: f.path) { return 0 }
        if kind == .original {
            guard let tmp = try? await client.downloadOriginal(name) else { return 0 }
            defer { try? FileManager.default.removeItem(at: tmp) }
            if Task.isCancelled { return 0 }
            guard let f = diskFile(name, .original) else { return 0 }
            let fm = FileManager.default
            try? fm.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard (try? fm.moveItem(at: tmp, to: f)) != nil else { return 0 }
            return Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        guard let data = try? await client.imageData(name, kind: kind) else { return 0 }
        if Task.isCancelled { return 0 }
        writeDisk(name, kind, data)
        return Int64(data.count)
    }

    /// 手机上存着的那张原图（离线时存相册 / 分享、预览兜底用）。
    nonisolated static func cachedOriginal(name: String) -> URL? {
        guard let f = diskFile(name, .original), FileManager.default.fileExists(atPath: f.path) else { return nil }
        return f
    }

    /// 壁纸列表变了：删掉不在这批里的缓存。
    /// 按文件名认，不用分批次目录：同一张图换了批还在，省得整批重下。
    nonisolated static func keepOnly(names: [String]) {
        guard let dir = diskDir else { return }
        let fm = FileManager.default
        let prefixes = ImageKind.allCases.map { $0.cachePrefix + "-" }
        let wanted = Set(names.map { safeName($0) })
        let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for u in items {
            let f = u.lastPathComponent
            if let prefix = prefixes.first(where: { f.hasPrefix($0) }),
               wanted.contains(String(f.dropFirst(prefix.count))) { continue }
            try? fm.removeItem(at: u)
        }
    }

    /// 磁盘上某种图占了多少 / 有多少张（设置页显示）。
    nonisolated static func cachedSize(kind: ImageKind) -> Int64 {
        guard let dir = diskDir else { return 0 }
        let prefix = kind.cachePrefix + "-"
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        var total: Int64 = 0
        for u in items where u.lastPathComponent.hasPrefix(prefix) {
            total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    nonisolated static func cachedCount(kind: ImageKind) -> Int {
        guard let dir = diskDir else { return 0 }
        let prefix = kind.cachePrefix + "-"
        let items = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return items.filter { $0.hasPrefix(prefix) }.count
    }

    /// 这一批里离线能看到大图的张数：有 2732 宽的预览图或者原图都算（原图能本地缩出来）。
    nonisolated static func viewableCount(names: [String]) -> Int {
        guard let dir = diskDir else { return 0 }
        let files = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        let imagePrefix = ImageKind.image.cachePrefix + "-"
        let originalPrefix = ImageKind.original.cachePrefix + "-"
        return names.reduce(0) { n, name in
            let s = safeName(name)
            return n + (files.contains(imagePrefix + s) || files.contains(originalPrefix + s) ? 1 : 0)
        }
    }

    /// 磁盘上的图片缓存占了多少（设置页显示）。
    nonisolated static func diskUsage() -> Int64 {
        guard let dir = diskDir else { return 0 }
        let fm = FileManager.default
        guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in e {
            total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// 清掉缓存（内存里的一起）。传空就是全部清掉。
    /// 下次连上电脑会从队列第一项开始慢慢补回来。
    func clear(_ kinds: [ImageKind] = ImageKind.allCases) {
        task?.cancel()
        task = nil
        gen += 1
        prefetching = false
        prefetchPaused = false
        prefetchHitLimit = false
        prefetchDone = 0
        prefetchTotal = 0
        prefetchOriginalDone = 0
        cache.removeAllObjects()
        let prev = clearTask
        clearTask = Task.detached(priority: .utility) {
            _ = await prev?.value
            for kind in kinds { Self.removeFiles(kind) }
        }
    }

    private nonisolated static func removeFiles(_ kind: ImageKind) {
        guard let dir = diskDir else { return }
        let prefix = kind.cachePrefix + "-"
        let items = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for f in items where f.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: dir.appending(path: f))
        }
    }

    #if DEBUG
    /// 截图用（-demo -demoOffline）：把演示图写进磁盘缓存，
    /// 验证「离线时从磁盘读图」这条路径真的能走通。
    func seedDiskCache(names: [String], hero: String?) {
        demo = false
        #if os(iOS) // NSImage 没有 jpegData，macOS 上的类型检查不用这段
        // 只种网格里看得见的那几张：这一步是同步的，种太多启动会卡好几秒
        for n in names {
            guard let img = Self.demoImage(n, large: false),
                  let data = img.jpegData(compressionQuality: 0.7) else { continue }
            Self.writeDisk(n, .thumb, data)
        }
        if let hero, let img = Self.demoImage(hero, large: true),
           let data = img.jpegData(compressionQuality: 0.7) {
            Self.writeDisk(hero, .hero, data)
        }
        // 设置 › 离线 › 原图那一行：种一半的「原图」，看有数字的样子
        for n in names.prefix(names.count / 2) {
            guard let img = Self.demoImage(n, large: true),
                  let data = img.jpegData(compressionQuality: 0.8) else { continue }
            Self.writeDisk(n, .original, data)
        }
        #endif
    }
    #endif

    /// 缓存目录：Application Support/拾景/images/<种类>-<文件名>。
    /// 文件名里可能带中文，直接用没问题，但 "/" 要换掉。
    private nonisolated static var diskDir: URL? {
        let fm = FileManager.default
        guard let base = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        else { return nil }
        return base.appending(path: "拾景/images", directoryHint: .isDirectory)
    }

    /// 文件名里可能带中文，直接用没问题，但 "/" 和 ":" 要换掉（不能做文件名）。
    private nonisolated static func safeName(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
    }

    private nonisolated static func diskFile(_ name: String, _ kind: ImageKind) -> URL? {
        guard !name.isEmpty, let dir = diskDir else { return nil }
        return dir.appending(path: "\(kind.cachePrefix)-\(safeName(name))", directoryHint: .notDirectory)
    }

    private nonisolated static func readDisk(_ name: String, _ kind: ImageKind) -> Data? {
        guard let f = diskFile(name, kind) else { return nil }
        return try? Data(contentsOf: f)
    }

    private nonisolated static func writeDisk(_ name: String, _ kind: ImageKind, _ data: Data) {
        guard let f = diskFile(name, kind) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: f, options: .atomic)
    }

    /// 在后台线程解码好，显示时不卡主线程。
    private nonisolated static func decode(_ data: Data) -> PlatformImage? {
        #if os(iOS)
        return UIImage(data: data)?.preparingForDisplay()
        #else
        return NSImage(data: data)
        #endif
    }

    /// 按最长边缩小解码：设置里存过原图、但这一批的预览图还没缓存时，用原图缩到展示尺寸，
    /// 别整张解进内存（几千万像素的原图直接解码要几百 MB，还可能失败）。顺带按 EXIF 转正。
    private nonisolated static func downsampleFile(_ url: URL, maxPixel: Int) -> PlatformImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        #if os(iOS)
        return UIImage(cgImage: cg, scale: 1, orientation: .up)
        #else
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        #endif
    }

    /// 演示用的风景色块：按文件名挑颜色，上深下浅，画一道山的轮廓。
    nonisolated static func demoImage(_ name: String, large: Bool) -> PlatformImage? {
        #if os(iOS)
        var h: UInt32 = 2166136261
        for b in name.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        let hue = CGFloat(h % 360) / 360
        let size = large ? CGSize(width: 1600, height: 900) : CGSize(width: 360, height: 203)
        let r = UIGraphicsImageRenderer(size: size)
        return r.image { ctx in
            let cg = ctx.cgContext
            let top = UIColor(hue: hue, saturation: 0.55, brightness: 0.45, alpha: 1)
            let bottom = UIColor(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.35, brightness: 0.95, alpha: 1)
            let grad = CGGradient(colorsSpace: nil, colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1])!
            cg.drawLinearGradient(grad, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            let path = UIBezierPath()
            path.move(to: CGPoint(x: 0, y: size.height))
            let peaks = 3 + Int(h % 3)
            for i in 0...peaks * 2 {
                let x = size.width * CGFloat(i) / CGFloat(peaks * 2)
                let y = size.height * (i % 2 == 0 ? 0.78 : 0.45 + CGFloat((h >> UInt32(i)) % 20) / 100)
                path.addLine(to: CGPoint(x: x, y: y))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            UIColor(hue: hue, saturation: 0.5, brightness: 0.25, alpha: 0.85).setFill()
            path.fill()
        }
        #else
        return nil
        #endif
    }
}

extension Image {
    init(platformImage: PlatformImage) {
        #if os(iOS)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}

/// 一张壁纸图：先用内存里已有的（大图没好时先显示缩略图），没有就去加载。
struct WallImage: View {
    let session: RemoteSession
    let wall: Wallpaper
    var kind: ImageKind = .thumb
    var contentMode: ContentMode = .fill
    @State private var image: PlatformImage?
    /// 切回前台时重试一次（后台时正在下载的那张会被系统掐断，回来不然一直是灰的）
    @State private var retry = 0
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            if let img = image ?? fallback {
                Image(platformImage: img)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Rectangle().fill(.quaternary)
                if !session.offline { ProgressView() } // 离线时没有就是没有，别一直转圈
            }
        }
        .task(id: wall.name + (session.offline ? "|offline" : "|online") + "|\(retry)") {
            image = ImageStore.shared.cached(session, wall.name, kind)
            if image == nil {
                image = await ImageStore.shared.load(session, wall.name, kind)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, image == nil { retry += 1 }
        }
    }

    /// 大图还没到时先用缩略图垫着。
    private var fallback: PlatformImage? {
        guard kind.isLarge else { return nil }
        return ImageStore.shared.cached(session, wall.name, kind == .image ? .hero : .image)
            ?? ImageStore.shared.cached(session, wall.name, .thumb)
    }
}
