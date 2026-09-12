import Carbon
import Cocoa

/// 基于 Carbon RegisterEventHotKey 的全局快捷键管理
/// 适用于 LSUIElement / accessory 类 macOS App
final class HotkeyManager {
    static let shared = HotkeyManager()

    private var eventHandler: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?
    private var action: (() -> Void)?

    private init() {}

    /// 注册全局快捷键。返回是否注册成功——失败通常意味着该组合已被系统或其它应用占用，
    /// 调用方必须据此给出反馈，避免出现「设置了快捷键却永远不触发」的静默失效。
    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) -> Bool {
        unregister()
        self.action = action

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let userData = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyCallback,
            1,
            &eventType,
            userData,
            &eventHandler
        )
        guard installStatus == noErr else {
            self.eventHandler = nil
            self.action = nil
            return false
        }

        let hotKeyID = EventHotKeyID(
            signature: FourCharCode("PERH") ?? 0,
            id: 1
        )
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard registerStatus == noErr else {
            // 注册失败：回收事件处理器与回调，避免留下永不触发的死状态
            if let eventHandler = eventHandler {
                RemoveEventHandler(eventHandler)
                self.eventHandler = nil
            }
            self.hotKeyRef = nil
            self.action = nil
            return false
        }
        return true
    }

    func unregister() {
        if let hotKeyRef = hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandler = eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        action = nil
    }

    fileprivate func invoke() {
        action?()
    }
}

private let hotKeyCallback: EventHandlerUPP = { _, _, userData -> OSStatus in
    guard let userData = userData else { return noErr }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    DispatchQueue.main.async {
        manager.invoke()
    }
    return noErr
}

extension NSEvent.ModifierFlags {
    /// 转换为 Carbon 修饰符常量（RegisterEventHotKey 所需）
    var carbonModifiers: UInt32 {
        var carbon: UInt32 = 0
        if contains(.command) { carbon |= UInt32(cmdKey) }
        if contains(.shift)   { carbon |= UInt32(shiftKey) }
        if contains(.option)  { carbon |= UInt32(optionKey) }
        if contains(.control) { carbon |= UInt32(controlKey) }
        return carbon
    }
}

/// 将 keyCode 映射为可显示的字符（仅覆盖常见 ANSI 键）
func keyCodeDisplayName(_ keyCode: UInt32) -> String {
    let map: [UInt32: String] = [
        // 字母
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        31: "O", 32: "U", 34: "I", 35: "P", 37: "J", 38: "L", 40: "K", 45: "N", 46: "M",
        // 数字
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
        26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 33: "[", 39: "'", 41: ";", 42: "\\",
        43: ",", 44: "/", 47: ".",
        // 功能/特殊
        49: "Space", 36: "↩", 48: "Tab", 51: "⌫", 53: "Esc",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
    return map[keyCode] ?? "Key \(keyCode)"
}

/// 将存储的 keyCode + modifiers 渲染为 "⌃⇧P" 这类字符串
func shortcutDisplayString(keyCode: UInt32, modifiers: UInt32) -> String {
    var result = ""
    if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
    if modifiers & UInt32(optionKey)  != 0 { result += "⌥" }
    if modifiers & UInt32(shiftKey)   != 0 { result += "⇧" }
    if modifiers & UInt32(cmdKey)     != 0 { result += "⌘" }
    result += keyCodeDisplayName(keyCode)
    return result
}
