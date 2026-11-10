import Foundation
import Security

/// Where passwords and passphrases are kept. Keys are opaque strings such as `Bookmark.credentialKey`.
public protocol CredentialStore: Sendable {
    func secret(for key: String) -> String?
    /// `nil` removes the secret.
    func setSecret(_ secret: String?, for key: String) throws
}

public enum CredentialKey {
    /// The key for an SSH key passphrase, by the path `ssh` shows in its prompt.
    public static func passphrase(keyPath: String) -> String { "ssh-key:" + keyPath }
}

/// For demo mode and tests.
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: String]

    public init(_ secrets: [String: String] = [:]) {
        self.secrets = secrets
    }

    public func secret(for key: String) -> String? {
        lock.withLock { secrets[key] }
    }

    public func setSecret(_ secret: String?, for key: String) throws {
        lock.withLock { secrets[key] = secret }
    }
}

public enum CredentialStoreError: Error, Equatable {
    /// The Keychain refused access (for example the user declined the system prompt).
    case keychain(OSStatus)
}

/// All of Navette's secrets in one Keychain item.
/// The app is ad hoc signed, so macOS asks for approval again after each update: one item means one question.
public final class KeychainCredentialStore: CredentialStore, @unchecked Sendable {
    private let service: String
    private let account = "credentials"
    private let lock = NSLock()
    private var cache: [String: String]?
    private var loadFailure: OSStatus?

    public init(service: String = "io.github.romainrg.Navette") {
        self.service = service
    }

    public func secret(for key: String) -> String? {
        lock.withLock {
            load()
            return cache?[key]
        }
    }

    public func setSecret(_ secret: String?, for key: String) throws {
        try lock.withLock {
            load()
            // Never overwrite an item that could not be read: that would drop every other secret.
            if let loadFailure { throw CredentialStoreError.keychain(loadFailure) }
            var secrets = cache ?? [:]
            guard secrets[key] != secret else { return }
            secrets[key] = secret
            let data = try JSONEncoder().encode(secrets)
            var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                var attributes = query
                attributes[kSecValueData as String] = data
                attributes[kSecAttrLabel as String] = "Navette"
                status = SecItemAdd(attributes as CFDictionary, nil)
            }
            guard status == errSecSuccess else { throw CredentialStoreError.keychain(status) }
            cache = secrets
        }
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private func load() {
        guard cache == nil, loadFailure == nil else { return }
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            cache = (result as? Data).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        case errSecItemNotFound:
            cache = [:]
        default:
            loadFailure = status
        }
    }
}
