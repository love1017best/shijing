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
/// 下载下来的图还会按批次（`walls_rev`）写到磁盘，连不上 Mac 时图片也还看得见：
/// 缩略图（360 宽）、横幅（1600 宽）和整批大图（2732 宽）同步完一轮就在后台预取，受「缓存上限」限制（默认 10 GB）。
/// 换了一批（rev 变了）就把上一批的缓存目录整个删掉，不会越积越多。
///
/// 另外设置里可以手动「保存原图」（`prefetchOriginals`）：把图库里那一份原始文件也存到手机上，
/// 离线时能看原图、直接存相册 / 分享；单独算进度，可以暂停、清除，换批时和预览图一起删。
@MainActor
@Observable
final class ImageStore {
    static let shared = ImageStore()

    private let cache = NSCache<NSString, PlatformImage>()
    private var inflight: [String: Task<PlatformImage?, Never>] = [:]
    private var prefetchTask: Task<Void, Never>?
    /// 每一轮预取一个编号：旧的那轮被取消后收尾时，别把新一轮的「正在缓存」标志清掉
    private var prefetchGen = 0
    /// 演示模式（Debug）：不请求网络，按文件名画一张渐变图
    var demo = false

    // 整批缓存（设置页显示）
    private(set) var prefetching = false
    private(set) var prefetchDone = 0
    private(set) var prefetchTotal = 0
    /// 这一轮因为到了上限提前停了
    private(set) var prefetchHitLimit = false
    /// 用户手动暂停了整批缓存
    private(set) var prefetchPaused = false

    // 原图缓存（设置 › 离线 › 原图，手动补齐）
    private var originalTask: Task<Void, Never>?
    private var originalGen = 0
    private(set) var originaling = false
    private(set) var originalDone = 0
    private(set) var originalTotal = 0
    private(set) var originalHitLimit = false
    private(set) var originalPaused = false

    /// 缓存上限（GB），存在手机上，和电脑上的设置无关
    nonisolated static let cacheLimitKey = "offlineCacheLimitGB"
    nonisolated static let defaultCacheLimitGB = 10
    /// 设置里「保存原图」的开关（默认关，手动点「补齐原图」才开始下载）
    nonisolated static let cacheOriginalsKey = "cacheOriginals"

    /// 打开了「保存原图」：换了一批、重新连上时自动跟着补齐原图。
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

    /// `rev` 不传时按当前这一批（session.wallsRev）；「待补操作」里那些记下时属于上一批的条目要传自己那批的 rev。
    func load(_ session: RemoteSession, _ name: String, _ kind: ImageKind, rev revOverride: String? = nil) async -> PlatformImage? {
        let k = key(session, name, kind)
        if let img = cache.object(forKey: k as NSString) { return img }
        if let t = inflight[k] { return await t.value }
        let demo = demo
        let offline = session.offline
        let rev = revOverride ?? session.wallsRev ?? ""
        let client = try? session.client()
        let t = Task<PlatformImage?, Never> {
            var data: Data?
            var original: URL?
            var originalWidth = 0
            if demo {
                data = nil
            } else if let d = await Task.detached(priority: .userInitiated, operation: { Self.readDisk(rev, name, kind) }).value {
                data = d
            } else if let w = (offline || kind == .image) ? kind.targetWidth : nil,
                      let f = ImageStore.cachedOriginal(rev: rev, name: name) {
                // 手机上存过这张的原图：大图不用再下载（离线时缩略图、横幅也拿原图缩）。
                // 在线时网格的缩略图还是照常下载，一张才几十 KB，从几十 MB 的原图现缩反而拖慢滚动
                original = f
                originalWidth = w
            } else if offline {
                data = nil // 连不上电脑：只认磁盘上缓存过的，别干等网络超时
            } else {
                data = try? await client?.imageData(name, kind: kind)
                if let data {
                    let rev = rev, name = name, kind = kind
                    await Task.detached(priority: .utility) { Self.writeDisk(rev, name, kind, data) }.value
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

    // MARK: 磁盘缓存

    /// 把当前这批的缩略图、横幅图和整批 2732 宽的预览图在后台存到磁盘：
    /// 离线打开时网格和大图都能看。上限按「缓存上限」算，到了就不再往后存。
    /// 换一批时调用（上一次的预取会被取消）；用户暂停过也照样重新开始（新一批了）。
    func prefetchAll(_ session: RemoteSession) {
        #if DEBUG
        if demo { return }
        #endif
        guard let client = try? session.client(), let rev = session.wallsRev, !rev.isEmpty else { return }
        prefetchTask?.cancel()
        prefetchGen += 1
        let gen = prefetchGen
        prefetchPaused = false
        prefetchHitLimit = false
        // 缩略图和横幅图排前面（十几 MB），网格里每张立刻有得看；再按上限存整批预览图
        var queue: [(String, ImageKind)] = session.walls.map { ($0.name, .thumb) }
        if let hero = session.heroName ?? session.walls.first?.name { queue.append((hero, .hero)) }
        queue.append(contentsOf: session.walls.map { ($0.name, .image) })
        prefetchTotal = session.walls.count // 进度按壁纸张数算（缩略图不算，它很快）
        prefetchDone = 0
        prefetching = true
        prefetchTask = Task {
            // 枚举整个缓存目录逐文件取大小，别在主线程做
            var used = await Task.detached(priority: .utility) { Self.diskUsage() }.value
            let limit = Self.cacheLimitBytes
            var pending = queue
            var hitLimit = false
            await withTaskGroup(of: (ImageKind, Int64).self) { group in
                // 同时最多 3 张，别把手机的网络和解码占满
                let workers = 3
                func addNext() -> Bool {
                    guard !pending.isEmpty, !hitLimit else { return false }
                    let (n, kind) = pending.removeFirst()
                    group.addTask { (kind, await Self.prefetchOne(client, rev, n, kind)) }
                    return true
                }
                for _ in 0..<workers where addNext() {}
                while let (kind, bytes) = await group.next() {
                    if Task.isCancelled {
                        group.cancelAll()
                        if gen == prefetchGen { prefetching = false }
                        return
                    }
                    if kind == .image { prefetchDone += 1 }
                    used += bytes
                    if used >= limit, !pending.isEmpty {
                        // 到了上限：手上这几张存完就停，后面的不存了
                        hitLimit = true
                        pending.removeAll()
                        prefetchHitLimit = true
                    }
                    _ = addNext()
                }
            }
            if gen == prefetchGen { prefetching = false }
        }
    }

    /// 暂停整批缓存（设置页）。再点「继续」会重新排队，已经存下的会跳过。
    func pausePrefetch() {
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetching = false
        prefetchPaused = true
    }

    /// 换了一批：先把旧的那一轮停掉，别让下载中的图写回马上要被删掉的目录。
    func stopForNewBatch() {
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetching = false
        originalTask?.cancel()
        originalTask = nil
        originaling = false
    }

    // MARK: 原图缓存（设置里手动触发）

    /// 把这一批壁纸的原文件（图库里那一份，不是 2732 宽的预览图）也存到手机上：
    /// 离线时能看原图、直接存相册 / 分享。只在设置里点「补齐原图」时跑，已经存下的会跳过；
    /// 受同一个「缓存上限」约束，到上限就停。
    func prefetchOriginals(_ session: RemoteSession) {
        #if DEBUG
        if demo { return }
        #endif
        guard let client = try? session.client(), let rev = session.wallsRev, !rev.isEmpty else { return }
        originalTask?.cancel()
        originalGen += 1
        let gen = originalGen
        originalPaused = false
        originalHitLimit = false
        originalDone = 0
        originalTotal = session.walls.count
        originaling = true
        let names = session.walls.map(\.name)
        originalTask = Task {
            // 已经存过的跳过（几百次 stat，别放主线程；别读文件内容，原图一张几十 MB）
            let pending = await Task.detached(priority: .utility) {
                names.filter { Self.cachedOriginal(rev: rev, name: $0) == nil }
            }.value
            originalDone = names.count - pending.count
            var used = await Task.detached(priority: .utility) { Self.diskUsage() }.value
            let limit = Self.cacheLimitBytes
            var queue = pending
            var hitLimit = false
            await withTaskGroup(of: Int64.self) { group in
                // 原图一张几十 MB，同时最多 2 张
                let workers = 2
                func addNext() -> Bool {
                    guard !queue.isEmpty, !hitLimit else { return false }
                    let n = queue.removeFirst()
                    group.addTask { await Self.prefetchOriginal(client, rev, n) }
                    return true
                }
                for _ in 0..<workers where addNext() {}
                while let bytes = await group.next() {
                    if Task.isCancelled {
                        group.cancelAll()
                        if gen == originalGen { originaling = false }
                        return
                    }
                    originalDone += 1
                    used += bytes
                    if used >= limit, !queue.isEmpty {
                        hitLimit = true
                        queue.removeAll()
                        originalHitLimit = true
                    }
                    _ = addNext()
                }
            }
            if gen == originalGen { originaling = false }
        }
    }

    /// 暂停补齐原图（设置页）。再点「补齐原图」会接着存，已有的跳过。
    func pauseOriginals() {
        originalTask?.cancel()
        originalTask = nil
        originaling = false
        originalPaused = true
    }

    /// 清除这一批已经存下的原图（预览图缓存不动）。
    func clearOriginals(rev: String?) {
        originalTask?.cancel()
        originalTask = nil
        originalGen += 1
        originaling = false
        originalPaused = false
        originalHitLimit = false
        originalDone = 0
        originalTotal = 0
        guard let rev else { return }
        Task.detached(priority: .utility) {
            Self.removeFiles(rev: rev, prefix: ImageKind.original.cachePrefix + "-")
        }
    }

    private nonisolated static func prefetchOriginal(_ client: APIClient, _ rev: String, _ name: String) async -> Int64 {
        guard let f = diskFile(rev, name, .original) else { return 0 }
        if FileManager.default.fileExists(atPath: f.path) { return 0 }
        guard let tmp = try? await client.downloadOriginal(name) else { return 0 }
        defer { try? FileManager.default.removeItem(at: tmp) } // 移进缓存成功后这个文件已经不在了
        if Task.isCancelled { return 0 } // 换批了：上一批的原图不用留，马上会跟着旧目录一起删
        let fm = FileManager.default
        try? fm.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? fm.moveItem(at: tmp, to: f)) != nil else { return 0 }
        return Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    /// 手机上存着的那张原图（离线时存相册 / 分享、预览兜底用）。
    nonisolated static func cachedOriginal(rev: String, name: String) -> URL? {
        guard !rev.isEmpty, let f = diskFile(rev, name, .original),
              FileManager.default.fileExists(atPath: f.path) else { return nil }
        return f
    }

    /// 磁盘上这一批某种图占了多少（设置页显示原图占用）。
    nonisolated static func cachedSize(rev: String, kind: ImageKind) -> Int64 {
        guard let dir = diskDir, let folder = revFolder(rev) else { return 0 }
        let path = dir.appending(path: folder, directoryHint: .isDirectory)
        let prefix = kind.cachePrefix + "-"
        let items = (try? FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        var total: Int64 = 0
        for u in items where u.lastPathComponent.hasPrefix(prefix) {
            total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    private nonisolated static func removeFiles(rev: String, prefix: String) {
        guard let dir = diskDir, let folder = revFolder(rev) else { return }
        let path = dir.appending(path: folder, directoryHint: .isDirectory)
        let items = (try? FileManager.default.contentsOfDirectory(atPath: path.path)) ?? []
        for f in items where f.hasPrefix(prefix) {
            try? FileManager.default.removeItem(atPath: path.appending(path: f).path)
        }
    }

    private nonisolated static func prefetchOne(_ client: APIClient, _ rev: String, _ name: String, _ kind: ImageKind) async -> Int64 {
        if readDisk(rev, name, kind) != nil { return 0 }
        // 手机上存过这张的原图：大图能本地缩出来，不用再下载（省流量）。缩略图、横幅太小，照常下
        if kind == .image, cachedOriginal(rev: rev, name: name) != nil { return 0 }
        guard let data = try? await client.imageData(name, kind: kind) else { return 0 }
        if Task.isCancelled { return 0 } // 换批了：这份属于上一批，别写回去
        writeDisk(rev, name, kind, data)
        return Int64(data.count)
    }

    /// 壁纸列表变了：把不属于这一批的缓存目录清掉。
    /// 名字还在这批里的文件搬到新批次的目录下（移出一两张不用整批重下），其余删掉。
    nonisolated static func groom(keepRev: String, names: [String]) {
        guard let dir = diskDir, let keep = revFolder(keepRev) else { return }
        let fm = FileManager.default
        let keepFolder = dir.appending(path: keep, directoryHint: .isDirectory)
        try? fm.createDirectory(at: keepFolder, withIntermediateDirectories: true)
        let prefixes = ImageKind.allCases.map { $0.cachePrefix + "-" }
        let wanted = Set(names.map { safeName($0) })
        let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for u in items where u.lastPathComponent != keep {
            for f in (try? fm.contentsOfDirectory(atPath: u.path)) ?? [] {
                let src = u.appending(path: f)
                if let prefix = prefixes.first(where: { f.hasPrefix($0) }),
                   wanted.contains(String(f.dropFirst(prefix.count))) {
                    let dest = keepFolder.appending(path: f)
                    if !fm.fileExists(atPath: dest.path) {
                        try? fm.moveItem(at: src, to: dest) // 同名同前缀的图，内容一样，搬过来接着用
                        continue
                    }
                }
                try? fm.removeItem(at: src)
            }
            try? fm.removeItem(at: u)
        }
        // 留下的这一批里，旧前缀的文件（比如以前 2048 宽的大图）也删掉，别白占空间
        for f in (try? fm.contentsOfDirectory(atPath: keepFolder.path)) ?? [] where !f.hasPrefix(".") {
            if !prefixes.contains(where: { f.hasPrefix($0) }) {
                try? fm.removeItem(at: keepFolder.appending(path: f))
            }
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

    /// 磁盘上这一批已经存了多少张某种图（设置页显示进度用）。
    nonisolated static func cachedCount(rev: String, kind: ImageKind) -> Int {
        guard let dir = diskDir, let folder = revFolder(rev) else { return 0 }
        let path = dir.appending(path: folder, directoryHint: .isDirectory).path
        let prefix = kind.cachePrefix + "-"
        let items = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return items.filter { $0.hasPrefix(prefix) }.count
    }

    /// 这一批里离线能看到大图的张数：有 2732 宽的预览图或者原图都算（原图能本地缩出来）。
    nonisolated static func viewableCount(rev: String, names: [String]) -> Int {
        guard let dir = diskDir, let folder = revFolder(rev) else { return 0 }
        let path = dir.appending(path: folder, directoryHint: .isDirectory).path
        let files = Set((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [])
        let imagePrefix = ImageKind.image.cachePrefix + "-"
        let originalPrefix = ImageKind.original.cachePrefix + "-"
        return names.reduce(0) { n, name in
            let s = safeName(name)
            return n + (files.contains(imagePrefix + s) || files.contains(originalPrefix + s) ? 1 : 0)
        }
    }

    /// 清掉这一批的预览图（缩略图、横幅、2732 宽的大图），内存里的一起。
    /// 原图缓存和离线快照不动（原图在设置里单独清）。下次连上电脑会慢慢补回来。
    func clearPreviews(rev: String?) {
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchGen += 1
        prefetching = false
        prefetchPaused = false
        prefetchHitLimit = false
        prefetchDone = 0
        prefetchTotal = 0
        cache.removeAllObjects()
        guard let rev else { return }
        // 几百张图，别在主线程删
        Task.detached(priority: .utility) {
            for kind in [ImageKind.thumb, .hero, .image] {
                Self.removeFiles(rev: rev, prefix: kind.cachePrefix + "-")
            }
        }
    }

    #if DEBUG
    /// 截图用（-demo -demoOffline）：把演示图按当前批次写进磁盘缓存，
    /// 验证「离线时从磁盘读图」这条路径真的能走通。
    func seedDiskCache(rev: String, names: [String], hero: String?) {
        demo = false
        #if os(iOS) // NSImage 没有 jpegData，macOS 上的类型检查不用这段
        // 只种网格里看得见的那几张：这一步是同步的，种太多启动会卡好几秒
        for n in names {
            guard let img = Self.demoImage(n, large: false),
                  let data = img.jpegData(compressionQuality: 0.7) else { continue }
            Self.writeDisk(rev, n, .thumb, data)
        }
        if let hero, let img = Self.demoImage(hero, large: true),
           let data = img.jpegData(compressionQuality: 0.7) {
            Self.writeDisk(rev, hero, .hero, data)
        }
        // 设置 › 离线 › 原图那一行：种一半的「原图」，看有数字的样子
        for n in names.prefix(names.count / 2) {
            guard let img = Self.demoImage(n, large: true),
                  let data = img.jpegData(compressionQuality: 0.8) else { continue }
            Self.writeDisk(rev, n, .original, data)
        }
        #endif
    }
    #endif

    /// 缓存目录：Application Support/拾景/images/<批次的哈希>/<种类>-<文件名>。
    /// 按批次分目录，换一批整个删；文件名里可能带中文，直接用没问题，但 "/" 要换掉。
    private nonisolated static var diskDir: URL? {
        let fm = FileManager.default
        guard let base = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        else { return nil }
        return base.appending(path: "拾景/images", directoryHint: .isDirectory)
    }

    private nonisolated static func revFolder(_ rev: String) -> String? {
        var h: UInt64 = 1469598103934665603
        for b in rev.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return String(format: "%016llx", h)
    }

    /// 文件名里可能带中文，直接用没问题，但 "/" 和 ":" 要换掉（不能做文件名）。
    private nonisolated static func safeName(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
    }

    private nonisolated static func diskFile(_ rev: String, _ name: String, _ kind: ImageKind) -> URL? {
        guard let dir = diskDir, let folder = revFolder(rev) else { return nil }
        return dir.appending(path: folder, directoryHint: .isDirectory)
            .appending(path: "\(kind.cachePrefix)-\(safeName(name))", directoryHint: .notDirectory)
    }

    private nonisolated static func readDisk(_ rev: String, _ name: String, _ kind: ImageKind) -> Data? {
        guard let f = diskFile(rev, name, kind) else { return nil }
        return try? Data(contentsOf: f)
    }

    private nonisolated static func writeDisk(_ rev: String, _ name: String, _ kind: ImageKind, _ data: Data) {
        guard let f = diskFile(rev, name, kind) else { return }
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
    /// 传了就用这一批的缓存（「待补操作」里上一批的条目）；不传按当前批次
    var rev: String?
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
        .task(id: wall.name + (session.offline ? "|offline" : "|online") + "|\(rev ?? "")|\(retry)") {
            image = ImageStore.shared.cached(session, wall.name, kind)
            if image == nil {
                image = await ImageStore.shared.load(session, wall.name, kind, rev: rev)
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
