import SwiftUI

/// Shown while signed out: web sign-in, the paste route, and the model's message.
struct SignInView: View {
    let model: AppModel
    @State private var showingWebSignIn = false
    @State private var showingPaste = false

    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)
            LogoTile(size: 120)
            Text("Apex DuoView")
                .heading(.largeTitle)
            if let message = model.message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            Button {
                showingWebSignIn = true
            } label: {
                Text("Sign in with F1 TV")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .controlSize(.large)

            Button("Paste a sign-in instead") {
                showingPaste = true
            }
            .buttonStyle(.bordered)
            .tint(Theme.textPrimary)
            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .themedBackground()
        .sheet(isPresented: $showingWebSignIn) {
            WebSignInView(model: model)
        }
        .sheet(isPresented: $showingPaste) {
            TokenPasteView(model: model)
        }
    }
}
