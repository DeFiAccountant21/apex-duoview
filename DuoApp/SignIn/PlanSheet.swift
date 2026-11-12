import SwiftUI

/// Shown after sign-in when the account has no video plan.
struct PlanSheet: View {
    let onSignOut: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("No video plan on this account")
                .font(.title2.bold())
            Text("A free F1 TV account can't play video.")
            Text("If you have US F1 TV Premium through Apple TV, link your Apple account on F1 TV's website first, then sign in again.")
            Spacer()
            Button {
                dismiss()
            } label: {
                Text("OK").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Button("Sign out") {
                dismiss()
                onSignOut()
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity)
        }
        .padding()
        .presentationDetents([.medium])
    }
}
