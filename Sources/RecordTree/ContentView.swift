import SwiftUI
import AppKit

private struct TreeHoverFrameKey: PreferenceKey {
    static var defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        if let n = nextValue() { value = n }
    }
}

private struct ChunkHoverFrameKey: PreferenceKey {
    static var defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        if let n = nextValue() { value = n }
    }
}

// MARK: - 删除确认

private struct DeleteRequest: Identifiable {
    enum Kind {
        /// 一条或多条整树记录（多选删除时 treeIDs 可能不止一个）
        case trees
        case chunk
        case all
    }
    let kind: Kind
    let treeIDs: [String]
    let chunkID: String?
    let treeChunkCount: Int

    // 兼容既有单条删除调用点
    init(kind: Kind, treeID: String, chunkID: String?, treeChunkCount: Int) {
        self.kind = kind
        self.treeIDs = [treeID]
        self.chunkID = chunkID
        self.treeChunkCount = treeChunkCount
    }

    // 多选删除专用
    init(trees ids: [String], totalChunks: Int) {
        self.kind = .trees
        self.treeIDs = ids
        self.chunkID = nil
        self.treeChunkCount = totalChunks
    }

    var id: String {
        switch kind {
        case .all: return "all"
        case .trees: return treeIDs.sorted().joined(separator: ",")
        case .chunk: return chunkID ?? ""
        }
    }

    var isMultiple: Bool { kind == .trees && treeIDs.count > 1 }

    var message: String {
        switch kind {
        case .trees:
            if treeIDs.count > 1 {
                return "将删除所选 \(treeIDs.count) 条记录及其下 \(treeChunkCount) 个分段，此操作不可恢复。"
            }
            return "将删除该记录及其下 \(treeChunkCount) 个分段，此操作不可恢复。"
        case .chunk:
            return "将删除该分段，此操作不可恢复。"
        case .all:
            return "将清空全部记录及全部分段，所有数据不可恢复。"
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var hoveredTreeID: String?
    @State private var hoveredChunkID: String?

    // 新建 maintree 编辑器
    @State private var newTitle = ""
    @State private var newContent = ""

    // 搜索
    @State private var searchText = ""
    /// 是否已经针对当前关键词执行过搜索（用于区分“未输入/无结果”两种空态）
    @State private var searchHasRun = false
    @State private var searchWork: DispatchWorkItem?
    /// 进入搜索界面后自动聚焦输入框，方便直接输入
    @FocusState private var searchFieldFocused: Bool
    /// 新建 maintree 编辑区的焦点（自动聚焦标题，回车跳到正文）
    @FocusState private var newTitleFocused: Bool
    @FocusState private var newContentFocused: Bool

    // 在当前 maintree 后追加 chunk 的草稿
    @State private var chunkDraftTreeID: String?
    @State private var chunkDraftText = ""

    // 删除确认
    @State private var confirmDelete: DeleteRequest?
    /// 新建记录编辑器：存在未保存内容时离开需确认丢弃
    @State private var discardNewDraft = false
    /// 底部日期跳转目录
    @State private var showDayJump = false

    // 多选删除：进入多选模式后可勾选多条记录批量删除
    @State private var multiSelectActive = false
    @State private var selectedTreeIDs: Set<String> = []

    // 悬停浮层（全局坐标）
    @State private var hoverTreeFrame: CGRect?
    @State private var hoverChunkFrame: CGRect?
    @State private var listFrame: CGRect = .zero
    /// 悬停预览延迟就绪：鼠标快速扫过各行时不逐行弹卡，停顿片刻才展示
    @State private var hoverPreviewReady = false
    @State private var hoverPreviewWork: DispatchWorkItem?

    // 右下角拖拽缩放
    @State private var resizeStartFrame: NSRect?
    @State private var resizeStartPoint: NSPoint?

    // 列表键盘导航：↑/↓ 选择行，回车复制整棵，空格展开/折叠，x 归档，⌫ 删除
    @State private var keyboardFocusedTreeID: String?
    @State private var keyboardMonitor: Any?
    @State private var windowResignObserver: NSObjectProtocol?

    var body: some View {
        VStack(spacing: 0) {
            topToolbar
            Divider()
            ZStack {
                listArea
                if model.viewMode == .newRecord {
                    newRecordEditor
                }
                if model.viewMode == .searchResults {
                    searchResultsView
                }
                if model.viewMode == .settings {
                    settingsPanel
                }
            }
            .background(listGeometry)
            .overlay(alignment: .topLeading) { hoverCard }
            .overlay(alignment: .bottom) { toastView }
            .onChange(of: hoveredTreeID) { _ in
                if hoveredTreeID == nil {
                    hoverTreeFrame = nil
                    cancelHoverPreview()
                } else {
                    scheduleHoverPreview()
                }
            }
            .onChange(of: hoveredChunkID) { _ in
                if hoveredChunkID == nil {
                    hoverChunkFrame = nil
                    cancelHoverPreview()
                } else {
                    scheduleHoverPreview()
                }
            }
            // 非列表页各自拥有完整的内容与操作区，不再显示列表翻页条
            if model.viewMode == .list {
                Divider()
                if multiSelectActive {
                    multiSelectBar
                } else {
                    bottomBar
                }
            }
        }
        .frame(
            minWidth: Config.panelMinWidth,
            idealWidth: Config.panelWidth,
            maxWidth: Config.panelMaxWidth,
            minHeight: Config.panelMinHeight,
            idealHeight: Config.panelHeight,
            maxHeight: Config.panelMaxHeight
        )
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottomTrailing) { resizeHandle }
        .overlay {
            if confirmDelete != nil {
                deleteConfirmLayer
                    .transition(.opacity)
            }
        }
        .overlay {
            if discardNewDraft {
                discardDraftLayer
                    .transition(.opacity)
            }
        }
        .overlay {
            if showDayJump, model.viewMode == .list {
                dayJumpLayer
                    .transition(.opacity)
            }
        }
        .onChange(of: model.scrollInProgress) { scrolling in
            // 开始滚动即清除旧悬停位，避免滚动结束后残留高亮/预览导致视觉跳变
            guard scrolling else { return }
            hoveredTreeID = nil
            hoveredChunkID = nil
            hoverTreeFrame = nil
            hoverChunkFrame = nil
            cancelHoverPreview()
        }
        .onAppear(perform: installKeyboardMonitor)
        .onDisappear(perform: removeKeyboardMonitor)
        .onChange(of: model.viewMode) { _ in
            keyboardFocusedTreeID = nil
            showDayJump = false
            // 离开主列表时退出多选，避免残留勾选状态
            if model.viewMode != .list {
                resetMultiSelect()
            }
        }
        .animation(.easeOut(duration: 0.15), value: confirmDelete != nil)
        .animation(.easeInOut(duration: 0.18), value: model.lastToast)
        .animation(.easeOut(duration: 0.1), value: hoverPreviewReady)
        .animation(.easeOut(duration: 0.15), value: showDayJump)
    }

    // MARK: - 删除确认（自定义左对齐弹层，替代系统 alert，保证与整体布局一致）

    private var deleteConfirmLayer: some View {
        ZStack {
            Color.black.opacity(0.12)
                .onTapGesture { confirmDelete = nil }
            if let req = confirmDelete {
                DeleteConfirmDialog(
                    request: req,
                    onCancel: { confirmDelete = nil },
                    onConfirm: { performDelete(req) }
                )
            }
        }
    }

    // MARK: - 日期跳转目录

    private var dayJumpLayer: some View {
        ZStack {
            Color.black.opacity(0.10)
                .onTapGesture { showDayJump = false }

            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.accentColor)
                    Text("跳转到有记录的日期")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer(minLength: 0)
                    Button("关闭", action: { showDayJump = false })
                        .keyboardShortcut(.cancelAction)
                        .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                Divider()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if model.hasNewer {
                            dayJumpRow(
                                icon: "bolt.fill",
                                title: "最新记录",
                                detail: "当前正停留在更早的日期",
                                isCurrent: false
                            ) {
                                model.goToNewestPage()
                                showDayJump = false
                            }
                        }
                        ForEach(model.dayJumpItems) { item in
                            dayJumpRow(
                                icon: "doc.text",
                                title: item.label,
                                detail: "\(item.count) 条"
                                    + (item.pageCount > 1 ? " · 共 \(item.pageCount) 屏" : ""),
                                isCurrent: item.dayKey == model.currentDayKey
                            ) {
                                model.jumpToDay(item.dayKey)
                                showDayJump = false
                            }
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 280)
            }
            .frame(width: 300, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.2), radius: 18, x: 0, y: 8)
            .transition(.scale(scale: 0.97).combined(with: .opacity))
        }
    }

    private func dayJumpRow(
        icon: String,
        title: String,
        detail: String,
        isCurrent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: isCurrent ? "checkmark.circle.fill" : icon)
                    .font(.system(size: 12))
                    .foregroundColor(isCurrent ? Color.accentColor : Color.secondary)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                    .foregroundColor(isCurrent ? Color.accentColor : Color.primary)
                Spacer(minLength: 8)
                Text(detail)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isCurrent ? Color.accentColor.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 新建记录：丢弃草稿确认

    /// 是否有未保存的草稿（标题或正文任一非空）
    private var hasNewDraft: Bool {
        !newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !newContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 取消/ESC 离开编辑器：有草稿先确认，避免静默丢失输入
    private func cancelNewRecordEditing() {
        if hasNewDraft {
            discardNewDraft = true
        } else {
            clearNewRecordDraft()
            model.cancelNewRecord()
        }
    }

    private var discardDraftLayer: some View {
        ZStack {
            Color.black.opacity(0.12)
                .onTapGesture { discardNewDraft = false }
            DiscardDraftDialog(
                onContinue: { discardNewDraft = false },
                onDiscard: {
                    discardNewDraft = false
                    clearNewRecordDraft()
                    model.cancelNewRecord()
                }
            )
        }
    }

    private func performDelete(_ req: DeleteRequest) {
        switch req.kind {
        case .trees:
            model.deleteTrees(req.treeIDs)
            resetMultiSelect()
        case .chunk:
            if let cid = req.chunkID {
                model.deleteChunk(cid)
            }
        case .all:
            model.clearAllRecords()
        }
        confirmDelete = nil
    }

    /// 单个记录/分段删除：按设置决定是否弹确认框；一键清空始终弹确认
    private func requestDelete(_ req: DeleteRequest) {
        if req.kind == .all || model.requireDeleteConfirm {
            confirmDelete = req
        } else {
            performDelete(req)
        }
    }

    // MARK: - 多选删除

    private func enterMultiSelect() {
        multiSelectActive = true
        selectedTreeIDs.removeAll()
        keyboardFocusedTreeID = nil
        cancelHoverPreview()
    }

    private func exitMultiSelect() {
        resetMultiSelect()
    }

    private func resetMultiSelect() {
        multiSelectActive = false
        selectedTreeIDs.removeAll()
    }

    /// 勾选 / 取消勾选某条记录（多选模式下点行主体也触发）
    private func toggleRowSelection(_ treeID: String) {
        if selectedTreeIDs.contains(treeID) {
            selectedTreeIDs.remove(treeID)
        } else {
            selectedTreeIDs.insert(treeID)
        }
        keyboardFocusedTreeID = treeID
    }

    /// 当前整页是否已全部选中
    private var currentPageAllSelected: Bool {
        !model.rows.isEmpty && model.rows.allSatisfy { selectedTreeIDs.contains($0.id) }
    }

    /// 全选本页 / 取消全选本页
    private func toggleSelectCurrentPage() {
        if currentPageAllSelected {
            model.rows.forEach { selectedTreeIDs.remove($0.id) }
        } else {
            model.rows.forEach { selectedTreeIDs.insert($0.id) }
        }
    }

    /// 所选记录的分段总数（用于确认文案）
    private func selectedChunkCount(_ ids: [String]) -> Int {
        model.rows
            .filter { ids.contains($0.id) }
            .reduce(0) { $0 + $1.tree.chunks.count }
    }

    private func confirmDeleteSelection() {
        let ids = Array(selectedTreeIDs)
        guard !ids.isEmpty else { return }
        requestDelete(
            DeleteRequest(trees: ids, totalChunks: selectedChunkCount(ids))
        )
    }

    // MARK: - 列表几何（用于浮层定位）

    private var listGeometry: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { listFrame = geo.frame(in: .global) }
                .onChange(of: geo.frame(in: .global)) { listFrame = $0 }
        }
    }

    // MARK: - 悬停浮层

    private var hoverCard: some View {
        let text = hoverText
        return Group {
            // 滚动期间或鼠标刚扫过（未稳定停留）时不显示预览卡，避免视觉抖动；
            // 多选模式下悬停含义变为“待勾选”，同样不弹出预览，避免误读
            if !model.scrollInProgress,
               !multiSelectActive,
               hoverPreviewReady,
               let hf = hoverFrame,
               !listFrame.isEmpty,
               !text.isEmpty {
                HoverCard(
                    title: hoverTitle,
                    text: text,
                    targetFrame: hf,
                    containerFrame: listFrame
                )
            }
        }
    }

    /// 悬停稳定一小段时间后再展示预览卡（跟随目标行，不额外锁定鼠标）
    private func scheduleHoverPreview() {
        hoverPreviewWork?.cancel()
        hoverPreviewReady = false
        let w = DispatchWorkItem { [self] in
            if !self.model.scrollInProgress,
               self.hoveredTreeID != nil || self.hoveredChunkID != nil {
                self.hoverPreviewReady = true
            }
        }
        hoverPreviewWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: w)
    }

    private func cancelHoverPreview() {
        hoverPreviewWork?.cancel()
        hoverPreviewWork = nil
        hoverPreviewReady = false
    }

    private var hoverFrame: CGRect? { hoverChunkFrame ?? hoverTreeFrame }

    private var hoverTitle: String? {
        if hoveredChunkID != nil {
            return nil
        }
        if let tid = hoveredTreeID,
           let row = model.rows.first(where: { $0.id == tid }) {
            return row.titleText
        }
        return nil
    }

    private var hoverText: String {
        if let cid = hoveredChunkID,
           let vm = model.rows.flatMap({ $0.chunks }).first(where: { $0.id == cid }) {
            return vm.chunk.content
        }
        if let tid = hoveredTreeID,
           let row = model.rows.first(where: { $0.id == tid }) {
            return row.fullText
        }
        return ""
    }

    // MARK: - 右下角拖拽缩放

    /// 当前面板窗口（可能处于非激活状态，keyWindow 为空时退而取悬浮面板）
    private var hostWindow: NSWindow? {
        NSApp.keyWindow ?? NSApp.windows.first { $0.level == .floating && $0.isVisible }
    }

    private var resizeHandle: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(Color.secondary.opacity(0.55))
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
            .gesture(cornerResizeGesture)
            .padding(.trailing, 1)
            .padding(.bottom, 1)
    }

    private var cornerResizeGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                guard let win = hostWindow else { return }
                if resizeStartFrame == nil {
                    resizeStartFrame = win.frame
                    resizeStartPoint = value.location
                }
                guard let start = resizeStartFrame, let sp = resizeStartPoint else { return }
                var newW = start.width + (value.location.x - sp.x)
                var newH = start.height + (value.location.y - sp.y)
                newW = min(max(newW, Config.panelMinWidth), Config.panelMaxWidth)
                newH = min(max(newH, Config.panelMinHeight), Config.panelMaxHeight)
                // SwiftUI 全局坐标 y 向下；保持窗口顶边不动，仅向右下伸展
                let topY = start.minY + start.height
                let newOrigin = NSPoint(x: start.minX, y: topY - newH)
                win.setFrame(
                    NSRect(x: newOrigin.x, y: newOrigin.y, width: newW, height: newH),
                    display: true
                )
            }
            .onEnded { _ in
                resizeStartFrame = nil
                resizeStartPoint = nil
            }
    }

    // MARK: - 列表键盘导航

    /// 当前第一响应者是否为文本编辑控件（TextField/TextEditor 编辑态均为 NSTextView），
    /// 是则把按键交还输入，避免在搜索/编辑/补充分段时误触发列表快捷键。
    private func isTypingInList() -> Bool {
        guard let fr = NSApp.keyWindow?.firstResponder else { return false }
        if fr is NSTextView { return true }
        if let tf = fr as? NSTextField, tf.currentEditor() != nil { return true }
        return false
    }

    private func installKeyboardMonitor() {
        removeKeyboardMonitor()
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            self.handleListKeyEvent(event) ? nil : event
        }
        // 面板失去键盘焦点（点击他处 / Esc 隐藏）时收起轻量浮层，避免再次打开时残留
        windowResignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { [self] note in
            guard let win = note.object as? NSWindow,
                  win.level == .floating || win.level == .normal
            else { return }
            self.showDayJump = false
        }
    }

    private func removeKeyboardMonitor() {
        if let m = keyboardMonitor {
            NSEvent.removeMonitor(m)
            keyboardMonitor = nil
        }
        if let o = windowResignObserver {
            NotificationCenter.default.removeObserver(o)
            windowResignObserver = nil
        }
    }

    /// 列表页键盘操作：↑/↓（或 J/K）移动选择行；回车复制整棵；空格展开/折叠；
    /// X 切换归档；⌫ 删除（仍走二次确认）。返回 true 表示已消费该按键。
    private func handleListKeyEvent(_ event: NSEvent) -> Bool {
        guard model.viewMode == .list,
              confirmDelete == nil,
              !discardNewDraft,
              !showDayJump,
              !isTypingInList(),
              !model.rows.isEmpty
        else { return false }

        // 多选模式有独立的键位语义：先交由其处理
        if multiSelectActive {
            return handleMultiSelectKeyEvent(event)
        }

        // 排除带 Command / Control / Option 的组合键，不劫持系统与全局快捷键
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            return false
        }

        let focusedID = keyboardFocusedTreeID
        switch event.keyCode {
        case 125: // ↓
            moveKeyboardSelection(+1)
            return true
        case 126: // ↑
            moveKeyboardSelection(-1)
            return true
        case 36: // 回车：复制整棵
            if let id = focusedID {
                model.copyTree(id)
                return true
            }
            return false
        case 49: // 空格：展开 / 折叠（需先有选择行，避免误触整页展开）
            if let id = focusedID {
                withAnimation(.easeInOut(duration: 0.16)) {
                    model.toggleExpanded(id)
                }
                return true
            }
            return false
        case 51, 117: // ⌫ / 向前删除
            deleteFocusedTree()
            return true
        default:
            break
        }

        if let ch = event.charactersIgnoringModifiers?.lowercased() {
            switch ch {
            case "j":
                moveKeyboardSelection(+1)
                return true
            case "k":
                moveKeyboardSelection(-1)
                return true
            case "x":
                if let id = focusedID {
                    model.toggleArchiveTree(id)
                    return true
                }
                return false
            default:
                break
            }
        }
        return false
    }

    /// 多选模式的键盘操作：↑/↓ 移动焦点，空格勾选当前行，⌫ 删除所选，
    /// ⌘A / A 全选本页，ESC 退出。返回 true 表示已消费该按键。
    private func handleMultiSelectKeyEvent(_ event: NSEvent) -> Bool {
        // ⌘A 全选 / 取消全选本页（优先于下方组合键拦截）
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "a" {
            toggleSelectCurrentPage()
            return true
        }
        // 其余带 Command / Control / Option 的组合键放行给系统或全局快捷键
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            return false
        }
        switch event.keyCode {
        case 53: // ESC：退出多选
            exitMultiSelect()
            return true
        case 125: // ↓
            moveKeyboardSelection(+1)
            return true
        case 126: // ↑
            moveKeyboardSelection(-1)
            return true
        case 49: // 空格：勾选 / 取消勾选当前焦点行
            if let id = keyboardFocusedTreeID {
                toggleRowSelection(id)
            }
            return true
        case 51, 117: // ⌫ / 向前删除：删除所选（未选任何记录时退化为删除焦点行）
            if !selectedTreeIDs.isEmpty {
                confirmDeleteSelection()
            } else {
                deleteFocusedTree()
            }
            return true
        default:
            break
        }
        if let ch = event.charactersIgnoringModifiers?.lowercased() {
            switch ch {
            case "j":
                moveKeyboardSelection(+1)
                return true
            case "k":
                moveKeyboardSelection(-1)
                return true
            case "a":
                toggleSelectCurrentPage()
                return true
            default:
                break
            }
        }
        return false
    }

    /// 相对当前选择行移动一行的键盘焦点；到页首/页尾时自动翻到相邻页并衔接选择行。
    private func moveKeyboardSelection(_ step: Int) {
        let rows = model.rows
        guard !rows.isEmpty else {
            keyboardFocusedTreeID = nil
            return
        }
        var current = keyboardFocusedTreeID.flatMap { id in
            rows.firstIndex { $0.id == id }
        }
        if current == nil { current = 0 }
        guard let cur = current else { return }

        let next = cur + step
        if next < 0 {
            // 已在本屏最顶（更新方向），继续上移到上一屏的末尾行保持连贯
            if model.hasNewer {
                model.goNewer(scroll: false)
                keyboardFocusedTreeID = model.rows.last?.id
            } else {
                keyboardFocusedTreeID = rows.first?.id
            }
        } else if next >= rows.count {
            // 已在本屏最底（更旧方向），继续下移到下一屏的首行
            if model.hasOlder {
                model.goOlder(scroll: false)
                keyboardFocusedTreeID = model.rows.first?.id
            } else {
                keyboardFocusedTreeID = rows.last?.id
            }
        } else {
            keyboardFocusedTreeID = rows[next].id
        }
        scrollKeyboardFocus()
    }

    /// 记录鼠标点击行：让键盘选择与鼠标操作保持同一“当前行”（点到的行必然可见，无需滚动）
    private func markKeyboardFocus(_ treeID: String) {
        keyboardFocusedTreeID = treeID
    }

    /// 让 ScrollView 把键盘选择行滚动到可视区顶部（复用列表页 scrollTarget 通道）
    private func scrollKeyboardFocus() {
        guard let id = keyboardFocusedTreeID else { return }
        model.scrollTargetTreeID = id
    }

    /// 键盘删除当前行（是否二次确认仍由 requestDelete 统一决策）
    private func deleteFocusedTree() {
        guard let id = keyboardFocusedTreeID,
              let row = model.rows.first(where: { $0.id == id }) else { return }
        requestDelete(
            DeleteRequest(
                kind: .trees,
                treeID: id,
                chunkID: nil,
                treeChunkCount: row.tree.chunks.count
            )
        )
    }

    // MARK: - 顶部工具栏

    private var topToolbar: some View {
        VStack(spacing: 0) {
            titleBar
            // 快捷动作行只在主列表展示，避免在编辑器/设置等场景下出现无关全局操作
            if model.viewMode == .list {
                if multiSelectActive {
                    multiSelectHintRow
                } else {
                    inputRow
                }
            }
        }
    }

    // MARK: - macOS 红绿灯（关闭 / 最小化）

    /// 置于标题栏最左侧（应用图标左侧），样式对齐系统红绿灯
    private var trafficLights: some View {
        HStack(spacing: 8) {
            TrafficLightButton(
                color: Color(red: 1.0, green: 0.35, blue: 0.33),
                stroke: Color(red: 0.87, green: 0.26, blue: 0.24),
                glyph: "xmark",
                glyphSize: 5.5,
                glyphWeight: .black,
                help: "关闭面板（应用继续驻留菜单栏，可随时打开）",
                action: { closePanel() }
            )
            TrafficLightButton(
                color: Color(red: 1.0, green: 0.74, blue: 0.18),
                stroke: Color(red: 0.85, green: 0.62, blue: 0.14),
                glyph: "minus",
                glyphSize: 7.5,
                glyphWeight: .black,
                help: "最小化",
                action: { minimizePanel() }
            )
        }
        .padding(.trailing, 2)
    }

    private func closePanel() {
        (NSApp.delegate as? AppDelegate)?.hidePanel()
    }

    private func minimizePanel() {
        (NSApp.delegate as? AppDelegate)?.minimizePanel()
    }

    /// 位置 1：应用图标 + 名称；位置 2：GitHub 开源仓库入口
    private var titleBar: some View {
        HStack(spacing: 6) {
            trafficLights

            Image(nsImage: appIconImage())
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 18, height: 18)
                .cornerRadius(4)
            Text("\(AppInfo.zhName) \(AppInfo.enName)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary)
            Spacer(minLength: 0)
            Button(action: { model.showSettings() }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .focusable(false)
            .help("设置（快捷键 / 数据 / 同步）")

            Button(action: openGitHub) {
                Label("开源仓库", systemImage: "globe")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .focusable(false)
            .help("访问 GitHub 开源仓库")
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    /// 顶部快捷行：搜索入口 + 新建。主列表页唯二的全局动作，避免重复/拥挤。
    /// 搜索入口呈现为“搜索框”样式，点击跳转到搜索界面并聚焦输入框。
    private var inputRow: some View {
        HStack(spacing: 8) {
            Button(action: openSearchPage) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                    Text("搜索本地记录…")
                        .font(.system(size: 13))
                    Spacer(minLength: 0)
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.secondary.opacity(0.07))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.secondary.opacity(0.16), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .keyboardShortcut("f", modifiers: .command)
            .help("打开搜索界面（⌘F）")

            Button(action: { model.showNewRecord() }) {
                Label("新建记录", systemImage: "doc.badge.plus")
            }
            .keyboardShortcut("n", modifiers: .command)
            .help("新建一条记录（⌘N）")

            Button(action: enterMultiSelect) {
                Label("多选", systemImage: "checkmark.circle")
            }
            .controlSize(.small)
            .help("进入多选：批量勾选记录后一并删除")
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 6)
    }

    /// 多选模式下的顶部提示行（替代搜索/新建行，避免误触发页面切换）
    private var multiSelectHintRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.accentColor)
            Text("多选模式：点行首圆圈勾选记录")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text("已选 \(selectedTreeIDs.count) 条")
                .font(.caption2)
                .foregroundColor(.secondary)
            Button("完成", action: exitMultiSelect)
                .controlSize(.small)
                .help("退出多选模式（ESC）")
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 6)
    }

    /// 打开搜索界面（顶部搜索入口与底部“搜索”按钮共用）
    private func openSearchPage() {
        searchText = ""
        searchHasRun = false
        searchWork?.cancel()
        model.showSearch()
        searchFieldFocused = true
    }

    private func appIconImage() -> NSImage {
        if let img = NSImage(named: NSImage.applicationIconName) { return img }
        if let img = NSImage(systemSymbolName: "tree",
                             accessibilityDescription: AppInfo.zhName) { return img }
        return NSImage(size: NSSize(width: 18, height: 18))
    }

    private func openGitHub() {
        guard let url = URL(string: "https://github.com/zhyr/Perch") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - 主内容区：列表 / 空状态

    private var listArea: some View {
        let hoverEnabled = !model.scrollInProgress
        return Group {
            if model.rows.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 30))
                        .foregroundColor(.secondary)
                    Text("暂无记录")
                        .font(.title3)
                    Text("在任意应用中复制文字或图片，会自动按 60 秒窗口归并成一条记录；也可以手动新建。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    Button {
                        model.showNewRecord()
                    } label: {
                        Label("新建一条记录", systemImage: "doc.badge.plus")
                    }
                    .controlSize(.small)
                    Text("快捷键：⌘N 新建 · ⌘F 搜索 · 列表内 ↑↓ 选择 / 回车复制 / 空格展开 / X 归档 / ⌫ 删除")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(model.rows) { row in
                            TreeRowView(
                                row: row,
                                isExpanded: model.expandedTreeID == row.id,
                                isHovered: hoveredTreeID == row.id,
                                isKeyboardSelected: keyboardFocusedTreeID == row.id,
                                isMultiSelecting: multiSelectActive,
                                isSelected: selectedTreeIDs.contains(row.id),
                                hoveredChunkID: hoveredChunkID,
                                highlightedChunkID: model.highlightedChunkID,
                                isAddingChunk: chunkDraftTreeID == row.id,
                                chunkDraft: $chunkDraftText,
                                onToggle: {
                                    markKeyboardFocus(row.id)
                                    withAnimation(.easeInOut(duration: 0.16)) {
                                        model.toggleExpanded(row.id)
                                    }
                                },
                                onToggleSelect: {
                                    toggleRowSelection(row.id)
                                },
                                onToggleSelectAllInPage: {
                                    toggleSelectCurrentPage()
                                },
                                onCopyTree: {
                                    markKeyboardFocus(row.id)
                                    model.copyTree(row.id)
                                },
                                onCopyRecord: {
                                    markKeyboardFocus(row.id)
                                    model.copyRecord(row.id)
                                },
                                onCopyChunk: { cid in
                                    markKeyboardFocus(row.id)
                                    model.copyChunk(cid)
                                },
                                onArchive: {
                                    markKeyboardFocus(row.id)
                                    model.toggleArchiveTree(row.id)
                                },
                                onDeleteTree: {
                                    markKeyboardFocus(row.id)
                                    requestDelete(
                                        DeleteRequest(
                                            kind: .trees,
                                            treeID: row.id,
                                            chunkID: nil,
                                            treeChunkCount: row.tree.chunks.count
                                        )
                                    )
                                },
                                onDeleteChunk: { cid in
                                    markKeyboardFocus(row.id)
                                    requestDelete(
                                        DeleteRequest(
                                            kind: .chunk,
                                            treeID: row.id,
                                            chunkID: cid,
                                            treeChunkCount: row.tree.chunks.count
                                        )
                                    )
                                },
                                onStartAddChunk: {
                                    markKeyboardFocus(row.id)
                                    withAnimation(.easeInOut(duration: 0.16)) {
                                        model.toggleExpanded(row.id)
                                    }
                                    chunkDraftTreeID = row.id
                                    chunkDraftText = ""
                                },
                                onSaveChunk: {
                                    if model.manualAppendToTree(row.id, content: chunkDraftText) {
                                        chunkDraftTreeID = nil
                                        chunkDraftText = ""
                                    }
                                },
                                onCancelChunk: {
                                    chunkDraftTreeID = nil
                                    chunkDraftText = ""
                                },
                                onHoverChanged: { hov in
                                    guard hoverEnabled else { return }
                                    hoveredTreeID = hov ? row.id : nil
                                },
                                onChunkHover: { cid, hov in
                                    guard hoverEnabled else { return }
                                    hoveredChunkID = hov ? cid : nil
                                }
                            )
                            .id(row.id)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: model.scrollTargetTreeID) { treeID in
                    guard let treeID else { return }
                    let p = proxy
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                        p.scrollTo(treeID, anchor: .top)
                        model.consumeScrollTarget()
                    }
                }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onPreferenceChange(TreeHoverFrameKey.self) { hoverTreeFrame = $0 }
        .onPreferenceChange(ChunkHoverFrameKey.self) { hoverChunkFrame = $0 }
    }

    // MARK: - 底部导航条（仅主列表展示）

    /// 多选模式下的批量操作条：全选本页 / 已选计数 / 批量删除 / 完成
    private var multiSelectBar: some View {
        HStack(spacing: 10) {
            Button(action: toggleSelectCurrentPage) {
                Text(currentPageAllSelected ? "取消全选本页" : "全选本页")
            }
            .disabled(model.rows.isEmpty)
            .help(currentPageAllSelected
                  ? "清空当前页的勾选"
                  : "勾选本页全部记录（⌘A）")

            Spacer(minLength: 4)

            Text("已选 \(selectedTreeIDs.count) 条")
                .font(.caption)
                .foregroundColor(.secondary)

            Button("删除所选", role: .destructive, action: confirmDeleteSelection)
                .disabled(selectedTreeIDs.isEmpty)
                .help("删除所有已勾选的记录（需确认）")

            Button("完成", action: exitMultiSelect)
                .keyboardShortcut(.cancelAction)
                .help("退出多选模式（ESC）")
        }
        .controlSize(.small)
        .padding(.leading, 12)
        .padding(.trailing, 26) // 右侧预留右下角缩放手柄
        .padding(.vertical, 6)
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Button {
                model.goNewer()
            } label: {
                Label("较新", systemImage: "chevron.left")
            }
            .disabled(!model.hasNewer)
            .help("切到更新的记录")

            Spacer(minLength: 4)

            // 日期中心按钮：点击 mm/dd 周几 文本弹出“日期跳转目录”，在深翻页后也可一键回最新
            let jumpable = model.dayJumpItems.count > 1
            VStack(spacing: 2) {
                Text(model.dayTitle).font(.headline)
                Text(model.dayMetaText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if jumpable {
                    showDayJump = true
                } else {
                    model.goToNewestPage()
                }
            }
            .help(jumpable
                  ? "点按跳转日期"
                  : "回到最新记录所在的一屏")
            .opacity(jumpable || model.hasNewer ? 1 : 0.55)

            Spacer(minLength: 4)

            Button {
                model.goOlder()
            } label: {
                Label("较旧", systemImage: "chevron.right")
            }
            .disabled(!model.hasOlder)
            .help("切到更旧的记录")
        }
        .controlSize(.small)
        .padding(.leading, 12)
        .padding(.trailing, 26) // 右侧预留右下角缩放手柄
        .padding(.vertical, 6)
    }

    // MARK: - 轻量浮层提示（不影响布局）

    @ViewBuilder
    private var toastView: some View {
        if let t = model.lastToast {
            Text(t)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(Color.black.opacity(0.72)))
                .padding(.bottom, 10)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - 新建 maintree 编辑区

    private func clearNewRecordDraft() {
        newTitle = ""
        newContent = ""
        newTitleFocused = false
        newContentFocused = false
    }

    private var newRecordEditor: some View {
        VStack(spacing: 0) {
            HStack {
                Text("新建记录")
                    .font(.headline)
                Spacer()
                Button("取消") {
                    cancelNewRecordEditing()
                }
                .keyboardShortcut(.cancelAction)
                .help("放弃草稿并返回（ESC）")
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            VStack(spacing: 10) {
                TextField("标题（可选）", text: $newTitle)
                    .textFieldStyle(.roundedBorder)
                    .focused($newTitleFocused)
                    .onSubmit { newContentFocused = true }

                ZStack(alignment: .topLeading) {
                    TextEditor(text: $newContent)
                        .font(.system(size: 13))
                        .frame(minHeight: 180)
                        .focused($newContentFocused)
                    if newContent.isEmpty {
                        Text("在此输入记录内容…")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                            .padding(.top, 6)
                            .padding(.leading, 4)
                            .allowsHitTesting(false)
                    }
                }
            }
            .padding(.horizontal, 12)

            HStack {
                Spacer()
                Button("保存") {
                    if model.createNewRecord(title: newTitle, content: newContent) {
                        newTitle = ""
                        newContent = ""
                        newTitleFocused = false
                        newContentFocused = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            .padding(.top, 8)

            Spacer()
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            // 面板为非激活型，延迟一拍让 window/keyWindow 就绪后再聚焦
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                newTitleFocused = true
            }
        }
    }

    // MARK: - 搜索区

    private var searchResultsView: some View {
        VStack(spacing: 0) {
            searchBar

            if model.searchResults.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: searchHasRun ? "magnifyingglass" : "text.magnifyingglass")
                        .font(.system(size: 30))
                        .foregroundColor(.secondary)
                    Text(searchHasRun ? "没有找到与“\(searchText)”相关的记录" : "输入关键词后自动搜索本地记录")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                    if searchHasRun {
                        Text("可尝试更短的关键词，搜索会同时匹配分段内容与记录标题")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundColor(.accentColor)
                            Text("找到 \(model.searchResults.count) 条匹配结果")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)

                        ForEach(model.searchResults) { vm in
                            Button {
                                model.openSearchResult(
                                    treeID: vm.result.treeID,
                                    chunkID: vm.result.chunkID
                                )
                                searchText = ""
                                searchHasRun = false
                                searchWork?.cancel()
                            } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(vm.treeTitle)
                                            .font(.system(size: 13, weight: .medium))
                                            .lineLimit(1)
                                        Text(vm.chunkPreview)
                                            .font(.system(size: 12))
                                            .lineLimit(1)
                                            .foregroundColor(.secondary)
                                        Text(vm.caption)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                        .padding(.top, 2)
                                }
                                .padding(8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 2)
                    .padding(.bottom, 8)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { searchFieldFocused = true }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Button {
                model.exitSearch()
                searchText = ""
                searchHasRun = false
                searchWork?.cancel()
            } label: {
                Label("返回", systemImage: "chevron.left")
            }
            .keyboardShortcut(.cancelAction)
            .help("返回主列表（ESC）")

            TextField("搜索本地记录…", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .focused($searchFieldFocused)
                .onSubmit {
                    runSearchNow(searchText)
                }
                .onChange(of: searchText) { _ in
                    scheduleSearch(searchText)
                }

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    searchWork?.cancel()
                    searchHasRun = false
                    model.searchResults = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("清空")
            }

            Button("搜索") {
                runSearchNow(searchText)
            }
            .disabled(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    /// 手动/回车触发：立即搜索，取消排队中的防抖任务
    private func runSearchNow(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        searchWork?.cancel()
        searchHasRun = !t.isEmpty
        guard !t.isEmpty else {
            model.searchResults = []
            return
        }
        model.performSearch(text)
    }

    /// 输入即搜：防抖 260ms 后执行，避免高频按键压力
    private func scheduleSearch(_ text: String) {
        searchWork?.cancel()
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else {
            searchHasRun = false
            model.searchResults = []
            return
        }
        let item = DispatchWorkItem { [weak model] in
            guard let model else { return }
            searchHasRun = true
            model.performSearch(text)
        }
        searchWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26, execute: item)
    }

    // MARK: - 设置区

    private var settingsPanel: some View {
        SettingsView(
            model: model,
            onRequestClearAll: {
                confirmDelete = DeleteRequest(
                    kind: .all,
                    treeID: "",
                    chunkID: nil,
                    treeChunkCount: 0
                )
            }
        )
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - 丢弃草稿确认弹层

/// 新建记录编辑器存在未保存内容时，取消/ESC 离开前给出确认，防止误触丢失输入。
private struct DiscardDraftDialog: View {
    let onContinue: () -> Void
    let onDiscard: () -> Void

    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.orange)
                Text("放弃未保存的内容？")
                    .font(.system(size: 14, weight: .semibold))
            }

            Text("离开后将丢弃尚未保存的标题与正文。若想保留，请选择“继续编辑”并点击保存。")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("继续编辑", action: onContinue)
                    .keyboardShortcut(.cancelAction)
                Button("放弃草稿", role: .destructive, action: onDiscard)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
            .padding(.top, 6)
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.2), radius: 18, x: 0, y: 8)
        .scaleEffect(appeared ? 1 : 0.94)
        .opacity(appeared ? 1 : 0)
        .onAppear { appeared = true }
    }
}

// MARK: - 删除确认弹层

/// 与系统 Alert 对齐习惯一致的自定义确认卡：标题与说明均左对齐，操作按钮位于右下角。
/// 用于“删除记录 / 删除分段 / 清空全部”的二次确认。
private struct DeleteConfirmDialog: View {
    let request: DeleteRequest
    let onCancel: () -> Void
    let onConfirm: () -> Void

    @State private var appeared = false

    private var titleText: String {
        switch request.kind {
        case .trees:
            return request.treeIDs.count > 1 ? "删除所选 \(request.treeIDs.count) 条记录？" : "删除该记录？"
        case .chunk: return "删除该分段？"
        case .all: return "清空全部数据？"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "trash")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.red)
                Text(titleText)
                    .font(.system(size: 14, weight: .semibold))
            }

            Text(request.message)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("删除", role: .destructive, action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
            .padding(.top, 6)
        }
        .padding(16)
        .frame(width: 300, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.2), radius: 18, x: 0, y: 8)
        .scaleEffect(appeared ? 1 : 0.94)
        .opacity(appeared ? 1 : 0)
        .onAppear { appeared = true }
    }
}

// MARK: - 悬停浮层卡片

private struct HoverCard: View {
    let title: String?
    let text: String
    let targetFrame: CGRect
    let containerFrame: CGRect

    private var cardW: CGFloat { targetFrame.width }
    private var maxCardH: CGFloat { 320 }

    /// 文本在自然换行下的高度，额外加一行空白
    private func textHeight(width: CGFloat) -> CGFloat {
        guard width > 0, !text.isEmpty else { return 0 }
        let attr = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: 12)]
        )
        let rect = attr.boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return ceil(rect.height)
    }

    private var cardH: CGFloat {
        let horizontalPadding: CGFloat = 16
        let verticalPadding: CGFloat = 16
        let titleH: CGFloat = title != nil ? 15 : 0
        let dividerH: CGFloat = title != nil ? 3 : 0
        let extraLine: CGFloat = 14
        let contentW = max(cardW - horizontalPadding, 0)
        let total = verticalPadding + titleH + dividerH + textHeight(width: contentW) + extraLine
        return min(max(total, 44), maxCardH)
    }

    var body: some View {
        let x = targetFrame.minX - containerFrame.minX
        let belowY = targetFrame.maxY - containerFrame.minY + 4
        let aboveY = targetFrame.minY - containerFrame.minY - cardH - 4
        let showBelow = targetFrame.maxY + cardH + 4 <= containerFrame.maxY

        VStack(alignment: .leading, spacing: 4) {
            if let title = title {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Divider().padding(.vertical, 1)
            }
            if cardH >= maxCardH {
                ScrollView {
                    Text(text)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text(text)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(8)
        .frame(width: cardW, height: cardH, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 8, x: 0, y: 4)
        .offset(x: x, y: showBelow ? belowY : aboveY)
        .allowsHitTesting(false)
    }
}

// MARK: - 行视图

private struct TreeRowView: View {
    let row: TreeRowVM
    let isExpanded: Bool
    let isHovered: Bool
    let isKeyboardSelected: Bool
    /// 是否处于列表多选模式（此时行主体点击 = 勾选，而非复制）
    let isMultiSelecting: Bool
    /// 多选模式下该行是否已被勾选
    let isSelected: Bool
    let hoveredChunkID: String?
    let highlightedChunkID: String?
    let isAddingChunk: Bool
    @Binding var chunkDraft: String
    @FocusState private var addChunkFocused: Bool
    let onToggle: () -> Void
    let onToggleSelect: () -> Void
    let onToggleSelectAllInPage: () -> Void
    let onCopyTree: () -> Void
    let onCopyRecord: () -> Void
    let onCopyChunk: (String) -> Void
    let onArchive: () -> Void
    let onDeleteTree: () -> Void
    let onDeleteChunk: (String) -> Void
    let onStartAddChunk: () -> Void
    let onSaveChunk: () -> Void
    let onCancelChunk: () -> Void
    let onHoverChanged: (Bool) -> Void
    let onChunkHover: (String?, Bool) -> Void

    /// 操作按钮仅在 悬停 / 展开 / 键盘选中 时展示，日常浏览保持简洁
    private var showActions: Bool { isHovered || isExpanded || isKeyboardSelected }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 6) {
                // 多选模式：最左侧显示勾选框；focusable(false) 防止刚进入多选时首行圆圈因焦点环误显示为蓝色
                if isMultiSelecting {
                    Button(action: onToggleSelect) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(isSelected ? Color.accentColor : Color.secondary)
                            .frame(width: 15)
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .padding(.top, 3)
                    .help(isSelected ? "取消选中该记录" : "选中该记录")
                }

                Button(action: onToggle) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                        .frame(width: 14)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .padding(.top, 4)

                // 左侧主内容：多选模式下点击切换勾选；平时单击复制整棵记录
                VStack(alignment: .leading, spacing: 3) {
                    primaryText
                    Text(row.caption)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .strikethrough(row.tree.isArchived)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(perform: isMultiSelecting ? onToggleSelect : onCopyTree)
                .help(isMultiSelecting
                      ? (isSelected ? "已选中：点击可取消勾选（空格）" : "点击勾选该记录（空格）")
                      : "单击复制整棵记录（标题 + 全部分段）；右键可展开 / 归档 / 删除等")

                // 行内操作仅在悬停 / 展开 / 键盘选中时展示，避免日常浏览被按钮占满
                // 多选模式下隐藏单行操作，避免与批量勾选语义冲突（右键菜单仍可用）
                if showActions && !isMultiSelecting {
                    HStack(spacing: 8) {
                        Button(action: onArchive) {
                            Image(systemName: row.tree.isArchived ? "archivebox.fill" : "archivebox")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.plain)
                        .focusable(false)
                        .foregroundColor(row.tree.isArchived ? .accentColor : .secondary)
                        .help(row.tree.isArchived ? "取消归档（快捷键 X）" : "归档（快捷键 X）")

                        Button(action: onDeleteTree) {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .focusable(false)
                        .foregroundColor(.secondary)
                        .help("删除该记录及其下全部分段（快捷键 ⌫）")

                        Button(action: onStartAddChunk) {
                            Image(systemName: "plus")
                                .font(.system(size: 12, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .focusable(false)
                        .foregroundColor(.secondary)
                        .help("在该记录末尾追加分段")
                    }
                    .padding(.top, 2)
                    .transition(.opacity)
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(rowBackgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        isKeyboardSelected ? Color.accentColor.opacity(0.6) : Color.clear,
                        lineWidth: 1
                    )
            )
            .background(treeHoverGeometry)
            .opacity(row.tree.isArchived ? 0.55 : 1.0)
            .onHover { hov in onHoverChanged(hov) }
            .contextMenu {
                rowContextMenu
            }
            .animation(.easeInOut(duration: 0.12), value: isHovered)
            .animation(.easeInOut(duration: 0.12), value: isKeyboardSelected)

            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(row.chunks) { c in
                        chunkRow(c)
                    }
                    if isAddingChunk {
                        addChunkInline
                    }
                }
                .padding(.leading, 24)
                .padding(.bottom, 6)
                .padding(.trailing, 8)
                .transition(.opacity)
            }
        }
    }

    /// 行底色：多选已勾选 > 键盘选中 > 鼠标悬停 > 无状态
    private var rowBackgroundColor: Color {
        if isMultiSelecting, isSelected { return Color.accentColor.opacity(0.16) }
        if isKeyboardSelected { return Color.accentColor.opacity(0.16) }
        if isHovered { return Color.accentColor.opacity(0.10) }
        return Color.clear
    }

    @ViewBuilder
    private var rowContextMenu: some View {
        if isMultiSelecting {
            Button(isSelected ? "取消选中" : "选中该记录", action: onToggleSelect)
            Button("全选本页", action: onToggleSelectAllInPage)
            Divider()
        }
        Button(isExpanded ? "折叠" : "展开", action: onToggle)
        Button("复制整棵记录", action: onCopyTree)
        Button("复制最新分段内容", action: onCopyRecord)
            .disabled(row.tree.latest == nil)
        Divider()
        Button("追加分段…", action: onStartAddChunk)
        Button(row.tree.isArchived ? "取消归档" : "归档", action: onArchive)
        Divider()
        Button("删除记录…", role: .destructive, action: onDeleteTree)
    }

    private var treeHoverGeometry: some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: TreeHoverFrameKey.self,
                value: isHovered ? geo.frame(in: .global) : nil
            )
        }
    }

    @ViewBuilder
    private var primaryText: some View {
        if let title = row.titleText {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .strikethrough(row.tree.isArchived)
        } else {
            Text(row.preview)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
                .strikethrough(row.tree.isArchived)
        }
    }

    private func chunkRow(_ c: ChunkRowVM) -> some View {
        let hov = hoveredChunkID == c.id
        let highlighted = highlightedChunkID == c.id
        return HStack(alignment: .top, spacing: 6) {
            Button {
                onCopyChunk(c.id)
            } label: {
                HStack(alignment: .top, spacing: 6) {
                    Circle()
                        .fill(Color.accentColor.opacity(0.55))
                        .frame(width: 5, height: 5)
                        .padding(.top, 7)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.preview)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(c.caption)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("复制该分段内容")

            Spacer(minLength: 0)

            if hov {
                Button {
                    onDeleteChunk(c.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .focusable(false)
                .foregroundColor(.secondary)
                .help("删除该分段")
                .padding(.trailing, 2)
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(highlighted ? Color.accentColor.opacity(0.25) : (hov ? Color.accentColor.opacity(0.08) : Color.clear))
        )
        .background(chunkHoverGeometry(for: c, hovered: hov))
        .onHover { hov in onChunkHover(c.id, hov) }
        .contextMenu {
            Button("复制该分段", action: { onCopyChunk(c.id) })
            Button("删除该分段", role: .destructive, action: { onDeleteChunk(c.id) })
                .disabled(row.chunks.count <= 1)
        }
    }

    private func chunkHoverGeometry(for c: ChunkRowVM, hovered: Bool) -> some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: ChunkHoverFrameKey.self,
                value: hovered ? geo.frame(in: .global) : nil
            )
        }
    }

    private var addChunkInline: some View {
        HStack(spacing: 8) {
            TextField("新分段内容…", text: $chunkDraft)
                .textFieldStyle(.roundedBorder)
                .focused($addChunkFocused)
                .onSubmit { onSaveChunk() }
                .onAppear {
                    DispatchQueue.main.async {
                        addChunkFocused = true
                    }
                }
            Button("保存") { onSaveChunk() }
                .keyboardShortcut(.defaultAction)
                .disabled(chunkDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("取消") { onCancelChunk() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.vertical, 4)
        .padding(.leading, 8)
    }
}

// MARK: - macOS 红绿灯按钮

private struct TrafficLightButton: View {
    let color: Color
    let stroke: Color
    let glyph: String
    let glyphSize: CGFloat
    let glyphWeight: Font.Weight
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color)
            Circle()
                .stroke(stroke, lineWidth: 0.75)
            if hovering {
                Image(systemName: glyph)
                    .font(.system(size: glyphSize, weight: glyphWeight))
                    .foregroundColor(.black.opacity(0.55))
            }
        }
        .frame(width: 12, height: 12)
        .contentShape(Circle())
        .onHover { hovering = $0 }
        .onTapGesture { action() }
        .help(help)
    }
}

