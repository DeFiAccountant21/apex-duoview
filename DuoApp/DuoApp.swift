import SwiftUI

@main
struct DuoApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .task { await model.restore() }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task { await model.revalidate() }
                }
        }
    }
}

/// Placeholder shell; the real screens replace it in later tasks.
struct RootView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            Text(authText)
                .font(.headline)
            if let message = model.message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Text(versionText)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private var authText: String {
        switch model.auth {
        case .signedOut: return "Signed out"
        case .signingIn: return "Signing in"
        case .signedIn(let account): return "Signed in (\(account.tier))"
        }
    }

    private var versionText: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let label = info["DuoBetaLabel"] as? String ?? ""
        let build = info["CFBundleVersion"] as? String ?? "?"
        let full = label.isEmpty ? version : "\(version)-\(label)"
        return "Apex DuoView v\(full) (build \(build))"
    }
}
