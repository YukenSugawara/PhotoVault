import Foundation
import Security

/// 認証情報と端末専用鍵をKeychainへ保存・読込する薄いラッパーです。
struct KeychainStore {
    private let service = "jp.photovault.secure-storage"

    /// 更新失敗で既存の鍵や試行制限を失わないよう、削除せずに更新します。
    func save(_ data: Data, account: String, synchronizable: Bool) throws {
        var query = baseQuery(account: account)
        query[kSecAttrSynchronizable as String] = synchronizable ? kCFBooleanTrue : kCFBooleanFalse
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: synchronizable
                ? kSecAttrAccessibleAfterFirstUnlock : kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            for (key, value) in attributes { query[key] = value }
            status = SecItemAdd(query as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    func read(account: String, synchronizable: Bool) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecAttrSynchronizable as String] = synchronizable
            ? kSecAttrSynchronizableAny
            : kCFBooleanFalse

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return result as? Data
    }

    func delete(account: String) {
        var query = baseQuery(account: account)
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        SecItemDelete(query as CFDictionary)
    }

    /// このアプリ専用サービスだけを対象に、退避した鍵を含めて削除します。
    func deleteEntireService() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
