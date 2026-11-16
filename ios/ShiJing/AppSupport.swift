import Foundation

/// Application Support/拾景 下各子目录的约定：位置、建目录、排除出备份都从这里取，
/// 别在 ImageStore / OfflineStore 里各写一份。
enum AppSupport {
    /// Application Support/拾景/<sub>。只算路径，不建目录。
    static func path(_ sub: String) -> URL? {
        let fm = FileManager.default
        guard let base = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true) else { return nil }
        return base.appending(path: "拾景/" + sub, directoryHint: .isDirectory)
    }

    /// 建好目录，并排除出 iCloud / 电脑备份（这里可能有十几 GB 的图）。
    /// 只在 init 里调：放在每次读写的路径上会多一次系统调用。
    static func prepare(_ dir: URL?) {
        guard let dir else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var d = dir
        var v = URLResourceValues()
        v.isExcludedFromBackup = true
        try? d.setResourceValues(v)
    }
}
