import SwiftUI
import AppKit
import Carbon

/// 设置页：整页布局（不再使用居中小卡片），所有说明文字统一左对齐，
/// 行内辅助控件统一放在右侧，保持与主界面一致的视觉节奏。
struct SettingsView: View {
    @ObservedObject var model: AppModel
    /// 由外层 ContentView 传入：打开“清空全部”的二次确认弹层（与删除确认同一套 UI）
    let onRequestClearAll: () -> Void
    @State private var isRecording = false
    @State private var eventMonitor: Any?

    // AI 打标签配置（键与 AppModel.AIConfigKey 保持一致）
    @AppStorage(AppModel.AIConfigKey.provider) private var aiProvider = 0
    @AppStorage(AppModel.AIConfigKey.cloudBase) private var cloudBase = AIProviderPreset.cloud.defaultBaseURL
    @AppStorage(AppModel.AIConfigKey.cloudModel) private var cloudModel = AIProviderPreset.cloud.defaultModel
    /// API Key 存 Keychain，不再用 @AppStorage，避免明文写进 UserDefaults
    @State private var cloudKey = ""
    @State private var cloudKeySaveTask: Task<Void, Never>?
    @AppStorage(AppModel.AIConfigKey.ollamaBase) private var ollamaBase = AIProviderPreset.ollama.defaultBaseURL
    @AppStorage(AppModel.AIConfigKey.ollamaModel) private var ollamaModel = AIProviderPreset.ollama.defaultModel
    @AppStorage(AppModel.AIConfigKey.mlxBase) private var mlxBase = AIProviderPreset.mlx.defaultBaseURL
    @AppStorage(AppModel.AIConfigKey.mlxModel) private var mlxModel = AIProviderPreset.mlx.defaultModel

    @State private var aiTestResult: String?
    @State private var isTestingAI = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    shortcutSection
                    recordingSection
                    aiSection
                    generalSection
                    syncSection
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { cloudKey = AppModel.cloudAPIKey() }
        .onChange(of: cloudKey) { newValue in
            // 400ms 防抖，避免每敲一个字符就写一次钥匙串
            cloudKeySaveTask?.cancel()
            cloudKeySaveTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                if !AppModel.setCloudAPIKey(newValue) {
                    model.showToast("API Key 写入钥匙串失败，请检查钥匙串访问权限")
                }
            }
        }
        .onChange(of: isRecording) { recording in
            if recording {
                startRecording()
            } else {
                stopRecording()
            }
        }
        .onDisappear {
            stopRecording()
        }
    }

    // MARK: - 顶部栏

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "gearshape")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            Text("设置")
                .font(.system(size: 14, weight: .semibold))
            Spacer(minLength: 0)
            Button("返回") {
                model.backFromSettings()
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    // MARK: - 全局快捷键

    private var shortcutSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("全局快捷键")

            Button {
                isRecording.toggle()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .frame(width: 16)

                    Text(isRecording ? "请按下新的快捷键…" : shortcutText)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    if isRecording {
                        ProgressView()
                            .controlSize(.small)
                        Text("监听中")
                            .font(.caption)
                            .foregroundColor(.accentColor)
                    } else {
                        Text("更改")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isRecording
                              ? Color.accentColor.opacity(0.12)
                              : Color.secondary.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(isRecording
                                ? Color.accentColor.opacity(0.4)
                                : Color.clear, lineWidth: 1)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text("按下“Command/Control/⌥/⇧ + 字母键”组合以打开 / 隐藏 \(AppInfo.zhName) 面板")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - 启动与记录

    private var recordingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("启动与记录")

            HStack(spacing: 10) {
                Image(systemName: "power")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text("开机自启动")
                        .font(.system(size: 13))
                    Text(model.launchAtLoginEnabled
                         ? "已开启：登录后自动启动栖痕"
                         : "已关闭：需手动启动栖痕")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer(minLength: 8)

                Toggle(
                    "",
                    isOn: Binding(
                        get: { model.launchAtLoginEnabled },
                        set: { model.setLaunchAtLogin($0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!Self.canManageLoginItem)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
            )

            HStack(spacing: 10) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text("自动记录剪贴板")
                        .font(.system(size: 13))
                    Text(model.autoRecordClipboard
                         ? "已开启：外部复制自动保存为记录"
                         : "已关闭：不会自动保存，请使用 ⌘N 新建 / 追加分段手动保存")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer(minLength: 8)

                Toggle(
                    "",
                    isOn: Binding(
                        get: { model.autoRecordClipboard },
                        set: { model.setAutoRecordClipboard($0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
            )
        }
    }

    private static var canManageLoginItem: Bool {
        if #available(macOS 13.0, *) {
            return true
        }
        return false
    }

    // MARK: - 通用

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("通用")


            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text("删除需二次确认")
                        .font(.system(size: 13))
                    Text(model.requireDeleteConfirm
                         ? "已开启：删除记录 / 分段前会先弹出确认"
                         : "已关闭：删除立即生效")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer(minLength: 8)

                Toggle(
                    "",
                    isOn: Binding(
                        get: { model.requireDeleteConfirm },
                        set: { model.setRequireDeleteConfirm($0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
            )

            HStack(spacing: 10) {
                Image(systemName: "trash.slash")
                    .font(.system(size: 12))
                    .foregroundColor(.red)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text("清空全部记录")
                        .font(.system(size: 13))
                        .foregroundColor(.red)
                    Text("删除所有记录与分段，此操作不可恢复")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer(minLength: 8)

                Button("清空", role: .destructive, action: onRequestClearAll)
                    .controlSize(.small)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.red.opacity(0.07))
            )
        }
    }

    // MARK: - AI 自动打标签

    private var aiSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("AI 自动打标签")

            // 服务类型
            HStack(spacing: 10) {
                Image(systemName: "cpu")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(width: 16)
                Text("类型")
                    .font(.system(size: 13))
                Spacer(minLength: 8)
                Picker("", selection: $aiProvider) {
                    Text("云端 API").tag(0)
                    Text("Ollama").tag(1)
                    Text("MLX").tag(2)
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                .labelsHidden()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.secondary.opacity(0.08)))

            // 当前预设的字段
            Group {
                if aiProvider == 0 {
                    configRow(title: "服务地址", text: $cloudBase, placeholder: "https://yueli.com/api/yueliai/v1/completions")
                    configRow(title: "API Key", text: $cloudKey, placeholder: "sk-…（yueli.com/admin/openapi-v1-keys 生成）", secure: true)
                    configRow(title: "模型", text: $cloudModel, placeholder: "freemodel")
                } else if aiProvider == 1 {
                    configRow(title: "服务地址", text: $ollamaBase, placeholder: "http://localhost:11434/v1")
                    configRow(title: "模型", text: $ollamaModel, placeholder: "qwen3.5")
                } else {
                    configRow(title: "服务地址", text: $mlxBase, placeholder: "http://127.0.0.1:8080/v1")
                    configRow(title: "模型", text: $mlxModel, placeholder: "mlx-community/Qwen3-4B-4bit")
                }
            }

            Text("默认走阅粒 Yueli AI（freemodel）云端推理；也兼容任意 OpenAI 兼容 /chat/completions 服务与 /v1/completions 聚合网关，本地 Ollama、Apple Silicon MLX（mlx_lm.server）。")
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // 操作行
            HStack(spacing: 8) {
                Button("测试连接") {
                    testAIConnection()
                }
                .controlSize(.small)
                .disabled(isTestingAI || model.isAutoTagging)

                if model.isAutoTagging {
                    ProgressView()
                        .controlSize(.small)
                    Text(model.aiTagProgressText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Button("停止", action: { model.stopAutoTag() })
                        .controlSize(.small)
                } else {
                    Button("为未打标签的记录打标签") {
                        model.startAutoTagUntaggedTrees()
                        if model.isAutoTagging { model.showSettings() }
                    }
                    .controlSize(.small)
                }

                Spacer(minLength: 0)
            }

            if let result = aiTestResult {
                Text(result)
                    .font(.caption)
                    .foregroundColor(result.contains("失败") ? .red : .secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
        }
    }

    private func configRow(title: String, text: Binding<String>, placeholder: String, secure: Bool = false) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(width: 52, alignment: .leading)
            if secure {
                SecureField(placeholder, text: text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            } else {
                TextField(placeholder, text: text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.secondary.opacity(0.08)))
    }

    private func testAIConnection() {
        isTestingAI = true
        aiTestResult = nil
        // 防抖可能还没落盘，先立即写入，避免测的是旧 Key
        cloudKeySaveTask?.cancel()
        AppModel.setCloudAPIKey(cloudKey)
        let (_, endpoint) = AppModel.currentAIConfig()
        Task {
            do {
                let reply = try await TagAIService.ping(config: endpoint)
                aiTestResult = "连接正常：\(reply.prefix(40))"
            } catch {
                aiTestResult = "连接失败：\(error.localizedDescription)"
            }
            isTestingAI = false
        }
    }

    // MARK: - 数据与同步（iCloud）

    private var syncSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("数据与同步")

            HStack(spacing: 10) {
                Image(systemName: "externaldrive.badge.icloud")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.storageLabel)
                        .font(.system(size: 13))
                    Text(model.storagePathDisplay)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
            )

            HStack(spacing: 8) {
                Button {
                    model.chooseSyncStorageFolder()
                } label: {
                    Label(
                        model.isCustomStorage ? "更换同步文件夹…" : "选择 iCloud Drive 文件夹…",
                        systemImage: "folder.badge.gearshape"
                    )
                }
                .controlSize(.small)

                if model.isCustomStorage {
                    Button("恢复本机存储") {
                        model.restoreLocalStorage()
                    }
                    .controlSize(.small)
                }
            }

            Text("将数据放在 iCloud Drive（或其它同步盘）中同一个文件夹，所有设备会自动共享同一份记录。首次选择会迁移现有数据；切换后如需本机备份请自行拷贝该文件夹。")
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 通用小组件

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.secondary)
            .textCase(.uppercase)
            .tracking(0.4)
    }

    private var shortcutText: String {
        shortcutDisplayString(keyCode: model.shortcutKeyCode, modifiers: model.shortcutModifiers)
    }

    private func startRecording() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.carbonModifiers
            guard mods != 0 else { return event }
            // 只按 ⌘+字母 会与 ⌘C/⌘V/⌘Q/⌘W 等系统与应用通用快捷键冲突：
            // 注册为全局热键后会劫持所有应用，因此要求再叠加 ⌃/⌥/⇧ 中至少一个。
            if mods == UInt32(cmdKey) {
                model.showToast("请再加一个修饰键（⌃ / ⌥ / ⇧），避免与 ⌘C、⌘Q 等冲突")
                return nil
            }
            let code = UInt32(event.keyCode)
            model.updateShortcut(keyCode: code, modifiers: mods)
            isRecording = false
            return nil
        }
    }

    private func stopRecording() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        isRecording = false
    }
}
