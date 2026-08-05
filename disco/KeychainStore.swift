import Foundation
import Security

protocol APIKeyStoring {
    func load() throws -> String?
    func save(_ apiKey: String) throws
    func delete() throws
}

struct KeychainStore: APIKeyStoring {
    private let service = Bundle.main.bundleIdentifier ?? "com.yankewei.disco"
    private let account = "openai-platform-api-key"

    func load() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError(status: status)
        }
        guard let data = result as? Data, let apiKey = String(data: data, encoding: .utf8) else {
            throw KeychainError(status: errSecDecode)
        }
        return apiKey
    }

    func save(_ apiKey: String) throws {
        let key = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as [String: Any]
        let attributes = [kSecValueData as String: Data(apiKey.utf8)] as [String: Any]

        let updateStatus = SecItemUpdate(key as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var newItem = key
            newItem[kSecValueData as String] = Data(apiKey.utf8)
            let addStatus = SecItemAdd(newItem as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError(status: addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw KeychainError(status: updateStatus)
        }
    }

    func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }
}

struct KeychainError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        SecCopyErrorMessageString(status, nil) as String? ?? "Keychain 操作失败（\(status)）。"
    }
}

final class InMemoryKeychainStore: APIKeyStoring {
    private var apiKey: String?

    func load() throws -> String? {
        apiKey
    }

    func save(_ apiKey: String) throws {
        self.apiKey = apiKey
    }

    func delete() throws {
        apiKey = nil
    }
}
