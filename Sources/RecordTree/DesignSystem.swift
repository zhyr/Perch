import SwiftUI
import AppKit

/// 全局设计系统。
///
/// Perch 与 Cella（层隅）共用同一套语义化 token：颜色含义、色值、间距与圆角
/// 在两边保持一致（Cella 侧的同名定义在 `PanelMetrics.swift` 底部）。
/// 所有颜色都提供浅色 / 深色两份值，由当前 `NSAppearance` 动态解析，
/// 因此“跟随系统 / 浅色 / 深色”三态切换都会立即生效。
enum DS {
    enum Color {
        // MARK: 品牌

        /// 科技蓝：主操作、选中、链接
        static let brand = dynamic(0x165DFF, 0x5B8CFF)
        static let brandHover = dynamic(0x0E42D2, 0x7FA8FF)
        static let brandPressed = dynamic(0x0A34A8, 0x4C7DFF)
        /// 主色低饱和底（标签、选中态、浅色提示块）
        static let brandSoft = dynamic(0xE8EFFF, 0x1B2B4A)
        /// 蒂芙尼蓝：强调、辅助高亮
        static let accent = dynamic(0x0ABAB5, 0x2FD3CD)
        static let accentSoft = dynamic(0xE6F8F7, 0x10312F)
        static let accentLight = dynamic(0x81D8D0, 0x81D8D0)

        // MARK: 背景与表面

        /// 窗口底色
        static let background = dynamic(0xF7F8FA, 0x10141C)
        /// 卡片 / 输入框 / 弹层表面
        static let surface = dynamic(0xFFFFFF, 0x1A1F2B)
        /// 次级填充（分组块、搜索框、禁用底）
        static let surfaceAlt = dynamic(0xF3F3F3, 0x232A38)
        /// 悬停态
        static let surfaceHover = dynamic(0xEDF2FF, 0x1E2A40)
        /// 选中态
        static let surfaceSelected = dynamic(0xE1EAFF, 0x233657)
        /// 浮层 / 半透明高光
        static let highlight = dynamic(0xFFFFFF, 0xFFFFFF, lightAlpha: 0.55, darkAlpha: 0.07)

        // MARK: 描边

        static let border = dynamic(0xE3E6EC, 0x2B3345)
        static let borderStrong = dynamic(0xC9CFDA, 0x3A455B)
        static let divider = dynamic(0xECEEF3, 0x232A38)

        // MARK: 文本层级

        static let textPrimary = dynamic(0x10141C, 0xF7F8FA)
        static let textSecondary = dynamic(0x4E5666, 0xA8B0C0)
        static let textTertiary = dynamic(0x6B7280, 0x8A93A5)
        static let textDisabled = dynamic(0xA6ACB8, 0x5C6475)
        static let textOnBrand = SwiftUI.Color.white

        // MARK: 状态色

        static let success = dynamic(0x0B8A2B, 0x2FD35A)
        static let successSoft = dynamic(0xE8F8EC, 0x12301C)
        static let warning = dynamic(0xC2410C, 0xFF9A3D)
        static let warningSoft = dynamic(0xFFF3E8, 0x33230F)
        static let danger = dynamic(0xD92D20, 0xFF7B7B)
        static let dangerSoft = dynamic(0xFEECEC, 0x331A1A)
        static let info = brand

        // MARK: 组件

        static let focusRing = dynamic(0x165DFF, 0x81D8D0)
        static let scrim = dynamic(0x10141C, 0x000000, lightAlpha: 0.32, darkAlpha: 0.55)
        static let shadow = dynamic(0x10141C, 0x000000, lightAlpha: 0.12, darkAlpha: 0.50)
        static let toastBackground = dynamic(0x10141C, 0x1A1F2B, lightAlpha: 0.90, darkAlpha: 0.96)
        static let tagBackground = brandSoft
        static let tagText = dynamic(0x0E42D2, 0x9DBBFF)

        // MARK: 动态解析

        private static func dynamic(
            _ light: UInt32,
            _ dark: UInt32,
            lightAlpha: CGFloat = 1,
            darkAlpha: CGFloat = 1
        ) -> SwiftUI.Color {
            SwiftUI.Color(nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return NSColor(hex: isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
            })
        }
    }

    // MARK: - 间距

    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
    }

    // MARK: - 圆角

    enum Radius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
        static let xl: CGFloat = 16
        static let pill: CGFloat = 999
    }

    // MARK: - 字号

    enum Font {
        static let caption = SwiftUI.Font.system(size: 11)
        static let captionStrong = SwiftUI.Font.system(size: 11, weight: .medium)
        static let body = SwiftUI.Font.system(size: 13)
        static let bodyStrong = SwiftUI.Font.system(size: 13, weight: .semibold)
        static let title = SwiftUI.Font.system(size: 14, weight: .semibold)
        static let titleLarge = SwiftUI.Font.system(size: 17, weight: .semibold)
    }
}

// MARK: - 外观模式

/// 浅色 / 深色 / 跟随系统三态，Perch 与 Cella 使用同一个存储键。
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

enum AppearanceStore {
    static let key = "appearanceMode"

    static var current: AppearanceMode {
        AppearanceMode(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system
    }

    static func set(_ mode: AppearanceMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: key)
        apply()
    }

    static func apply() {
        NSApp.appearance = current.nsAppearance
    }
}

// MARK: - 色值工具

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}
