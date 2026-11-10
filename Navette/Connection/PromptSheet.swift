import NavetteCore
import SwiftUI

/// One question from a connection: an unknown host key, a password, a passphrase, a one-time code or a yes/no.
struct PromptSheet: View {
    let request: PromptCenter.Request
    let answer: (PromptAnswer?) -> Void
    @State private var text = ""
    @State private var remember = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch request.prompt {
            case .hostKey(let host, let keyType, let fingerprint):
                header("questionmark.diamond.fill", .orange, String(localized: "“\(request.server)” is a server this Mac does not know yet"))
                Text("Check this fingerprint with the server's administrator before trusting it. Once trusted, it is saved in your known_hosts file and Navette warns you if it ever changes.")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Server") { Text(host).textSelection(.enabled) }
                    LabeledContent("Key type") { Text(keyType) }
                    LabeledContent("Fingerprint") { Text(fingerprint).font(.system(.callout, design: .monospaced)).textSelection(.enabled) }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .themeCard()
                buttons(confirm: String(localized: "Trust"), isQuestion: true)

            case .confirm(let message):
                header("questionmark.circle.fill", .blue, request.server)
                Text(message).textSelection(.enabled)
                buttons(confirm: String(localized: "Allow"), isQuestion: true)

            case .password(let account):
                header("key.fill", .blue, String(localized: "Password for “\(request.server)”"))
                if !account.isEmpty { Text(account).font(.callout).foregroundStyle(.secondary) }
                secretField(String(localized: "Password"))
                buttons(confirm: String(localized: "Log In"), isQuestion: false)

            case .passphrase(let keyPath):
                header("key.horizontal.fill", .blue, String(localized: "Passphrase of your SSH key"))
                if !keyPath.isEmpty {
                    Text(keyPath).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                }
                secretField(String(localized: "Passphrase"))
                buttons(confirm: String(localized: "Unlock"), isQuestion: false)

            case .oneTimeCode(let message), .other(let message):
                header("number.circle.fill", .blue, request.server)
                Text(message).textSelection(.enabled)
                secretField(String(localized: "Answer"))
                buttons(confirm: String(localized: "Continue"), isQuestion: false)

            case .notice(let message):
                header("info.circle.fill", .blue, request.server)
                Text(message)
                buttons(confirm: String(localized: "OK"), isQuestion: true)
            }
        }
        .padding(22)
        .frame(width: 460)
    }

    private func header(_ symbol: String, _ color: Color, _ title: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(color)
            Text(title).font(.title3.bold()).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func secretField(_ placeholder: String) -> some View {
        if request.isRetry {
            Label("The previous answer was refused. Try again.", systemImage: "exclamationmark.triangle.fill")
                .font(.callout).foregroundStyle(.orange)
        }
        SecureField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .onSubmit { if !text.isEmpty { answer(PromptAnswer(text: text, remember: remember && request.prompt.canBeRemembered)) } }
        if request.prompt.canBeRemembered {
            Toggle("Remember in the Keychain", isOn: $remember).font(.callout)
        }
    }

    private func buttons(confirm: String, isQuestion: Bool) -> some View {
        HStack {
            Spacer()
            Button("Cancel") { answer(nil) }.buttonStyle(.soft).keyboardShortcut(.cancelAction)
            Button(confirm) {
                answer(PromptAnswer(text: text, remember: remember && request.prompt.canBeRemembered, accepted: true))
            }
            .buttonStyle(.gradient)
            .keyboardShortcut(.defaultAction)
            .disabled(!isQuestion && text.isEmpty)
        }
    }
}
