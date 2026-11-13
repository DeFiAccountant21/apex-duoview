import F1TV
import SwiftUI

/// Root shell: the three rooms, signed in or not (the catalogue loads anonymously; only playing
/// needs a sign-in). Sign-in lives behind a button and the Settings sheet.
struct RootView: View {
    let model: AppModel
    @State private var planDismissed = false
    @State private var sheet: ActiveSheet?
    /// The fold, tracked from the root so its frame is in root coordinates. Nothing lays out by
    /// it in beta.1; it is in the environment for later betas.
    @State private var fold = FoldState()

    private enum ActiveSheet: Identifiable {
        case settings
        case signIn
        case plan
        var id: Self { self }
    }

    private var context: RoomContext {
        RoomContext(
            model: model,
            onPlay: { item, channel in
                Task { await model.playback.play(item: item, channel: channel) }
            },
            onSignIn: { sheet = .signIn },
            onSettings: { sheet = .settings })
    }

    /// The one sheet binding. Dismissing the plan sheet any way at all counts as "seen".
    private var sheetBinding: Binding<ActiveSheet?> {
        Binding(
            get: { sheet },
            set: { newValue in
                if newValue == nil, sheet == .plan { planDismissed = true }
                sheet = newValue
            })
    }

    var body: some View {
        // The rooms stay mounted in every auth state, so signing in never resets navigation or
        // reloads them; "Signing in" is only an overlay.
        rooms
            .themedBackground()
            .foldTracking(fold)
            .overlay(alignment: .top) {
                if case .signingIn = model.auth {
                    ProgressView("Signing in")
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                } else if case .signedOut = model.auth,
                    let message = model.message, message != AppModel.signInPrompt
                {
                    MessageBanner(
                        message: message,
                        canRetry: model.restorePending,
                        onSignIn: { sheet = .signIn },
                        onRetry: { Task { await model.retryRestore() } },
                        onDismiss: { model.dismissMessage() })
                }
            }
            .sheet(item: sheetBinding) { active in
                switch active {
                case .settings:
                    SettingsView(
                        model: model,
                        fold: fold,
                        onSignIn: { self.sheet = .signIn },
                        onSignOut: { signOutAndClearWebData(model) })
                case .signIn:
                    NavigationStack {
                        SignInView(model: model)
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button("Close") { self.sheet = nil }
                                }
                            }
                    }
                case .plan:
                    PlanSheet { signOutAndClearWebData(model) }
                }
            }
            .fullScreenCover(isPresented: Binding(
                get: { model.playback.isPresented },
                set: { if !$0 { model.playback.close() } })
            ) {
                PlayerCover(controller: model.playback)
            }
            .onChange(of: model.auth) { _, auth in
                if case .signedIn(let account) = auth {
                    if !account.hasVideoPlan && !planDismissed {
                        // Replaces the sign-in sheet in the same binding, so there is no second
                        // presentation racing the dismissal.
                        sheet = .plan
                    } else if sheet == .signIn {
                        sheet = nil
                    }
                    return
                }
                planDismissed = false
                if sheet == .plan { sheet = nil }
            }
            .environment(fold)
    }

    private var rooms: some View {
        TabView {
            Tab("Race Weekend", systemImage: "flag.checkered") {
                RaceWeekendRoom(context: context).tint(Theme.textPrimary)
            }
            Tab("Paddock", systemImage: "person.2") {
                PaddockRoom(context: context).tint(Theme.textPrimary)
            }
            Tab("Archive", systemImage: "clock.arrow.circlepath") {
                ArchiveRoom(context: context).tint(Theme.textPrimary)
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        // Red selection in the tab bar and sidebar; each room sets its content back to silver.
        .tint(Theme.accent)
    }
}

/// Sign-in news over the rooms: expired, refused, or a launch that couldn't reach F1 TV.
private struct MessageBanner: View {
    let message: String
    let canRetry: Bool
    let onSignIn: () -> Void
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.footnote.bold())
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("Dismiss")
            }
            HStack(spacing: 8) {
                if canRetry {
                    Button("Try again", action: onRetry)
                        .buttonStyle(.bordered)
                        .tint(Theme.textPrimary)
                }
                Button("Sign in", action: onSignIn)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            }
        }
        .padding(12)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius).stroke(Theme.hairline, lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}
