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

    private final class InflightLoad {
        let task: Task<PlatformImage?, Never>
        var waiters: Set<UUID> = []
        init(task: Task<PlatformImage?, Never>) {
            self.task = task
        }
    }

    let cache = NSCache<NSString, PlatformImage>()
    private var inflight: [String: InflightLoad] = [:]
    /// 前台图片加载并发上限：快速滑动网格时避免数十张图同时下载解码挤占连接与内存
    private let maxConcurrentLoads = 6
    private var activeLoads = 0
    private var loadWaiters: [(id: UUID, cont: CheckedContinuation<Bool, Never>)] = []
    var task: Task<Void, Never>?
    /// 每一轮一个编号：旧的那轮被取消后收尾时，别把新一轮的「正在缓存」标志清掉
    var gen = 0
    /// 正在删缓存的磁盘操作：补齐之前要等它做完，否则 `diskUsage()` 会把还没删掉的文件算进「已用」
    var clearTask: Task<Void, Never>?
    /// 每次启动或触发磁盘清理递增，避免旧的 `waitForClear` 清掉并发新创建的 `clearTask`
    var clearGen: UInt64 = 0
    /// 演示模式（Debug）：不请求网络，按文件名画一张渐变图
    var demo = false

    // 后台缓存的状态（设置页显示）
    var prefetching = false
    /// 这一批已经存下来的大图张数（设置页「大图缓存」那个数）
    var prefetchDone = 0
    /// 这一批的总张数（大图和原图各算这么多，不翻倍——用户按「一批多少张」理解）
    var prefetchTotal = 0
    /// 原图存了多少张（开了「保存原图」才有）
    var prefetchOriginalDone = 0
    /// 这一轮因为到了上限提前停了
    var prefetchHitLimit = false
    /// 用户手动暂停了
    var prefetchPaused = false

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
        AppSupport.prepare(Self.rootDiskDir)
        // 清理旧版本（v0.4.20 及以前）平铺在 images/ 根目录的缓存文件，
        // 以及此前异常退出可能留在 tmp/originals/ 的过期临时原图；
        // 挂到 clearTask 上让首次统计磁盘占用和后台缓存都等它删完再量。
        clearGen &+= 1
        clearTask = Task.detached(priority: .utility) {
            Self.purgeLegacyRootFiles()
            Self.purgeStaleTempOriginals()
        }
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

    /// 申请前台加载槽位；排队期间若调用方取消，立刻退出等待并返回 false。
    private func acquireLoadSlot() async -> Bool {
        if Task.isCancelled { return false }
        if activeLoads < maxConcurrentLoads {
            activeLoads += 1
            return true
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                if Task.isCancelled {
                    cont.resume(returning: false)
                    return
                }
                if activeLoads < maxConcurrentLoads {
                    activeLoads += 1
                    cont.resume(returning: true)
                    return
                }
                loadWaiters.append((id, cont))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelLoadWaiter(id)
            }
        }
    }

    private func cancelLoadWaiter(_ id: UUID) {
        guard let idx = loadWaiters.firstIndex(where: { $0.id == id }) else { return }
        let (_, cont) = loadWaiters.remove(at: idx)
        cont.resume(returning: false)
    }

    private func releaseLoadSlot() {
        if !loadWaiters.isEmpty {
            let (_, cont) = loadWaiters.removeFirst()
            cont.resume(returning: true)
            return
        }
        activeLoads = max(0, activeLoads - 1)
    }

    private func removeWaiter(key: String, entry: InflightLoad, waiterID: UUID) {
        if entry.waiters.remove(waiterID) != nil, entry.waiters.isEmpty {
            entry.task.cancel()
            if inflight[key] === entry { inflight[key] = nil }
        }
    }

    /// 读一张图：内存 → 磁盘 →（有原图就本地缩）→ 在线时下载并写盘。
    /// 连不上电脑时只认磁盘上有的，不干等网络超时；所有等待视图都取消时中止底层任务。
    func load(_ session: RemoteSession, _ name: String, _ kind: ImageKind) async -> PlatformImage? {
        let k = key(session, name, kind)
        if let img = cache.object(forKey: k as NSString) { return img }
        if Task.isCancelled { return nil }

        let entry: InflightLoad
        if let existing = inflight[k] {
            entry = existing
        } else {
            let demo = demo
            let macID = session.macID.uuidString
            let t = Task<PlatformImage?, Never> {
                guard await self.acquireLoadSlot() else { return nil }
                defer { self.releaseLoadSlot() }
                if Task.isCancelled { return nil }

                var data: Data?
                var original: URL?
                var originalWidth = 0
                let offline = session.offline
                if demo {
                    data = nil
                } else if let d = await Task.detached(priority: .userInitiated, operation: { Self.readDisk(macID, name, kind) }).value {
                    data = d
                } else if let w = (offline || kind == .image) ? kind.targetWidth : nil,
                          let f = ImageStore.cachedOriginal(macID: macID, name: name) {
                    // 手机上存过这张的原图：大图不用再下载（离线时缩略图、横幅也拿原图缩）。
                    // 在线时网格的缩略图还是照常下载，一张才几十 KB，从几十 MB 的原图现缩反而拖慢滚动
                    original = f
                    originalWidth = w
                } else if offline || session.offline {
                    data = nil // 连不上电脑或排队期间已断开：只认磁盘上缓存过的
                } else if let client = try? session.client() {
                    do {
                        let d = try await client.imageData(name, kind: kind)
                        data = d
                        if !Task.isCancelled {
                            await Task.detached(priority: .utility) { Self.writeDisk(macID, name, kind, d) }.value
                        }
                    } catch {
                        // 连不上电脑了：顺手把连接状态改成离线，别让后面每张图都各等一次超时
                        session.noteNetworkFailure(error)
                    }
                }
                if Task.isCancelled { return nil }
                let img = await Task.detached(priority: .userInitiated) { () -> PlatformImage? in
                    if Task.isCancelled { return nil }
                    if demo { return Self.demoImage(name, large: kind.isLarge) }
                    if let original { return Self.downsampleFile(original, maxPixel: originalWidth) }
                    guard let data else { return nil }
                    return Self.decode(data)
                }.value
                if let img {
                    self.cache.setObject(img, forKey: k as NSString, cost: Self.memoryCost(img))
                }
                return img
            }
            entry = InflightLoad(task: t)
            inflight[k] = entry
        }

        let waiterID = UUID()
        entry.waiters.insert(waiterID)
        let img = await withTaskCancellationHandler {
            await entry.task.value
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.removeWaiter(key: k, entry: entry, waiterID: waiterID)
            }
        }
        removeWaiter(key: k, entry: entry, waiterID: waiterID)
        return Task.isCancelled ? nil : img
    }

    /// 一张图在内存里占多少，按解码后的像素算：2732 宽的大图一张十七八 MB，
    /// 以前一律按 8 MB 计，NSCache 以为还装得下，实际能把 App 撑出内存警告。
    private nonisolated static func memoryCost(_ img: PlatformImage) -> Int {
        #if os(iOS)
        let px = img.size.width * img.scale * img.size.height * img.scale
        #else
        let px = img.size.width * img.size.height
        #endif
        return max(1, Int(px) * 4)
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
    /// `image` 对应的那张图（Mac + 文件名 + 档位）：网格列数变化（比如首次布局从 2 列变 3 列）
    /// 或列表变更复用视图时，旧的 `load` 任务结束后不会把新位置的图覆写成旧图。
    @State private var loadedKey: String?
    /// 切回前台时重试一次（后台时正在下载的那张会被系统掐断，回来不然一直是灰的）
    @State private var retry = 0
    @Environment(\.scenePhase) private var scenePhase

    private var targetKey: String { "\(session.macID.uuidString)|\(wall.name)|\(kind.rawValue)" }

    private var displayed: PlatformImage? {
        if loadedKey == targetKey, let image { return image }
        return ImageStore.shared.cached(session, wall.name, kind) ?? fallback
    }

    var body: some View {
        ZStack {
            if let img = displayed {
                Image(platformImage: img)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Rectangle().fill(.quaternary)
                if !session.offline { ProgressView() } // 离线时没有就是没有，别一直转圈
            }
        }
        .task(id: "\(targetKey)|\(session.offline ? "offline" : "online")|\(retry)") {
            let key = targetKey
            if let hit = ImageStore.shared.cached(session, wall.name, kind) {
                loadedKey = key
                image = hit
                return
            }
            if loadedKey != key {
                image = nil
                loadedKey = nil
            }
            let loaded = await ImageStore.shared.load(session, wall.name, kind)
            guard !Task.isCancelled, targetKey == key else { return }
            loadedKey = key
            image = loaded
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, (loadedKey != targetKey || image == nil) { retry += 1 }
        }
    }

    /// 大图还没到时先用缩略图垫着。
    private var fallback: PlatformImage? {
        guard kind.isLarge else { return nil }
        return ImageStore.shared.cached(session, wall.name, kind == .image ? .hero : .image)
            ?? ImageStore.shared.cached(session, wall.name, .thumb)
    }
}
