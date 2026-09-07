import AppKit

/// 剪贴板会话：自我复制标记 + 来源识别
final class ClipboardSession {
    static let shared = ClipboardSession()

    enum PendingKind: Equatable {
        /// 与某个 chunk 对应（点击单条复制），剪贴板回落后只更新时间戳
        case chunk(String)
        /// 聚合文本（如整棵记录），复制到剪贴板但不重新入库
        case ignored
    }

    struct Pending {
        let kind: PendingKind
        let content: String
        let setAtMs: Int64
    }
    /// 本应用主动写入剪贴板后的待判定记录
    private(set) var pending: Pending?
    private let windowMs: Int64 = 3000

    /// 点击单条 chunk / 记录复制时调用
    func beginCopy(content: String, chunkID: String) {
        pending = Pending(kind: .chunk(chunkID), content: content, setAtMs: TimeUtil.msNow())
    }

    /// 复制整棵记录（聚合文本，不重复入库）时调用
    func beginTreeCopy(content: String) {
        pending = Pending(kind: .ignored, content: content, setAtMs: TimeUtil.msNow())
    }

    /// 剪贴板未变化时，清理过期的 pending，避免误判
    func expirePendingIfNeeded() {
        if let p = pending, TimeUtil.msNow() - p.setAtMs > windowMs {
            pending = nil
        }
    }

    /// 剪贴板发生变化时判定：窗口内且内容一致 → 返回对应处理类型
    func takePending(content currentContent: String?) -> PendingKind? {
        guard let p = pending else { return nil }
        let fresh = TimeUtil.msNow() - p.setAtMs <= windowMs
        if fresh, currentContent == p.content {
            pending = nil
            return p.kind
        }
        pending = nil
        return nil
    }

    func frontmostAppName() -> String {
        NSWorkspace.shared.frontmostApplication?.localizedName ?? "未知应用"
    }
}

/// 剪贴板轮询监听（每 0.5s 比较 changeCount）
final class ClipboardMonitor {
    private var timer: Timer?
    private var lastChangeCount = -1
    private var initialized = false
    private var editObservers: [NSObjectProtocol] = []
    /// 面板内是否正有文本处于编辑状态（TextField / TextEditor）
    private var textEditingActive = false

    func start() {
        guard timer == nil else { return }
        let nc = NotificationCenter.default
        // SwiftUI TextField 的字段编辑器与 TextEditor 在编辑中都会发出 NSText 编辑通知
        editObservers.append(nc.addObserver(forName: NSText.didBeginEditingNotification, object: nil, queue: .main) { [weak self] _ in
            self?.textEditingActive = true
        })
        editObservers.append(nc.addObserver(forName: NSText.didEndEditingNotification, object: nil, queue: .main) { [weak self] _ in
            self?.textEditingActive = false
        })
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        for token in editObservers {
            NotificationCenter.default.removeObserver(token)
        }
        editObservers.removeAll()
        textEditingActive = false
    }

    private func tick() {
        let pb = NSPasteboard.general
        let cc = pb.changeCount

        if !initialized {
            initialized = true
            lastChangeCount = cc
            return
        }
        guard cc != lastChangeCount else {
            ClipboardSession.shared.expirePendingIfNeeded()
            return
        }
        lastChangeCount = cc

        // 1) 自我复制：文本走 pending 比对；图片走剪贴板标记（chunk id）
        if let kind = ClipboardSession.shared.takePending(content: pb.string(forType: .string)) {
            switch kind {
            case .chunk(let chunkID):
                AppModel.shared.handleSelfCopy(chunkID: chunkID)
            case .ignored:
                break // 整树复制：不回写库，也不重复入库
            }
            return
        }
        if let chunkID = pb.string(forType: ClipboardImage.selfCopyMarkerType) {
            AppModel.shared.handleSelfCopy(chunkID: chunkID)
            return
        }

        // 用户正在面板内编辑文本时，⌘C/⌘X 产生的剪贴板变化属于应用内部操作，
        // 不应当作“外部复制”重新入库，否则输入过程中会在背后新增记录并整页重排，
        // 造成输入中断、列表抖动。仅在“编辑中”才拦截，避免误吞打开面板前的正常外部复制。
        if textEditingActive, (NSApp.delegate as? AppDelegate)?.isPanelKeyWindow() == true {
            return
        }

        // 若用户关闭了“自动记录剪贴板”，不再将外部复制保存入库。
        // 自我复制与手动新建 / 追加分段不受影响。
        guard AppModel.shared.autoRecordClipboard else { return }

        // 2) 外部复制
        let source = ClipboardSession.shared.frontmostAppName()
        let text = pb.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let imageData = ClipboardImage.rawImageData(from: pb)
        if let text, !text.isEmpty {
            // 纯文本优先按文本记录；仅当文本像是图片的 URL/路径且剪贴板确有图片数据时，才按图片处理
            if imageData == nil || !ClipboardImage.looksLikeURLOrPath(text) {
                AppModel.shared.handleExternalCopy(content: text, source: source)
                return
            }
        }
        if let imageData {
            AppModel.shared.handleExternalImageCopy(rawImage: imageData, source: source)
        }
    }
}
