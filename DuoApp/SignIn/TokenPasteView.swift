import F1TV
import SwiftUI

/// The fallback route: paste the `login-session` cookie or a subscription token.
struct TokenPasteView: View {
    let model: AppModel
    @State private var text = ""
    @State private var showsError = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Paste your login-session cookie or subscription token.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $text)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Sign-in to paste")
                    if text.isEmpty {
                        Text("Paste here")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .frame(minHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                if showsError {
                    Text("That doesn't look like a login-session cookie or a subscription token.")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                Button {
                    use()
                } label: {
                    Text("Use this")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Spacer()
            }
            .padding()
            .navigationTitle("Paste a sign-in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func use() {
        guard let token = LoginCookie.token(from: text) else {
            showsError = true
            return
        }
        text = ""
        let model = model
        Task { await model.signIn(token: token) }
        dismiss()
    }
}
