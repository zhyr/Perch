import Foundation
import Security

/// 极简 Keychain 封装（`kSecClassGenericPassword`）。
///
/// 用于存放 API Key 等敏感字段，避免明文落在 `UserDefaults`（磁盘 plist 与备份都可读）。
/// 读取失败（条目不存在、ACL 拒绝、钥匙串锁定等）统一返回 `nil`，由调用方决定回退策略。
enum KeychainStore {

    /// 以 bundle id 作为 service，避免与其它应用的同名条目冲突
    private static var service: String {
        Bundle.main.bundleIdentifier ?? "com.local.perch"
    }

    /// 读取字符串；不存在或出错时返回 nil
    static func string(for account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        // 不弹系统授权框：签名变化（例如重新安装）导致 ACL 不认当前应用时直接失败，
        // 避免启动阶段阻塞在主线程等待用户点击授权对话框
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 写入字符串；`value` 为空视为删除。返回是否写入成功。
    @discardableResult
    static func set(_ value: String, for account: String) -> Bool {
        if value.isEmpty { return remove(account: account) }
        guard let data = value.data(using: .utf8) else { return false }

        let query = baseQuery(account: account)
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            // 首次解锁后即可读，避免锁屏时后台打标签被拦
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return true
        case errSecItemNotFound:
            return add(query: query, attrs: attrs)
        case errSecAuthFailed, errSecInteractionNotAllowed, errSecNotAvailable:
            // 签名变化（例如重新安装）后旧条目的 ACL 不再信任当前应用：先删后建，
            // 否则用户重新输入 Key 也会一直写不进去
            guard remove(account: account) else { return false }
            return add(query: query, attrs: attrs)
        default:
            return false
        }
    }

    private static func add(query: [String: Any], attrs: [String: Any]) -> Bool {
        var addQuery = query
        addQuery.merge(attrs) { _, new in new }
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    /// 删除条目；条目本来就不存在也视为成功
    @discardableResult
    static func remove(account: String) -> Bool {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
