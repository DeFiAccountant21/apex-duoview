import F1TV
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

/// Root shell: sign-in while signed out; the placeholder content (replaced by the rooms later) once in.
struct RootView: View {
    let model: AppModel
    @State private var planDismissed = false

    var body: some View {
        VStack(spacing: 12) {
            switch model.auth {
            case .signedOut:
                SignInView(model: model)
            case .signingIn:
                ProgressView("Signing in")
            case .signedIn(let account):
                Text("Signed in (\(account.tier))")
                    .font(.headline)
                Button("Sign out") { signOutAndClearWebData(model) }
                    .buttonStyle(.bordered)
            }
            Text(versionText)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
        .sheet(isPresented: planSheetBinding) {
            PlanSheet { signOutAndClearWebData(model) }
        }
        .onChange(of: model.auth) { _, auth in
            if case .signedIn = auth { return }
            planDismissed = false
        }
    }

    private var planSheetBinding: Binding<Bool> {
        Binding(
            get: {
                guard case .signedIn(let account) = model.auth else { return false }
                return !account.hasVideoPlan && !planDismissed
            },
            set: { if !$0 { planDismissed = true } })
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
