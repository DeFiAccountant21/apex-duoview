import SwiftUI

/// Shown while signed out: web sign-in, the paste route, and the model's message.
struct SignInView: View {
    let model: AppModel
    @State private var showingWebSignIn = false
    @State private var showingPaste = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Apex DuoView")
                .font(.largeTitle.bold())
            if let message = model.message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button {
                showingWebSignIn = true
            } label: {
                Text("Sign in with F1 TV")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button("Paste a sign-in instead") {
                showingPaste = true
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .sheet(isPresented: $showingWebSignIn) {
            WebSignInView(model: model)
        }
        .sheet(isPresented: $showingPaste) {
            TokenPasteView(model: model)
        }
    }
}
