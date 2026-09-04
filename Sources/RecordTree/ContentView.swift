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
        case tree
        case chunk
        case all
    }
    let kind: Kind
    let treeID: String
    let chunkID: String?
    let treeChunkCount: Int

    var id: String {
        switch kind {
        case .all: return "all"
        case .tree: return treeID
        case .chunk: return chunkID ?? ""
        }
    }

    var message: String {
        switch kind {
        case .tree:
            return "将删除该 maintree record 及其下 \(treeChunkCount) 个 chunk，此操作不可恢复。"
        case .chunk:
            return "将删除该 chunk 分段，此操作不可恢复。"
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

    // 在当前 maintree 后追加 chunk 的草稿
    @State private var chunkDraftTreeID: String?
    @State private var chunkDraftText = ""

    // 删除确认
    @State private var confirmDelete: DeleteRequest?

    // 悬停浮层（全局坐标）
    @State private var hoverTreeFrame: CGRect?
    @State private var hoverChunkFrame: CGRect?
    @State private var listFrame: CGRect = .zero

    // 右下角拖拽缩放
    @State private var resizeStartFrame: NSRect?
    @State private var resizeStartPoint: NSPoint?

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
            .onChange(of: hoveredTreeID) { _ in
                if hoveredTreeID == nil { hoverTreeFrame = nil }
            }
            .onChange(of: hoveredChunkID) { _ in
                if hoveredChunkID == nil { hoverChunkFrame = nil }
            }
            Divider()
            bottomBar
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
        .onChange(of: model.scrollInProgress) { scrolling in
            // 开始滚动即清除旧悬停位，避免滚动结束后残留高亮/预览导致视觉跳变
            guard scrolling else { return }
            hoveredTreeID = nil
            hoveredChunkID = nil
            hoverTreeFrame = nil
            hoverChunkFrame = nil
        }
        .animation(.easeOut(duration: 0.15), value: confirmDelete != nil)
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

    private func performDelete(_ req: DeleteRequest) {
        switch req.kind {
        case .tree:
            model.deleteTree(req.treeID)
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
            // 滚动期间不显示悬停预览，避免卡片随滚动跳变造成视觉抖动
            if !model.scrollInProgress, let hf = hoverFrame, !listFrame.isEmpty, !text.isEmpty {
                HoverCard(
                    title: hoverTitle,
                    text: text,
                    targetFrame: hf,
                    containerFrame: listFrame
                )
            }
        }
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

    // MARK: - 顶部工具栏

    private var topToolbar: some View {
        VStack(spacing: 0) {
            titleBar
            if model.viewMode != .searchResults {
                inputRow
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
            .help("快捷键设置")

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

    /// 顶部快捷行：搜索入口 + 新建 + 全部清空。
    /// 搜索入口呈现为“搜索框”样式，点击与底部“搜索”按钮行为一致：跳转到搜索界面并聚焦输入框。
    private var inputRow: some View {
        HStack(spacing: 8) {
            if model.viewMode != .list {
                Button {
                    model.returnToList()
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("返回主列表")
            }

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
            .help("打开搜索界面")

            Button {
                model.showNewRecord()
            } label: {
                Label("新建 maintree", systemImage: "doc.badge.plus")
            }
            .help("新建一条 maintree record")

            Button {
                confirmDelete = DeleteRequest(
                    kind: .all,
                    treeID: "",
                    chunkID: nil,
                    treeChunkCount: 0
                )
            } label: {
                Label("全部清空", systemImage: "trash.slash")
            }
            .disabled(model.rows.isEmpty)
            .help("一键清空全部记录与分段（需二次确认）")
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
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 30))
                        .foregroundColor(.secondary)
                    Text("暂无记录")
                        .font(.title3)
                    Text("在任何应用中复制内容，会自动按 60 秒窗口归并记录")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.rows) { row in
                            TreeRowView(
                                row: row,
                                isExpanded: model.expandedTreeID == row.id,
                                isHovered: hoveredTreeID == row.id,
                                hoveredChunkID: hoveredChunkID,
                                highlightedChunkID: model.highlightedChunkID,
                                isAddingChunk: chunkDraftTreeID == row.id,
                                chunkDraft: $chunkDraftText,
                                onToggle: { model.toggleExpanded(row.id) },
                                onCopyTree: { model.copyTree(row.id) },
                                onCopyChunk: { model.copyChunk($0) },
                                onArchive: { model.toggleArchiveTree(row.id) },
                                onDeleteTree: {
                                    requestDelete(
                                        DeleteRequest(
                                            kind: .tree,
                                            treeID: row.id,
                                            chunkID: nil,
                                            treeChunkCount: row.tree.chunks.count
                                        )
                                    )
                                },
                                onDeleteChunk: { cid in
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
                                    model.toggleExpanded(row.id)
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
                        }
                    }
                    .padding(8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onPreferenceChange(TreeHoverFrameKey.self) { hoverTreeFrame = $0 }
        .onPreferenceChange(ChunkHoverFrameKey.self) { hoverChunkFrame = $0 }
    }

    // MARK: - 底部导航与操作条

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Button {
                model.goNewer()
            } label: {
                Label("较新", systemImage: "chevron.left")
            }
            .disabled(!model.hasNewer)

            VStack(spacing: 2) {
                Text(model.dayTitle).font(.headline)
                Text(model.dayMetaText).font(.caption).foregroundColor(.secondary)
            }

            Button {
                model.goOlder()
            } label: {
                Label("较旧", systemImage: "chevron.right")
            }
            .disabled(!model.hasOlder)

            Spacer()

            Button {
                model.showNewRecord()
            } label: {
                Label("新建 maintree", systemImage: "doc.badge.plus")
            }

            Button(action: openSearchPage) {
                Label("搜索", systemImage: "magnifyingglass")
            }

            if let t = model.lastToast {
                Text(t)
                    .font(.caption)
                    .foregroundColor(.accentColor)
                    .transition(.opacity)
            }
        }
        .controlSize(.small)
        .padding(.leading, 12)
        .padding(.trailing, 26) // 右侧预留右下角缩放手柄
        .padding(.vertical, 6)
    }

    // MARK: - 新建 maintree 编辑区

    private var newRecordEditor: some View {
        VStack(spacing: 0) {
            HStack {
                Text("新建 maintree record")
                    .font(.headline)
                Spacer()
                Button("取消") {
                    model.cancelNewRecord()
                    newTitle = ""
                    newContent = ""
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            VStack(spacing: 10) {
                TextField("标题（可选）", text: $newTitle)
                    .textFieldStyle(.roundedBorder)

                ZStack(alignment: .topLeading) {
                    TextEditor(text: $newContent)
                        .font(.system(size: 13))
                        .frame(minHeight: 180)
                    if newContent.isEmpty {
                        Text("在此输入 maintree record 的内容…")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                            .padding(.top, 6)
                            .padding(.leading, 4)
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
                    }
                }
                .disabled(newContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            .padding(.top, 8)

            Spacer()
        }
        .background(Color(nsColor: .windowBackgroundColor))
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
        SettingsView(model: model)
            .background(Color(nsColor: .windowBackgroundColor))
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
        case .tree: return "删除该记录？"
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
    let hoveredChunkID: String?
    let highlightedChunkID: String?
    let isAddingChunk: Bool
    @Binding var chunkDraft: String
    let onToggle: () -> Void
    let onCopyTree: () -> Void
    let onCopyChunk: (String) -> Void
    let onArchive: () -> Void
    let onDeleteTree: () -> Void
    let onDeleteChunk: (String) -> Void
    let onStartAddChunk: () -> Void
    let onSaveChunk: () -> Void
    let onCancelChunk: () -> Void
    let onHoverChanged: (Bool) -> Void
    let onChunkHover: (String?, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 6) {
                Button(action: onToggle) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                        .frame(width: 14)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)

                // 左侧主内容：点击整行复制整棵记录
                VStack(alignment: .leading, spacing: 3) {
                    primaryText
                    Text(row.caption)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .strikethrough(row.tree.isArchived)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(perform: onCopyTree)

                // 右侧操作按钮：复制整棵 / 删除 / 归档 / 追加
                HStack(spacing: 8) {
                    Button(action: onCopyTree) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .help("复制整棵记录（标题 + 全部分段，按时序）")

                    Button(action: onDeleteTree) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .help("删除该记录及其下全部 chunk")

                    Button(action: onArchive) {
                        Image(systemName: row.tree.isArchived ? "archivebox.fill" : "archivebox")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(row.tree.isArchived ? .accentColor : .secondary)
                    .help(row.tree.isArchived ? "取消归档" : "归档")

                    Button(action: onStartAddChunk) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .help("在该记录末尾追加 chunk")
                }
                .padding(.top, 2)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.accentColor.opacity(0.10) : Color.clear)
            )
            .background(treeHoverGeometry)
            .opacity(row.tree.isArchived ? 0.55 : 1.0)
            .onHover { hov in onHoverChanged(hov) }

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
            }
        }
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
            Button("保存") { onSaveChunk() }
                .disabled(chunkDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("取消") { onCancelChunk() }
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

