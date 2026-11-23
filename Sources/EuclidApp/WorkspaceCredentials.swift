import Foundation
import Security

/// Session files contain opaque references only, including for custom URLs with embedded tokens.
protocol WorkspaceCredentialStore: Sendable {
    func data(for reference: String) throws -> Data?
    func store(_ data: Data, for reference: String) throws
}

struct KeychainWorkspaceCredentials: WorkspaceCredentialStore {
    private let service = "com.euclid.workspace.online-configuration"

    private func query(_ reference: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: reference]
    }

    func data(for reference: String) throws -> Data? {
        var request = query(reference)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw WorkspaceCredentialError(status: status)
        }
        return data
    }

    func store(_ data: Data, for reference: String) throws {
        let request = query(reference)
        let status = SecItemUpdate(request as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw WorkspaceCredentialError(status: status) }
        var insertion = request
        insertion[kSecValueData as String] = data
        insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let inserted = SecItemAdd(insertion as CFDictionary, nil)
        guard inserted == errSecSuccess else { throw WorkspaceCredentialError(status: inserted) }
    }
}

struct WorkspaceCredentialError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        "无法保存或读取在线服务凭据：\(SecCopyErrorMessageString(status, nil) as String? ?? String(status))"
    }
}
