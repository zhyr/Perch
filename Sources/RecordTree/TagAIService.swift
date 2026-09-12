import Foundation

/// AI 打标签服务：统一走 OpenAI 兼容 `/v1/chat/completions`。
///
/// 兼容的后端（按预设区分，仅 baseURL/model/apiKey 不同）：
/// - 云端 API：任意 OpenAI 兼容服务（OpenAI / DeepSeek / 月之暗面等），
///   也可以指向自托管 Yueli KGM Computing 网关（同样暴露 /v1/chat/completions）
/// - Ollama：http://localhost:11434/v1（原生提供 OpenAI 兼容端点，无需 key）
/// - MLX：mlx_lm.server（Apple Silicon 本地 MLX 推理），默认 http://127.0.0.1:8080/v1
struct AIEndpointConfig: Equatable {
    var baseURL: String
    var apiKey: String
    var model: String

    var chatURL: URL? {
        var s = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasSuffix("/") { s.removeLast() }
        // 允许用户填到 /v1、根路径，或完整端点（含 /completions 结尾的聚合网关）
        if s.hasSuffix("/chat/completions") {
            // 已是完整路径
        } else if s.hasSuffix("/completions") {
            // Yueli AI 等聚合网关：/v1/completions 即聊天入口，原样使用，不再拼接
        } else if s.hasSuffix("/v1") {
            s += "/chat/completions"
        } else {
            s += "/v1/chat/completions"
        }
        return URL(string: s)
    }
}

enum AIProviderPreset: Int {
    case cloud = 0
    case ollama = 1
    case mlx = 2

    var label: String {
        switch self {
        case .cloud: return "云端 API"
        case .ollama: return "本地 Ollama"
        case .mlx: return "本地 MLX"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .cloud: return "https://yueli.com/api/yueliai/v1/completions"
        case .ollama: return "http://localhost:11434/v1"
        case .mlx: return "http://127.0.0.1:8080/v1"
        }
    }

    var defaultModel: String {
        switch self {
        case .cloud: return "freemodel"
        case .ollama: return "qwen3.5"
        case .mlx: return "mlx-community/Qwen3-4B-4bit"
        }
    }
}

enum TagAIService {

    static let systemPrompt = """
    你是笔记打标签助手。根据给定的笔记标题与内容，输出 2-5 个最能概括其主题、所属项目或任务类型的简短标签。
    规则：
    1. 标签用简体中文，专有名词/项目代号可保留原文；
    2. 每个标签不超过 12 个字，不带 # 号；
    3. 只输出一个 JSON 字符串数组，例如 ["终端轨迹","数据采购"]，不要输出任何解释或其他内容。
    """

    /// 调用 chat completions（非流式），返回助手文本
    static func chat(config: AIEndpointConfig, userContent: String, timeout: TimeInterval = 60) async throws -> String {
        guard let url = config.chatURL else {
            throw AIError.badURL(config.baseURL)
        }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let body: [String: Any] = [
            "model": config.model,
            "temperature": 0.2,
            "stream": false,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userContent],
            ],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw AIError.badResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw AIError.httpStatus(http.statusCode, String(text.prefix(300)))
        }
        let content = try Self.extractAssistantText(data)
        guard !content.isEmpty else {
            // 200 但结构无法识别：把响应体前缀带回给调用方，便于定位网关实际格式
            let preview = String(data: data, encoding: .utf8) ?? "(非 UTF-8 响应)"
            throw AIError.badResponseBody(String(preview.prefix(300)))
        }
        // yueliai 网关把上游故障包装成 success:true + 道歉文案（如
        // "技术原因: Nvidia API error: 410 - Gone"）。识别并透出真实上游错误，
        // 避免把"无法回答"当成打标签成功。
        if content.contains("技术原因") || content.hasPrefix("很抱歉") {
            throw AIError.upstreamError(content)
        }
        return content
    }

    /// 从响应 JSON 提取助手文本。容忍多种网关包装：
    /// - OpenAI chat：choices[0].message.content
    /// - 旧版 completions / 流式增量：choices[0].text、choices[0].delta.content
    /// - 网关自定义信封：标准结构嵌套在 data / result / response 字段下
    /// - 顶层直出文本字段：output / content / answer / text / message
    private static func extractAssistantText(_ data: Data) throws -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // 可能是纯文本响应
            if let s = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                return s.hasPrefix("{") || s.hasPrefix("[") ? "" : s
            }
            return ""
        }
        let root: [String: Any] = {
            if obj["choices"] != nil { return obj }
            for key in ["data", "result", "response"] {
                if let nested = obj[key] as? [String: Any], nested["choices"] != nil {
                    return nested
                }
            }
            return obj
        }()
        if let choices = root["choices"] as? [[String: Any]], let first = choices.first {
            if let message = first["message"] as? [String: Any],
               let content = message["content"] as? String, !content.isEmpty {
                return content
            }
            if let delta = first["delta"] as? [String: Any],
               let content = delta["content"] as? String, !content.isEmpty {
                return content
            }
            if let text = first["text"] as? String, !text.isEmpty {
                return text
            }
        }
        for key in ["output", "content", "answer", "text", "message"] {
            if let s = root[key] as? String, !s.isEmpty {
                return s
            }
        }
        // 网关把标准字段再包一层（如 yueliai 的 {"success":true,"data":{"content":…}}）
        for key in ["data", "result", "response"] {
            if let nested = obj[key] as? [String: Any] {
                for field in ["output", "content", "answer", "text", "message"] {
                    if let s = nested[field] as? String, !s.isEmpty {
                        return s
                    }
                }
            }
        }
        return ""
    }

    /// 从模型输出中解析标签数组（容忍代码块包裹、前后杂讯）
    static func parseTags(_ text: String) -> [String] {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 剥掉 ```json ... ``` 包裹
        if let start = s.range(of: "["),
           let end = s.range(of: "]", options: .backwards), start.lowerBound < end.lowerBound {
            s = String(s[start.lowerBound...end.lowerBound])
        }
        guard let data = s.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return []
        }
        var seen = Set<String>()
        var out: [String] = []
        for item in arr {
            guard var name = item as? String else { continue }
            name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            while name.hasPrefix("#") { name.removeFirst() }
            name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty || name.count > 16 { continue }
            if seen.contains(name) { continue }
            seen.insert(name)
            out.append(name)
            if out.count >= 5 { break }
        }
        return out
    }

    /// 连通性测试：返回一段模型自述文本
    static func ping(config: AIEndpointConfig) async throws -> String {
        try await chat(
            config: config,
            userContent: "只回复两个字：正常",
            timeout: 15
        )
    }

    enum AIError: LocalizedError {
        case badURL(String)
        case badResponse
        case badResponseBody(String)
        case upstreamError(String)
        case httpStatus(Int, String)

        var errorDescription: String? {
            switch self {
            case .badURL(let s): return "无效的服务地址：\(s)"
            case .badResponse: return "响应格式无法解析（确认是 OpenAI 兼容服务）"
            case .badResponseBody(let preview):
                return "响应格式无法解析，实际响应：\(preview)"
            case .upstreamError(let detail):
                return "上游推理服务故障：\(detail)"
            case .httpStatus(let code, let body): return "HTTP \(code)：\(body)"
            }
        }
    }
}
