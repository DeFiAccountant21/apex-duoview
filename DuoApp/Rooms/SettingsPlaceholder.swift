import SwiftUI

/// A minimal Settings sheet; Task 12 replaces it with the real SettingsView.
struct SettingsPlaceholder: View {
    let model: AppModel
    let onSignIn: () -> Void
    let onSignOut: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    switch model.auth {
                    case .signedIn(let account):
                        Text("Signed in (\(account.tier))")
                        Button("Sign out") {
                            dismiss()
                            onSignOut()
                        }
                    default:
                        Button("Sign in", action: onSignIn)
                    }
                }
                Section {
                    Text(versionText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
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
