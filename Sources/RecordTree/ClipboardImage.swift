import AppKit

/// 图片剪贴板工具：识别剪贴板图片数据、统一转 PNG 落盘、回写剪贴板
enum ClipboardImage {
    /// 自我复制标记：栖痕把图片写入剪贴板时附带其 chunk id，
    /// 轮询器据此直接判定为「图片自我复制」，无需比对文本内容。
    static let selfCopyMarkerType = NSPasteboard.PasteboardType("com.perch.selfcopy.image")

    struct Decoded {
        let pngData: Data
        let width: Int
        let height: Int
    }

    /// 单张图片可接受的最大原始字节数（超过则忽略，避免解码撑爆内存）
    private static let maxRawBytes = 100 * 1024 * 1024

    /// 从剪贴板读取原始图片数据（优先 PNG / TIFF / JPEG），不含文本时返回 nil
    static func rawImageData(from pb: NSPasteboard) -> Data? {
        let types = [
            NSPasteboard.PasteboardType.png,
            .tiff,
            NSPasteboard.PasteboardType("public.jpeg")
        ]
        for t in types {
            if let d = pb.data(forType: t), !d.isEmpty, d.count <= maxRawBytes { return d }
        }
        return nil
    }

    /// 字符串是否「仅为一个 URL / 路径」——复制网页图片时常附带这类文本；
    /// 判定为真且剪贴板又含图片数据时，优先按图片记录。
    static func looksLikeURLOrPath(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        guard !t.contains(where: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }) else { return false }
        let low = t.lowercased()
        if low.hasPrefix("http://") || low.hasPrefix("https://")
            || low.hasPrefix("file://") || low.hasPrefix("www.") {
            return true
        }
        if t.hasPrefix("/") || t.hasPrefix("~/") { return true }
        // 形如 xx.png 等直接以图片扩展名结尾的短文本
        guard let last = t.split(separator: "/").last, last.contains(".") else { return false }
        let ext = last.split(separator: ".").last?.lowercased() ?? ""
        return ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"].contains(ext)
    }

    /// 把任意支持的图片数据统一转成 PNG，并给出像素尺寸
    static func decodePNG(_ raw: Data) -> Decoded? {
        guard let rep = NSBitmapImageRep(data: raw) else { return nil }
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return Decoded(pngData: png, width: rep.pixelsWide, height: rep.pixelsHigh)
    }

    /// 保存 PNG 到数据目录 images/<day>/ 下（随数据目录一并跨设备同步），返回相对根目录的路径
    static func savePNG(_ pngData: Data, dayKey: String, atMs: Int64) throws -> String {
        let fm = FileManager.default
        let dir = AppPaths.imagesRootURL.appendingPathComponent(dayKey, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = String(format: "%06x", Int.random(in: 0...0xFFFFFF))
        let name = "img_\(atMs)_\(stamp).png"
        try pngData.write(to: dir.appendingPathComponent(name), options: .atomic)
        return "images/\(dayKey)/\(name)"
    }
}
