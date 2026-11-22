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
    /// 单轮文件检查是否仍在后台进行，避免同步盘响应慢时堆积任务
    private var checkInFlight = false
    /// 距本机最近一次写入至少超过该间隔才认为是「远端变更」。
    /// 必须大于轮询间隔：否则下一次 tick（最多约 2s 后）会把本机写入误判成云端替换，
    /// 关掉正在使用的连接；若此时文件还是 iCloud 占位，历史列表会被刷空。
    private let remoteQuietThreshold: TimeInterval = 3.5

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
        guard AppModel.shared.store != nil, !checkInFlight else { return }
        checkInFlight = true
        let url = AppPaths.dbURL

        // databaseFileIsReady 会向 iCloud / Dropbox 的 FileProvider 发同步 XPC，
        // 同步盘繁忙时可能阻塞数秒。放在主线程会表现为整个面板“卡死”，
        // 因此文件检查全部移到后台队列，结果再回主线程比较。
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let ready = DataStore.databaseFileIsReady(at: url)
            var mtime: TimeInterval?
            if ready,
               let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let date = attrs[.modificationDate] as? Date {
                mtime = date.timeIntervalSinceReferenceDate
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.checkInFlight = false
                // 文件还在下载或被截断时不要更新 lastSeen，下一轮继续等完整文件
                guard ready else { return }
                guard let mtime else {
                    self.lastSeenMtime = nil
                    return
                }
                // mtime 与本机观测不同 → 发生了数据写入（本机提交 或 远端同步替换）
                if let last = self.lastSeenMtime, last != mtime {
                    let sinceLocal = Date.timeIntervalSinceReferenceDate - DataStore.lastLocalMutationSec
                    if sinceLocal > self.remoteQuietThreshold {
                        AppModel.shared.reloadFromRemoteChange()
                    }
                }
                self.lastSeenMtime = mtime
            }
        }
    }
}
