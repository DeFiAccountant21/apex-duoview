import F1TV
import SwiftUI
import WebKit

/// Owns the web view so the sheet and its cookie poll share one instance.
@MainActor
final class SignInBrowser {
    let webView: WKWebView

    init() {
        let configuration = WKWebViewConfiguration()
        // The default store, so sign-out can clear what this screen leaves behind.
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = Endpoints.userAgent
        webView.load(URLRequest(url: LoginCookie.loginURL))
        self.webView = webView
    }

    /// The token from the `login-session` cookie, once the page has set it.
    func currentToken() async -> String? {
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        for cookie in cookies where cookie.name == "login-session" && cookie.domain.hasSuffix("formula1.com") {
            if let token = LoginCookie.token(from: cookie.value) { return token }
        }
        return nil
    }
}

private struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct WebSignInView: View {
    let model: AppModel
    @State private var browser = SignInBrowser()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("Sign in with your F1 TV email and password. Google sign-in doesn't work inside apps.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
                WebViewContainer(webView: browser.webView)
            }
            .navigationTitle("Sign in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        // Tied to the sheet's lifetime: cancelled when it closes, and it returns after the first token.
        .task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard let token = await browser.currentToken() else { continue }
                // Not a child of this view: closing the sheet must not cancel the sign-in.
                let model = model
                Task { await model.signIn(token: token) }
                dismiss()
                return
            }
        }
    }
}
