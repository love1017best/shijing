import Foundation

// MARK: - 后台缓存队列

extension ImageStore {
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
        let macID = session.macID.uuidString
        let names = session.walls.map(\.name)
        let heroName = session.heroName
        let wantOriginals = Self.originalsEnabled
        // 进度按壁纸算：这一批多少张就是多少（缩略图、横幅很小，不算；大图和原图各走一遍这个数）
        prefetchTotal = names.count
        prefetchDone = 0
        prefetchOriginalDone = 0
        prefetching = true
        task = Task {
            // 先等还在跑的删缓存（含升级后清理根目录旧文件）做完，再量磁盘：
            // 不然「已用」会把马上要删的文件也算进去
            await waitForClear()
            if Task.isCancelled {
                if g == gen { prefetching = false }
                return
            }
            let prep = await Task.detached(priority: .utility) {
                (Self.totalDiskUsage(), Self.existingFileNames(for: macID))
            }.value
            if Task.isCancelled {
                if g == gen { prefetching = false }
                return
            }
            var used = prep.0
            let existing = prep.1
            var candidates: [(String, ImageKind)] = names.map { ($0, .thumb) }
            if let hero = heroName ?? names.first { candidates.append((hero, .hero)) }
            // 概览横幅会轮播整批：其余每张也存一份横幅图（1600 宽，每张约 200–300 KB）。
            // 旧版桌面端没给 hero 时手机横幅用大图，不存这一档
            if let hero = heroName {
                candidates.append(contentsOf: names.filter { $0 != hero }.map { ($0, .hero) })
            }
            candidates.append(contentsOf: names.map { ($0, .image) })
            if wantOriginals { candidates.append(contentsOf: names.map { ($0, .original) }) }

            // 先过滤已经在磁盘上的项，既省去无意义的并发任务，也避免已全部存完时误触发「已到上限」
            var queue: [(String, ImageKind)] = []
            var doneImage = 0
            var doneOriginal = 0
            let origPrefix = ImageKind.original.cachePrefix + "-"
            for (n, kind) in candidates {
                let s = Self.safeName(n)
                let fileName = "\(kind.cachePrefix)-\(s)"
                if existing.contains(fileName) || (kind == .image && existing.contains(origPrefix + s)) {
                    if kind == .image { doneImage += 1 }
                    if kind == .original { doneOriginal += 1 }
                    continue
                }
                queue.append((n, kind))
            }
            if g == gen {
                prefetchDone = doneImage
                prefetchOriginalDone = doneOriginal
            }
            guard !queue.isEmpty else {
                if g == gen { prefetching = false }
                return
            }
            if used >= Self.cacheLimitBytes {
                if g == gen {
                    prefetchHitLimit = true
                    prefetching = false
                }
                return
            }

            var next = 0
            var hitLimit = false
            await withTaskGroup(of: (ImageKind, Int64, Error?).self) { group in
                // 同时最多 3 张，别把手机的网络和解码占满
                let workers = 3
                func addNext() -> Bool {
                    guard next < queue.count, !hitLimit else { return false }
                    let (n, kind) = queue[next]
                    next += 1
                    group.addTask { await Self.fetchOne(client, macID: macID, n, kind) }
                    return true
                }
                for _ in 0..<workers where addNext() {}
                while let (kind, bytes, error) = await group.next() {
                    if let error {
                        // 连不上电脑或令牌已失效：这一轮先停（已经存下的留着），同步离线 / 未配对状态
                        group.cancelAll()
                        if g == gen {
                            prefetching = false
                            session.handleRequestError(error, showMessage: false)
                        }
                        return
                    }
                    if Task.isCancelled {
                        group.cancelAll()
                        if g == gen { prefetching = false }
                        return
                    }
                    // 进度按壁纸算：大图、原图各数各的，缩略图和横幅不算
                    if g == gen {
                        if kind == .image { prefetchDone += 1 }
                        if kind == .original { prefetchOriginalDone += 1 }
                    }
                    used += bytes
                    if used >= Self.cacheLimitBytes, next < queue.count {
                        // 到了上限：手上这几张存完就停，后面的不存了
                        hitLimit = true
                        if g == gen { prefetchHitLimit = true }
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

    /// 等还在跑的「清除」做完：删文件是后台任务，量磁盘之前不等它，
    /// 数出来的还是删之前的大小（设置页点完「清除」看着像没清掉）。
    func waitForClear() async {
        while let clear = clearTask {
            let g = clearGen
            await clear.value
            if clearGen == g {
                clearTask = nil
                break
            }
        }
    }

    /// 进入离线模式或切换 Mac：停掉这一轮缓存。和「暂停」不同，退出离线模式、重新连上后会自动接着补。
    func cancelPrefetch() {
        task?.cancel()
        task = nil
        prefetching = false
        prefetchHitLimit = false
    }

    /// 换了一批：先停掉下载中的任务（别让属于上一批的图写进来），由调用方接着 `keepOnly`。
    func stopForNewBatch() {
        task?.cancel()
        task = nil
        prefetching = false
    }

    /// 下载一张存到磁盘；已经有了就不动。返回写下的字节数，以及需要中止本轮缓存的错误
    /// （连不上电脑或 401 未配对：调用方据此停掉这一轮，别把后面几百张各等一次超时或静默吃 401）。
    private nonisolated static func shouldAbortPrefetch(_ error: Error) -> Bool {
        if case APIError.unauthorized = error { return true }
        return RemoteSession.isNetworkFailure(error)
    }

    private nonisolated static func fetchOne(_ client: APIClient, macID: String, _ name: String,
                                             _ kind: ImageKind) async -> (ImageKind, Int64, Error?) {
        // 只 stat 不读整张图：补齐几百张时每张都按几十万字节读一遍纯属白读
        if onDisk(macID, name, kind) { return (kind, 0, nil) }
        if kind == .image, cachedOriginal(macID: macID, name: name) != nil { return (kind, 0, nil) } // 有原图能本地缩，不用再下
        if kind == .original {
            let tmp: URL
            do {
                tmp = try await client.downloadOriginal(name)
            } catch {
                return (kind, 0, shouldAbortPrefetch(error) ? error : nil)
            }
            defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent()) }
            if Task.isCancelled { return (kind, 0, nil) }
            guard let f = diskFile(macID, name, .original) else { return (kind, 0, nil) }
            let fm = FileManager.default
            try? fm.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: f.path) { try? fm.removeItem(at: f) }
            guard (try? fm.moveItem(at: tmp, to: f)) != nil else { return (kind, 0, nil) }
            return (kind, Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0), nil)
        }
        let data: Data
        do {
            data = try await client.imageData(name, kind: kind)
        } catch {
            return (kind, 0, shouldAbortPrefetch(error) ? error : nil)
        }
        if Task.isCancelled { return (kind, 0, nil) }
        writeDisk(macID, name, kind, data)
        return (kind, Int64(data.count), nil)
    }
}
