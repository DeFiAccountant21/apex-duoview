import F1TV
import SwiftUI

/// Root shell: the three rooms, signed in or not (the catalogue loads anonymously; only playing
/// needs a sign-in). Sign-in lives behind a button and the Settings sheet.
struct RootView: View {
    let model: AppModel
    @State private var planDismissed = false
    @State private var sheet: ActiveSheet?
    /// The fold, tracked from the root so its frame is in root coordinates. In beta.1 only the
    /// Settings placement lays out by it; it is in the environment for later betas.
    @State private var fold = FoldState()
    /// Settings shown on the right-hand screen (book posture) instead of as a sheet.
    @State private var settingsInPane = false

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
            onSettings: { showSettings() })
    }

    /// Half-open like a book, with a known fold: Settings goes on the right-hand screen. A system
    /// sheet would open on the left one, and the SDK has no way to choose the side.
    private var settingsBelongsInPane: Bool {
        fold.posture == .book && fold.foldFrame != nil
    }

    private func showSettings() {
        if settingsBelongsInPane {
            withAnimation(.snappy) { settingsInPane = true }
        } else {
            sheet = .settings
        }
    }

    private func closeSettings() {
        if settingsInPane { withAnimation(.snappy) { settingsInPane = false } }
        if sheet == .settings { sheet = nil }
    }

    private var settingsView: SettingsView {
        SettingsView(
            model: model,
            fold: fold,
            onDone: { closeSettings() },
            onSignIn: {
                closeSettings()
                sheet = .signIn
            },
            onSignOut: { signOutAndClearWebData(model) })
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
            // Settings on the right-hand screen: the left one is dimmed, and tapping it closes
            // Settings, as tapping outside a sheet would.
            .overlay {
                if settingsInPane {
                    Color.black.opacity(0.5)
                        .ignoresSafeArea()
                        .onTapGesture { closeSettings() }
                        .accessibilityLabel("Close Settings")
                        .accessibilityAddTraits(.isButton)
                        .transition(.opacity)
                }
            }
            .overlay {
                if settingsInPane, let foldFrame = fold.foldFrame {
                    TrailingPane(foldFrame: foldFrame) { settingsView }
                        .transition(.move(edge: .trailing))
                }
            }
            // Folding into or out of book posture moves an open Settings between the pane and
            // the sheet. Another sheet (sign-in, plan) is never replaced.
            .onChange(of: settingsBelongsInPane) { _, inPane in
                if inPane, sheet == .settings {
                    sheet = nil
                    withAnimation(.snappy) { settingsInPane = true }
                } else if !inPane, settingsInPane {
                    withAnimation(.snappy) { settingsInPane = false }
                    if sheet == nil { sheet = .settings }
                }
            }
            .sheet(item: sheetBinding) { active in
                switch active {
                case .settings:
                    settingsView
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

/// Fills the screen to the right of the fold. `foldFrame` is in full-screen coordinates, and this
/// reader keeps the safe area so its content clears the status bar, so the fold's edge is
/// converted through global space (the window's space, which is the screen's).
private struct TrailingPane<Content: View>: View {
    let foldFrame: CGRect
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { proxy in
            let leading = max(0, foldFrame.maxX - proxy.frame(in: .global).minX)
            HStack(spacing: 0) {
                Color.clear
                    .frame(width: min(leading, proxy.size.width))
                    .allowsHitTesting(false)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.background.ignoresSafeArea())
                    .accessibilityAddTraits(.isModal)
            }
        }
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
