import Foundation

/// 数据文件远端变更监视器
///
/// 数据目录可位于 iCloud Drive / Dropbox 等同步盘。其它设备写入后，
/// 同步引擎会以「新文件版本」替换本地 recordtree.sqlite；本应用通过
/// 轮询 DB 文件的修改时间发现变更，并在确认不是自身写入后重开数据库
/// 重新加载，实现多设备数据自动同步。
///
/// 注意：SQLite 长连接在文件被外部整体替换后不会自动感知新内容，
/// 因此必须 close() 后按新路径重新 open。
final class SyncWatcher {
    private var timer: Timer?
    private var lastSeenMtime: TimeInterval?
    /// 距本机最近一次写入至少超过该间隔才认为是「远端变更」
    private let remoteQuietThreshold: TimeInterval = 1.5

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        // 数据未就绪（首次启动失败或正在迁移）时跳过
        guard AppModel.shared.store != nil else { return }

        let url = AppPaths.dbURL
        guard
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
            let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate
        else {
            lastSeenMtime = nil
            return
        }

        // mtime 与本机观测不同 → 发生了数据写入（本机提交 或 远端同步替换）
        if let last = lastSeenMtime, last != mtime {
            let sinceLocal = Date.timeIntervalSinceReferenceDate - DataStore.lastLocalMutationSec
            if sinceLocal > remoteQuietThreshold {
                AppModel.shared.reloadFromRemoteChange()
            }
        }
        lastSeenMtime = mtime
    }
}
