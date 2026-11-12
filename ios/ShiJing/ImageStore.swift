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
/// 缩略图（360 宽）同步完一轮就整批预取，大图（2048 宽）看过哪张存哪张。
/// 换了一批（rev 变了）就把上一批的缓存目录整个删掉，不会越积越多。
@MainActor
final class ImageStore {
    static let shared = ImageStore()

    private let cache = NSCache<NSString, PlatformImage>()
    private var inflight: [String: Task<PlatformImage?, Never>] = [:]
    private var prefetchTask: Task<Void, Never>?
    /// 演示模式（Debug）：不请求网络，按文件名画一张渐变图
    var demo = false

    private init() {
        cache.countLimit = 400
        cache.totalCostLimit = 160 << 20
    }

    private func key(_ base: URL, _ name: String, _ kind: ImageKind) -> String {
        "\(base.absoluteString)|\(name)|\(kind.rawValue)"
    }

    /// 已经在内存里的图（不发请求）。
    func cached(_ session: RemoteSession, _ name: String, _ kind: ImageKind) -> PlatformImage? {
        guard let c = try? session.client() else { return nil }
        return cache.object(forKey: key(c.base, name, kind) as NSString)
    }

    func load(_ session: RemoteSession, _ name: String, _ kind: ImageKind) async -> PlatformImage? {
        guard let client = try? session.client() else { return nil }
        let k = key(client.base, name, kind)
        if let img = cache.object(forKey: k as NSString) { return img }
        if let t = inflight[k] { return await t.value }
        let demo = demo
        let rev = session.wallsRev ?? ""
        let t = Task<PlatformImage?, Never> {
            let data: Data?
            if demo {
                data = nil
            } else if let d = await Task.detached(priority: .userInitiated, operation: { Self.readDisk(rev, name, kind) }).value {
                data = d
            } else {
                data = try? await client.imageData(name, kind: kind)
                if let data {
                    let rev = rev, name = name, kind = kind
                    await Task.detached(priority: .utility) { Self.writeDisk(rev, name, kind, data) }.value
                }
            }
            return await Task.detached(priority: .userInitiated) {
                if demo { return Self.demoImage(name, large: kind.isLarge) }
                return data.flatMap(Self.decode)
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

    /// 把当前这批的缩略图（和横幅图）在后台整批存到磁盘：离线打开时网格里每张都能看。
    /// 换一批时调用（上一次的预取会被取消）。
    func prefetchThumbs(_ session: RemoteSession) {
        #if DEBUG
        if demo { return }
        #endif
        guard let client = try? session.client(), let rev = session.wallsRev, !rev.isEmpty else { return }
        prefetchTask?.cancel()
        // 缩略图整批都要（十几 MB）；横幅图单独一张大一点，也只取这一张
        var queue: [(String, ImageKind)] = session.walls.map { ($0.name, .thumb) }
        if let hero = session.heroName ?? session.walls.first?.name { queue.append((hero, .hero)) }
        prefetchTask = Task {
            await withTaskGroup(of: Void.self) { group in
                // 同时最多 3 张，别把手机的网络和解码占满
                for _ in 0..<3 {
                    guard !queue.isEmpty else { break }
                    let (n, kind) = queue.removeFirst()
                    group.addTask { await Self.prefetchOne(client, rev, n, kind) }
                }
                while await group.next() != nil {
                    if Task.isCancelled { group.cancelAll(); return }
                    guard !queue.isEmpty else { continue }
                    let (n, kind) = queue.removeFirst()
                    group.addTask { await Self.prefetchOne(client, rev, n, kind) }
                }
            }
        }
    }

    private nonisolated static func prefetchOne(_ client: APIClient, _ rev: String, _ name: String, _ kind: ImageKind) async {
        if readDisk(rev, name, kind) != nil { return }
        guard let data = try? await client.imageData(name, kind: kind) else { return }
        writeDisk(rev, name, kind, data)
    }

    /// 换了一批：把不属于这一批的缓存目录删掉。启动读到快照时不要调（那一批可能正是离线要看的）。
    nonisolated static func groom(keepRev: String) {
        guard let dir = diskDir, let keep = revFolder(keepRev) else { return }
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for u in items where u.lastPathComponent != keep {
            try? fm.removeItem(at: u)
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

    /// 清掉磁盘上的图片缓存（内存里的一起），下次连上电脑再慢慢补回来。
    func clearDiskCache() {
        cache.removeAllObjects()
        guard let dir = Self.diskDir else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    #if DEBUG
    /// 截图用（-demo -demoOffline）：把演示图按当前批次写进磁盘缓存，
    /// 验证「离线时从磁盘读图」这条路径真的能走通。
    func seedDiskCache(rev: String, names: [String], hero: String?) {
        demo = false
        #if os(iOS) // NSImage 没有 jpegData，macOS 上的类型检查不用这段
        for n in names {
            for kind in [ImageKind.thumb, .hero] {
                guard let img = Self.demoImage(n, large: kind.isLarge),
                      let data = img.jpegData(compressionQuality: 0.7) else { continue }
                Self.writeDisk(rev, n, kind, data)
            }
        }
        if let hero, let img = Self.demoImage(hero, large: true),
           let data = img.jpegData(compressionQuality: 0.7) {
            Self.writeDisk(rev, hero, .hero, data)
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

    private nonisolated static func diskFile(_ rev: String, _ name: String, _ kind: ImageKind) -> URL? {
        guard let dir = diskDir, let folder = revFolder(rev) else { return nil }
        let safe = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return dir.appending(path: folder, directoryHint: .isDirectory)
            .appending(path: "\(kind.rawValue)-\(safe)", directoryHint: .notDirectory)
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

    var body: some View {
        ZStack {
            if let img = image ?? fallback {
                Image(platformImage: img)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Rectangle().fill(.quaternary)
                ProgressView()
            }
        }
        .task(id: wall.name) {
            image = ImageStore.shared.cached(session, wall.name, kind)
            if image == nil {
                image = await ImageStore.shared.load(session, wall.name, kind)
            }
        }
    }

    /// 大图还没到时先用缩略图垫着。
    private var fallback: PlatformImage? {
        guard kind.isLarge else { return nil }
        return ImageStore.shared.cached(session, wall.name, kind == .image ? .hero : .image)
            ?? ImageStore.shared.cached(session, wall.name, .thumb)
    }
}
