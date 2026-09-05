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

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    shortcutSection
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
