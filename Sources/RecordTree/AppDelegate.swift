import AppKit
import SwiftUI
import Carbon

/// 可拖拽的浮动面板：
/// - 不激活宿主 App（不抢焦点）
/// - 点击面板内文本控件时仍可成为 key window 以便输入
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: FloatingPanel!
    private let monitor = ClipboardMonitor()
    private let syncWatcher = SyncWatcher()
    private var bootOK = false
    /// 防止 App Nap 让后台剪贴板轮询被大幅延迟
    private var activityToken: NSObjectProtocol?
    private var escMonitor: Any?
    /// 滚轮滚动停止后恢复悬停的延时任务
    private var scrollIdleWork: DispatchWorkItem?

    /// 面板位置的持久化 key（v2：引入可缩放窗口）
    private enum FrameKey {
        static let x = "floatingPanelFrame2.x"
        static let y = "floatingPanelFrame2.y"
        static let w = "floatingPanelFrame2.width"
        static let h = "floatingPanelFrame2.height"
        /// 旧版（固定 578×620）键：仅迁移位置，尺寸改用新默认值
        static let legacyX = "floatingPanelFrame.x"
        static let legacyY = "floatingPanelFrame.y"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "\(AppInfo.zhName) 需要及时监听剪贴板变化"
        )

        // boot 失败自动重试：数据目录在 iCloud 等同步盘上时，启动瞬间可能碰到
        // 同步引擎短暂锁文件（SQLITE_BUSY），一次失败就永久瘫痪整个会话。
        // 最多重试 3 次（2s 间隔），成功后照常展示面板。
        bootWithRetry(attempts: 3) { [weak self] ok in
            guard let self else { return }
            self.bootOK = ok
            if ok {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    self?.showPanel()
                }
            } else {
                AppModel.shared.showToast("数据初始化失败，已重试 3 次；请检查数据目录后重启应用")
            }
        }

        setupStatusItem()
        setupPanel()
        setupGlobalShortcut()
        setupEscapeToHide()
        installScrollSuppression()
        monitor.start()
        syncWatcher.start()
    }

    /// 串行重试 boot；结果在主线程回调（首次立即，失败后间隔 2s）
    private func bootWithRetry(attempts: Int, completion: @escaping (Bool) -> Void) {
        do {
            try AppModel.shared.boot()
            completion(true)
        } catch {
            NSLog("\(AppInfo.zhName) 数据初始化失败（剩余重试 \(attempts - 1) 次）: \(error)")
            if attempts > 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    self?.bootWithRetry(attempts: attempts - 1, completion: completion)
                }
            } else {
                completion(false)
            }
        }
    }

    private func setupGlobalShortcut() {
        AppModel.shared.shortcutAction = { [weak self] in
            self?.togglePanel()
        }
        AppModel.shared.applyShortcut()
    }

    /// 面板激活状态下按 ESC 隐藏面板
    private func setupEscapeToHide() {
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == UInt16(kVK_Escape) else { return event }
            guard let self, self.panel.isVisible, self.panel.isKeyWindow else { return event }
            // 正在编辑文本（TextField / TextEditor 的第一响应者是 NSTextView）时，
            // 把 Esc 交还给编辑器与“取消”按钮，避免一按 Esc 就误隐藏整个面板。
            if self.isEditingText() { return event }
            // 弹层（删除确认 / 丢弃草稿 / 日期跳转）或多选模式激活时，
            // Esc 交给弹层“取消”按钮或多选退出逻辑，而不是隐藏整个面板
            if AppModel.shared.overlayActive { return event }
            self.hidePanel()
            return nil
        }
    }

    /// 当前第一响应者是否为文本编辑控件（SwiftUI TextField/TextEditor 编辑态均为 NSTextView 字段编辑器）
    private func isEditingText() -> Bool {
        guard let fr = panel?.firstResponder else { return false }
        if fr is NSTextView { return true }
        if let tf = fr as? NSTextField, tf.currentEditor() != nil { return true }
        return false
    }

    /// 面板当前是否处于 key 状态（用于剪贴板监听区分“应用内操作”与“外部复制”）
    func isPanelKeyWindow() -> Bool {
        panel?.isKeyWindow ?? false
    }

    /// 列表滚动时临时抑制悬停高亮/预览：
    /// 鼠标不动而列表内容滚动会令指针持续跨过各行，逐行触发 hover 导致整棵视图反复重算，
    /// 表现为滚动抖动。滚轮事件后 0.35s 内抑制，停顿后自动恢复。
    private func installScrollSuppression() {
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.scrollIdleWork?.cancel()
            let shared = AppModel.shared
            if !shared.scrollInProgress {
                shared.scrollInProgress = true
            }
            let w = DispatchWorkItem { shared.scrollInProgress = false }
            self?.scrollIdleWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
            return event
        }
    }

    // MARK: - 菜单栏图标

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.statusIcon()
        item.button?.toolTip = AppInfo.zhName
        item.button?.target = self
        item.button?.action = #selector(statusClicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
    }

    private static func statusIcon() -> NSImage {
        let names = ["tree.fill", "tree", "doc.on.clipboard.fill", "doc.on.clipboard"]
        for n in names {
            if let img = NSImage(systemSymbolName: n, accessibilityDescription: AppInfo.zhName) {
                img.isTemplate = true
                return img
            }
        }
        let img = NSImage(size: NSSize(width: 20, height: 20))
        img.lockFocus()
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: p,
        ]
        ("栖" as NSString).draw(in: NSRect(x: 0, y: 1, width: 20, height: 18), withAttributes: attrs)
        img.unlockFocus()
        img.isTemplate = true
        return img
    }

    // MARK: - 浮动面板

    private func setupPanel() {
        let defaultSize = NSSize(width: Config.panelWidth, height: Config.panelHeight)
        let minSize = NSSize(width: Config.panelMinWidth, height: Config.panelMinHeight)
        let maxSize = NSSize(width: Config.panelMaxWidth, height: Config.panelMaxHeight)
        let rect = NSRect(origin: .zero, size: defaultSize)
        let hosting = NSHostingController(rootView: ContentView(model: AppModel.shared))

        let win = FloatingPanel(
            contentRect: rect,
            styleMask: [.borderless, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        win.title = AppInfo.zhName
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isReleasedWhenClosed = false
        win.isMovableByWindowBackground = true   // 按住空白处长按拖拽即可移动
        win.level = .floating                    // 悬浮在普通窗口之上
        win.hidesOnDeactivate = false            // 点击其它应用时不自动消失
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.isRestorable = false
        win.minSize = minSize
        win.maxSize = maxSize
        win.contentViewController = hosting
        win.setContentSize(defaultSize)
        panel = win

        applyRoundedCorners(to: hosting.view)

        // 拖拽结束时记忆新位置
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(panelDidMove),
            name: NSWindow.didMoveNotification,
            object: win
        )
    }

    /// macOS 系统窗口同款圆角（四角）。
    /// borderless 窗口不会自动裁切圆角，这里让内容视图按系统连续圆角裁切，
    /// 并把窗口背景设为透明，露出圆角外的区域。
    private func applyRoundedCorners(to view: NSView) {
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        view.layer?.cornerRadius = 10
        view.layer?.cornerCurve = .continuous
        panel.isOpaque = false
        panel.backgroundColor = .clear
    }

    @objc private func statusClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent else {
            togglePanel()
            return
        }
        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePanel()
        }
    }

    func togglePanel() {
        if panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    func showPanel() {
        if !panel.isVisible {
            panel.setFrame(panelFrame, display: false)
        }
        if panel.isMiniaturized {
            panel.deminiaturize(nil)
        }
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    func hidePanel() {
        savePanelFrame()
        panel.orderOut(nil)
    }

    /// 窗口右上角红绿灯“最小化”（应用无 Dock 图标，恢复可从菜单栏图标或全局快捷键再次打开）
    func minimizePanel() {
        if panel.isMiniaturized {
            panel.deminiaturize(nil)
        } else {
            panel.performMiniaturize(nil)
        }
    }

    /// 面板显示位置：优先取用户上次拖拽的位置；首次或该位置不在当前屏幕时，
    /// 回退到菜单栏图标下方。
    private var panelFrame: NSRect {
        let size = NSSize(width: Config.panelWidth, height: Config.panelHeight)
        if let saved = savedFrame(size: size),
           NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -24, dy: -24).intersects(saved) }) {
            return saved
        }
        return defaultFrame(size: size)
    }

    /// 状态栏图标下方的默认位置（对齐图标水平中心、紧贴菜单栏）
    private func defaultFrame(size: NSSize) -> NSRect {
        var screen = NSScreen.main ?? NSScreen.screens.first
        var anchorX = screen?.visibleFrame.midX ?? NSEvent.mouseLocation.x
        if let button = statusItem.button, let bw = button.window, let s = bw.screen {
            screen = s
            let bf = bw.convertToScreen(button.convert(button.bounds, to: nil))
            anchorX = bf.midX
        }
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var x = anchorX - size.width / 2
        x = min(max(x, vf.minX + 8), vf.maxX - size.width - 8)
        let y = max(vf.maxY - size.height - 6, vf.minY + 6)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    @objc private func panelDidMove() {
        savePanelFrame()
    }

    private func savePanelFrame() {
        guard panel != nil else { return }
        let f = panel.frame
        let d = UserDefaults.standard
        d.set(f.origin.x, forKey: FrameKey.x)
        d.set(f.origin.y, forKey: FrameKey.y)
        d.set(f.size.width, forKey: FrameKey.w)
        d.set(f.size.height, forKey: FrameKey.h)
    }

    private func savedFrame(size: NSSize) -> NSRect? {
        let d = UserDefaults.standard
        var frame: NSRect?
        if d.object(forKey: FrameKey.x) != nil {
            let w = d.object(forKey: FrameKey.w) != nil ? d.double(forKey: FrameKey.w) : size.width
            let h = d.object(forKey: FrameKey.h) != nil ? d.double(forKey: FrameKey.h) : size.height
            frame = NSRect(x: d.double(forKey: FrameKey.x),
                           y: d.double(forKey: FrameKey.y),
                           width: w, height: h)
        } else if d.object(forKey: FrameKey.legacyX) != nil {
            // 旧版本迁移：沿用位置，尺寸改用新的默认值
            frame = NSRect(x: d.double(forKey: FrameKey.legacyX),
                           y: d.double(forKey: FrameKey.legacyY),
                           width: size.width, height: size.height)
        }
        guard let raw = frame else { return nil }
        let f = clampFrame(raw)
        guard f.width >= Config.panelMinWidth, f.height >= Config.panelMinHeight,
              NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -24, dy: -24).intersects(f) })
        else { return nil }
        return f
    }

    /// 将窗口尺寸夹在可缩放范围内（右下角拖拽时也用于限制）
    private func clampFrame(_ f: NSRect) -> NSRect {
        var r = f
        r.size.width = min(max(r.width, Config.panelMinWidth), Config.panelMaxWidth)
        r.size.height = min(max(r.height, Config.panelMinHeight), Config.panelMaxHeight)
        return r
    }

    // MARK: - 右键菜单

    private func showContextMenu() {
        let menu = NSMenu()
        let open = NSMenuItem(title: "打开 \(AppInfo.zhName)", action: #selector(openAction), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 \(AppInfo.zhName)", action: #selector(quitAction), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        if let button = statusItem.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 6), in: button)
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    @objc private func openAction() {
        showPanel()
    }

    @objc private func quitAction() {
        savePanelFrame()
        NSApp.terminate(nil)
    }
}
