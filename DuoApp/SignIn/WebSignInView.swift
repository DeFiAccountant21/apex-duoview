import F1TV
import SwiftUI
import WebKit

/// Builds the web view only when asked, so constructing the view loads nothing.
@MainActor
enum SignInBrowser {
    /// Clears the default website data first (a stale `login-session` cookie must not be re-read),
    /// then returns a web view already loading the login page. Nil if cancelled meanwhile.
    static func start() async -> WKWebView? {
        let configuration = WKWebViewConfiguration()
        // The default store, so sign-out can clear what this screen leaves behind.
        configuration.websiteDataStore = .default()
        await configuration.websiteDataStore.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast)
        guard !Task.isCancelled else { return nil }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = Endpoints.userAgent
        webView.load(URLRequest(url: LoginCookie.loginURL))
        return webView
    }

    /// The token from the `login-session` cookie, once the page has set it.
    static func token(in webView: WKWebView) async -> String? {
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
    @State private var webView: WKWebView?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("Sign in with your F1 TV email and password. Google sign-in doesn't work inside apps.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
                if let webView {
                    WebViewContainer(webView: webView)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
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
            guard let webView = await SignInBrowser.start() else { return }
            self.webView = webView
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard let token = await SignInBrowser.token(in: webView) else { continue }
                // Not a child of this view: closing the sheet must not cancel the sign-in.
                let model = model
                Task { await model.signIn(token: token) }
                dismiss()
                return
            }
        }
    }
}
