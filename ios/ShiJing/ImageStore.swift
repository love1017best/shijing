import SwiftUI

#if os(iOS)
import UIKit
typealias PlatformImage = UIImage
#else
import AppKit
typealias PlatformImage = NSImage
#endif

/// 壁纸图片的内存缓存和加载：同一张同时只请求一次，缩略图和大图分开存。
@MainActor
final class ImageStore {
    static let shared = ImageStore()

    private let cache = NSCache<NSString, PlatformImage>()
    private var inflight: [String: Task<PlatformImage?, Never>] = [:]
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
        let t = Task<PlatformImage?, Never> {
            let data: Data?
            if demo {
                data = nil
            } else {
                data = try? await client.imageData(name, kind: kind)
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
