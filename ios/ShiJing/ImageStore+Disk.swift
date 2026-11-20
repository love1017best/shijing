import Foundation
import ImageIO
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// MARK: - 磁盘缓存、占用统计与图片解码

extension ImageStore {
    /// 手机上存着的那张原图（离线时存相册 / 分享、预览兜底用）。
    nonisolated static func cachedOriginal(macID: String, name: String) -> URL? {
        guard let f = diskFile(macID, name, .original), FileManager.default.fileExists(atPath: f.path) else { return nil }
        return f
    }

    /// 壁纸列表变了：删掉这台 Mac 目录里不在这批里的缓存，并顺手清掉旧版本留在根目录的平铺文件。
    /// 按 Mac 分目录、按文件名认：切换 Mac 不互相清，同一张图换了批还在。
    nonisolated static func keepOnly(macID: String, names: [String]) {
        let fm = FileManager.default
        if let dir = diskDir(for: macID) {
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
        // 升级前缓存平铺在 images/ 根目录，清理普通文件但不动其他 Mac 的子目录
        purgeLegacyRootFiles()
    }

    /// 清理旧版本留在 images/ 根目录的平铺缓存文件，不动各台 Mac 的子目录。
    nonisolated static func purgeLegacyRootFiles() {
        guard let root = rootDiskDir else { return }
        let fm = FileManager.default
        let rootItems = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for u in rootItems {
            let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if !isDir { try? fm.removeItem(at: u) }
        }
    }

    /// 清理此前异常退出可能残留在 tmp/originals/ 里的过期临时原图（超过 1 分钟未修改）。
    nonisolated static func purgeStaleTempOriginals() {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "originals", directoryHint: .isDirectory)
        let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let cutoff = Date().addingTimeInterval(-60)
        for u in items {
            let mtime = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if mtime < cutoff { try? fm.removeItem(at: u) }
        }
    }

    /// 列出某台 Mac 缓存目录里已有的文件名集合（单次列目录，供后台缓存跳过已存文件）。
    nonisolated static func existingFileNames(for macID: String) -> Set<String> {
        guard let dir = diskDir(for: macID) else { return [] }
        return Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
    }

    /// 某一档缓存的统计。
    struct KindUsage {
        var bytes: Int64 = 0 // 这一档占了多少
        var count = 0        // 目录里有几个文件
        var inBatch = 0      // 这一批里有多少张有这一档
    }

    /// 设置页、补齐要的磁盘统计：列一次目录、每张图 stat 一次，各档一起算出来。
    /// （以前分别调 diskUsage / cachedSize / viewableCount / cachedCount，一次刷新要列四遍目录）
    struct Usage {
        var used: Int64 = 0      // 这台 Mac 的缓存目录占了多少
        var totalUsed: Int64 = 0 // 全部 Mac 缓存目录合计占了多少（与缓存上限同口径）
        var viewable = 0         // 这一批里离线能看到大图的张数（有大图或原图都算）
        var kinds: [ImageKind: KindUsage] = [:]

        func data(_ kind: ImageKind) -> KindUsage { kinds[kind] ?? KindUsage() }
    }

    nonisolated static func usage(macID: String, names: [String]) -> Usage {
        let fm = FileManager.default
        var u = Usage()
        var present: [ImageKind: Set<String>] = [:]
        if let dir = diskDir(for: macID) {
            let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            for f in items {
                let n = f.lastPathComponent
                let size = Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                u.used += size
                guard let kind = ImageKind.allCases.first(where: { n.hasPrefix($0.cachePrefix + "-") }) else { continue }
                var d = u.kinds[kind] ?? KindUsage()
                d.bytes += size
                d.count += 1
                u.kinds[kind] = d
                present[kind, default: []].insert(n)
            }
        }
        // 加上其他 Mac 子目录的占用，确保设置页「已用 / 上限」与后台缓存上限口径一致
        var total = u.used
        if let root = rootDiskDir {
            let currentName = safeName(macID)
            let topItems = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for sub in topItems where sub.lastPathComponent != currentName {
                let isDir = (try? sub.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir { total += directorySize(sub) }
            }
        }
        u.totalUsed = total
        // 这一批里每档存了多少张（文件名对得上才算）
        let imageName = ImageKind.image.cachePrefix + "-"
        let originalName = ImageKind.original.cachePrefix + "-"
        for name in names {
            let s = safeName(name)
            for kind in ImageKind.allCases where present[kind]?.contains(kind.cachePrefix + "-" + s) == true {
                var d = u.kinds[kind] ?? KindUsage()
                d.inBatch += 1
                u.kinds[kind] = d
            }
            // 离线能看到大图的：有 2732 宽的预览图或者原图都算（原图能本地缩出来）
            if present[.image]?.contains(imageName + s) == true || present[.original]?.contains(originalName + s) == true {
                u.viewable += 1
            }
        }
        return u
    }

    /// 整个图片缓存目录（所有 Mac 子目录合计）占了多少磁盘空间，补齐前用来对比全局缓存上限。
    /// 仅统计各 Mac 子目录，不把旧版可能残留的根目录散落文件算进去。
    nonisolated static func totalDiskUsage() -> Int64 {
        guard let root = rootDiskDir else { return 0 }
        let fm = FileManager.default
        let topItems = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var total: Int64 = 0
        for sub in topItems {
            let isDir = (try? sub.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir { total += directorySize(sub) }
        }
        return total
    }

    private nonisolated static func directorySize(_ dir: URL) -> Int64 {
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else {
            return 0
        }
        var total: Int64 = 0
        for f in items {
            guard let vals = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  vals.isRegularFile == true else { continue }
            total += Int64(vals.fileSize ?? 0)
        }
        return total
    }

    /// 清掉某台 Mac 的缓存（内存里的一起）。默认清除该 Mac 全部四档并移除目录。
    /// 下次连上电脑会从队列第一项开始慢慢补回来。
    func clear(macID: String, _ kinds: [ImageKind] = ImageKind.allCases) {
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
        let clearAll = kinds.count == ImageKind.allCases.count
        let prev = clearTask
        clearGen &+= 1
        clearTask = Task.detached(priority: .utility) {
            _ = await prev?.value
            if clearAll {
                if let dir = Self.diskDir(for: macID) {
                    try? FileManager.default.removeItem(at: dir)
                }
                Self.purgeLegacyRootFiles()
            } else {
                for kind in kinds { Self.removeFiles(macID, kind) }
            }
        }
    }

    private nonisolated static func removeFiles(_ macID: String, _ kind: ImageKind) {
        guard let dir = diskDir(for: macID) else { return }
        let prefix = kind.cachePrefix + "-"
        let items = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for f in items where f.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: dir.appending(path: f))
        }
    }

    #if DEBUG
    /// 截图用（-demo -demoOffline）：把演示图写进磁盘缓存，
    /// 验证「离线时从磁盘读图」这条路径真的能走通。
    func seedDiskCache(macID: String, names: [String], hero: String?) {
        demo = false
        #if os(iOS) // NSImage 没有 jpegData，macOS 上的类型检查不用这段
        // 只种网格里看得见的那几张：这一步是同步的，种太多启动会卡好几秒
        for n in names {
            guard let img = Self.demoImage(n, large: false),
                  let data = img.jpegData(compressionQuality: 0.7) else { continue }
            Self.writeDisk(macID, n, .thumb, data)
        }
        if let hero, let img = Self.demoImage(hero, large: true),
           let data = img.jpegData(compressionQuality: 0.7) {
            Self.writeDisk(macID, hero, .hero, data)
        }
        // 设置 › 离线 › 大图那一行：只种几张，看有数字的样子
        for n in names.prefix(names.count / 3) {
            guard let img = Self.demoImage(n, large: true),
                  let data = img.jpegData(compressionQuality: 0.8) else { continue }
            Self.writeDisk(macID, n, .image, data)
        }
        // 设置 › 离线 › 原图那一行：种一半的「原图」，看有数字的样子
        for n in names.prefix(names.count / 2) {
            guard let img = Self.demoImage(n, large: true),
                  let data = img.jpegData(compressionQuality: 0.8) else { continue }
            Self.writeDisk(macID, n, .original, data)
        }
        #endif
    }
    #endif

    /// 缓存根目录：Application Support/拾景/images/<macID>/<种类>-<文件名>。
    nonisolated static var rootDiskDir: URL? { AppSupport.path("images") }

    nonisolated static func diskDir(for macID: String) -> URL? {
        guard !macID.isEmpty, let root = rootDiskDir else { return nil }
        return root.appending(path: safeName(macID), directoryHint: .isDirectory)
    }

    /// 文件名里可能带中文，直接用没问题，但 "/" 和 ":" 要换掉（不能做文件名）。
    nonisolated static func safeName(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
    }

    nonisolated static func diskFile(_ macID: String, _ name: String, _ kind: ImageKind) -> URL? {
        guard !name.isEmpty, let dir = diskDir(for: macID) else { return nil }
        return dir.appending(path: "\(kind.cachePrefix)-\(safeName(name))", directoryHint: .notDirectory)
    }

    nonisolated static func readDisk(_ macID: String, _ name: String, _ kind: ImageKind) -> Data? {
        guard let f = diskFile(macID, name, kind) else { return nil }
        return try? Data(contentsOf: f)
    }

    /// 磁盘上有没有这一档（只看文件在不不在，不读内容）。
    nonisolated static func onDisk(_ macID: String, _ name: String, _ kind: ImageKind) -> Bool {
        guard let f = diskFile(macID, name, kind) else { return false }
        return FileManager.default.fileExists(atPath: f.path)
    }

    nonisolated static func writeDisk(_ macID: String, _ name: String, _ kind: ImageKind, _ data: Data) {
        guard let f = diskFile(macID, name, kind) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: f, options: .atomic)
    }

    /// 在后台线程解码好，显示时不卡主线程。
    nonisolated static func decode(_ data: Data) -> PlatformImage? {
        #if os(iOS)
        return UIImage(data: data)?.preparingForDisplay()
        #else
        return NSImage(data: data)
        #endif
    }

    /// 按最长边缩小解码：设置里存过原图、但这一批的预览图还没缓存时，用原图缩到展示尺寸，
    /// 别整张解进内存（几千万像素的原图直接解码要几百 MB，还可能失败）。顺带按 EXIF 转正。
    nonisolated static func downsampleFile(_ url: URL, maxPixel: Int) -> PlatformImage? {
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
