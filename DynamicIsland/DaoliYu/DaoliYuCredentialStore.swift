import Foundation
import Security

enum DaoliYuCredentialAccount: String, CaseIterable {
    case password = "password"
    case accessToken = "access-token"
}

protocol DaoliYuCredentialStoring: Sendable {
    func read(_ account: DaoliYuCredentialAccount) -> String?
    @discardableResult func write(_ value: String, account: DaoliYuCredentialAccount) -> OSStatus
    @discardableResult func delete(_ account: DaoliYuCredentialAccount) -> OSStatus
}

struct KeychainDaoliYuCredentialStore: DaoliYuCredentialStoring {
    private static let service = "com.Ebullioscopic.Atoll.DaoliYu"

    private func baseQuery(for account: DaoliYuCredentialAccount) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account.rawValue
        ]
    }

    func read(_ account: DaoliYuCredentialAccount) -> String? {
        var query = baseQuery(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    func write(_ value: String, account: DaoliYuCredentialAccount) -> OSStatus {
        let data = Data(value.utf8)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery(for: account) as CFDictionary, update as CFDictionary)
        guard status == errSecItemNotFound else {
            return status
        }

        var attributes = baseQuery(for: account)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil)
    }

    @discardableResult
    func delete(_ account: DaoliYuCredentialAccount) -> OSStatus {
        let status = SecItemDelete(baseQuery(for: account) as CFDictionary)
        return status == errSecItemNotFound ? errSecSuccess : status
    }
}
