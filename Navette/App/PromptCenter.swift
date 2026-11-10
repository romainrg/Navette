import Foundation
import NavetteCore
import Observation

struct PromptAnswer {
    /// The secret or code typed by the user; empty for yes/no questions.
    var text = ""
    var remember = false
    /// For yes/no questions.
    var accepted = false
}

/// The questions a connection asks the user (host key, password, passphrase, one-time code), one sheet at a time.
@MainActor @Observable
final class PromptCenter {
    struct Request: Identifiable {
        let id = UUID()
        let server: String
        let prompt: AskpassPrompt
        /// The previous answer was refused.
        let isRetry: Bool
        /// Set when the question is whether to trust a TLS certificate the system does not trust.
        var certificate: CertificateSummary?
    }

    private(set) var current: Request?
    /// Messages that need no answer, such as "touch your security key".
    private(set) var notices: [UUID: String] = [:]

    /// Called when the user trusts a certificate, so the choice is remembered with the bookmark.
    @ObservationIgnored var onCertificateTrusted: ((Bookmark, String) -> Void)?
    @ObservationIgnored private var continuation: CheckedContinuation<PromptAnswer?, Never>?
    @ObservationIgnored private var waiting: [(Request, CheckedContinuation<PromptAnswer?, Never>)] = []

    init(preview: Request? = nil) {
        current = preview
    }

    /// Returns `nil` when the user cancels.
    func ask(server: String, prompt: AskpassPrompt, isRetry: Bool = false, certificate: CertificateSummary? = nil) async -> PromptAnswer? {
        await withCheckedContinuation { continuation in
            let request = Request(server: server, prompt: prompt, isRetry: isRetry, certificate: certificate)
            if current == nil {
                current = request
                self.continuation = continuation
            } else {
                waiting.append((request, continuation))
            }
        }
    }

    func resolve(_ answer: PromptAnswer?) {
        continuation?.resume(returning: answer)
        continuation = nil
        if waiting.isEmpty {
            current = nil
        } else {
            (current, continuation) = waiting.removeFirst()
        }
    }

    /// Shows the certificate and asks whether to trust it. A certificate error is never bypassed without this.
    func askToTrust(_ certificate: CertificateSummary, for bookmark: Bookmark) async -> Bool {
        let answer = await ask(server: bookmark.displayName, prompt: .confirm(message: certificate.reason), certificate: certificate)
        guard answer?.accepted == true else { return false }
        onCertificateTrusted?(bookmark, certificate.sha256)
        return true
    }

    func showNotice(_ message: String, id: UUID) { notices[id] = message }
    func hideNotice(id: UUID) { notices[id] = nil }
}

/// Answers the questions of one `ssh` connection attempt: from the Keychain when a saved secret has not been
/// tried yet, from the user otherwise. A one-time code is never stored.
final class SSHPromptResponder: AskpassResponder, @unchecked Sendable {
    private let bookmark: Bookmark
    private let credentials: any CredentialStore
    private let prompts: PromptCenter
    private let lock = NSLock()
    private var initialPassword: String?
    private var tried: Set<String> = []

    init(bookmark: Bookmark, initialPassword: String?, credentials: any CredentialStore, prompts: PromptCenter) {
        self.bookmark = bookmark
        self.initialPassword = initialPassword
        self.credentials = credentials
        self.prompts = prompts
    }

    func respond(to prompt: AskpassPrompt) async -> String? {
        switch prompt {
        case .password:
            return await secret(prompt, key: bookmark.credentialKey)
        case .passphrase(let keyPath):
            return await secret(prompt, key: CredentialKey.passphrase(keyPath: keyPath))
        case .hostKey, .confirm:
            let answer = await prompts.ask(server: bookmark.displayName, prompt: prompt)
            return answer?.accepted == true ? "yes" : "no"
        case .oneTimeCode, .other:
            return await prompts.ask(server: bookmark.displayName, prompt: prompt)?.text
        case .notice:
            return nil
        }
    }

    private func secret(_ prompt: AskpassPrompt, key: String) async -> String? {
        let (firstTime, initial): (Bool, String?) = lock.withLock {
            let firstTime = tried.insert(key).inserted
            defer { if case .password = prompt { initialPassword = nil } }
            return (firstTime, { if case .password = prompt { initialPassword } else { nil } }())
        }
        if firstTime {
            if let initial { return initial }
            if let saved = credentials.secret(for: key) { return saved }
        }
        guard let answer = await prompts.ask(server: bookmark.displayName, prompt: prompt, isRetry: !firstTime) else { return nil }
        if answer.remember { try? credentials.setSecret(answer.text, for: key) }
        return answer.text
    }

    func noticeBegan(_ message: String, id: UUID) {
        Task { @MainActor in prompts.showNotice(message, id: id) }
    }

    func noticeEnded(id: UUID) {
        Task { @MainActor in prompts.hideNotice(id: id) }
    }
}
