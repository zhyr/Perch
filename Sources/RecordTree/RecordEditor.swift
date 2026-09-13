import SwiftUI

// MARK: - 笔记编辑器（新建 / 编辑共用）

/// 把新建与编辑笔记的输入区从 `ContentView` 里拆出来，避免编辑时每一次按键
/// 都触发整个 `ContentView` + 列表的重新渲染，从而解决输入卡顿。
struct RecordEditor: View {
    enum Mode {
        case new
        case edit
    }

    let mode: Mode
    let model: AppModel
    let initialTitle: String
    let initialContent: String
    let onSave: (_ title: String, _ content: String) -> Bool
    let onCancel: () -> Void
    let onDraftChanged: ((Bool) -> Void)?

    @State private var title: String
    @State private var content: String
    /// 上一次已上报给上层（ContentView）的草稿状态。
    /// 只在本值真正翻转时才回调，避免每次按键都把父视图整棵标脏 → 输入卡顿。
    @State private var reportedDraft = false
    @FocusState private var titleFocused: Bool
    @FocusState private var contentFocused: Bool

    private var hasDraft: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(
        mode: Mode,
        model: AppModel,
        initialTitle: String = "",
        initialContent: String = "",
        onSave: @escaping (_ title: String, _ content: String) -> Bool,
        onCancel: @escaping () -> Void,
        onDraftChanged: ((Bool) -> Void)? = nil
    ) {
        self.mode = mode
        self.model = model
        self.initialTitle = initialTitle
        self.initialContent = initialContent
        self.onSave = onSave
        self.onCancel = onCancel
        self.onDraftChanged = onDraftChanged
        _title = State(initialValue: initialTitle)
        _content = State(initialValue: initialContent)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(mode == .new ? "新建笔记" : "编辑笔记")
                    .font(.headline)
                Spacer()
                Button {
                    appendClipboard()
                } label: {
                    Label("追加剪切板", systemImage: "doc.on.clipboard")
                }
                .controlSize(.small)
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .help("将剪切板文本追加到内容末尾（⌘⇧V）；⌘V 则粘贴到光标处")

                Button("取消") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                .help(mode == .new ? "放弃草稿并返回（ESC）" : "放弃修改并返回（ESC）")
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            VStack(spacing: 10) {
                TextField("标题（可选）", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .focused($titleFocused)
                    .onSubmit { contentFocused = true }

                ZStack(alignment: .topLeading) {
                    TextEditor(text: $content)
                        .font(.system(size: 13))
                        .frame(minHeight: 180)
                        .focused($contentFocused)
                    if content.isEmpty {
                        Text(mode == .new ? "在此输入记录内容…" : "在此输入笔记内容…")
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
                    if onSave(title, content) {
                        clear()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            .padding(.top, 8)

            Spacer()
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            // 新建时自动聚焦标题；编辑时保持原样，避免抢占光标打扰用户
            guard mode == .new else { return }
            // 面板为非激活型，延迟一拍让 window/keyWindow 就绪后再聚焦
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                titleFocused = true
            }
        }
        .onChange(of: title) { _ in notifyDraftChanged() }
        .onChange(of: content) { _ in notifyDraftChanged() }
    }

    private func notifyDraftChanged() {
        let draft = hasDraft
        guard draft != reportedDraft else { return }
        reportedDraft = draft
        onDraftChanged?(draft)
    }

    private func appendClipboard() {
        guard let text = model.clipboardText() else { return }
        content += (content.isEmpty ? "" : "\n") + text
    }

    private func clear() {
        title = ""
        content = ""
        titleFocused = false
        contentFocused = false
    }
}
