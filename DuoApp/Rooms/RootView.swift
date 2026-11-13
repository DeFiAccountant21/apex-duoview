import F1TV
import SwiftUI

/// Root shell: the three rooms, signed in or not (the catalogue loads anonymously; only playing
/// needs a sign-in). Sign-in lives behind a button and the Settings sheet.
struct RootView: View {
    let model: AppModel
    @State private var planDismissed = false
    @State private var sheet: ActiveSheet?
    /// The fold, tracked from the root so its frame is in root coordinates. The Settings panel and
    /// the multiview lay out by it; it is also in the environment.
    @State private var fold = FoldState()
    /// Settings drawn by the app (`SettingsPanel`) instead of the system sheet: on a wide screen
    /// such as the Duo's inner one, so it can sit on the right-hand screen and glide between there
    /// and the middle as the phone folds.
    @State private var settingsPanelOpen = false

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

    /// Wide screens get the app's own Settings panel; a narrow one (a phone in portrait, or the
    /// Duo's outer screen) keeps the system sheet. `rootSize` is zero until the first layout,
    /// which also means the sheet.
    private var usesSettingsPanel: Bool {
        fold.rootSize.width >= Self.minimumPanelScreenWidth
    }

    private static let minimumPanelScreenWidth: CGFloat = 600

    private func showSettings() {
        if usesSettingsPanel {
            withAnimation(.snappy) { settingsPanelOpen = true }
        } else {
            sheet = .settings
        }
    }

    private func closeSettings() {
        if settingsPanelOpen { withAnimation(.snappy) { settingsPanelOpen = false } }
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
            // The app's Settings panel over a dimmed screen; tapping the dimmed part closes it, as
            // tapping outside a sheet would.
            .overlay {
                if settingsPanelOpen {
                    Color.black.opacity(0.5)
                        .ignoresSafeArea()
                        .onTapGesture { closeSettings() }
                        .accessibilityLabel("Close Settings")
                        .accessibilityAddTraits(.isButton)
                        .transition(.opacity)
                }
            }
            .overlay {
                if settingsPanelOpen {
                    SettingsPanel(fold: fold) { settingsView }
                        .transition(.move(edge: SettingsPanel<SettingsView>.isPane(fold) ? .trailing : .bottom))
                }
            }
            // Only a change of screen width (rotating, or switching between the Duo's screens)
            // swaps the panel and the system sheet. Folding never does: the panel just moves.
            // Another sheet (sign-in, plan) is never replaced.
            .onChange(of: usesSettingsPanel) { _, panel in
                if panel, sheet == .settings {
                    sheet = nil
                    settingsPanelOpen = true
                } else if !panel, settingsPanelOpen {
                    settingsPanelOpen = false
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
            .fullScreenCover(isPresented: Binding(
                get: { model.multiview.isPresented },
                set: { if !$0 { model.multiview.close() } })
            ) {
                MultiviewView(controller: model.multiview, fold: fold)
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

/// Settings drawn by the app on a wide screen. Half-open like a book (with a right-hand screen at
/// least 320 pt wide) it fills the screen to the right of the fold; otherwise it is a card in the
/// middle, like a sheet. It is one view whose frame animates, so folding and unfolding glide it
/// between the two places instead of closing one Settings and opening another. A system sheet
/// can't do this: in book posture it opens on the left screen, and the SDK has no way to choose
/// the side.
///
/// Coordinates: the inner reader ignores the safe area, so its space is the full screen, the same
/// space as `FoldState.foldFrame`. The outer reader keeps the safe area only to read its insets,
/// which pad the content wherever the panel touches a screen edge.
struct SettingsPanel<Content: View>: View {
    let fold: FoldState
    @ViewBuilder let content: Content

    static var minimumPaneWidth: CGFloat { 320 }

    /// Whether the panel sits on the right-hand screen rather than in the middle.
    @MainActor static func isPane(_ fold: FoldState) -> Bool {
        guard fold.posture == .book, let frame = fold.foldFrame else { return false }
        return fold.rootSize.width - frame.maxX >= minimumPaneWidth
    }

    private struct Layout: Equatable {
        var frame: CGRect
        var padding: EdgeInsets
        var cornerRadius: CGFloat
        var isPane: Bool
    }

    var body: some View {
        GeometryReader { safe in
            let insets = safe.safeAreaInsets
            GeometryReader { screen in
                let placement = makePlacement(screen: screen.size, insets: insets)
                content
                    .padding(placement.padding)
                    .frame(width: placement.frame.width, height: placement.frame.height)
                    .background(Theme.background)
                    .clipShape(RoundedRectangle(cornerRadius: placement.cornerRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: placement.cornerRadius, style: .continuous)
                            .strokeBorder(Theme.hairline, lineWidth: placement.isPane ? 0 : 1)
                    }
                    .shadow(color: .black.opacity(0.45), radius: 24)
                    .position(x: placement.frame.midX, y: placement.frame.midY)
                    .animation(.snappy, value: placement)
                    .accessibilityAddTraits(.isModal)
            }
            .ignoresSafeArea()
        }
    }

    private func makePlacement(screen: CGSize, insets: EdgeInsets) -> Layout {
        if Self.isPane(fold), let foldFrame = fold.foldFrame {
            let x = min(foldFrame.maxX, screen.width)
            return Layout(
                frame: CGRect(x: x, y: 0, width: screen.width - x, height: screen.height),
                padding: EdgeInsets(
                    top: insets.top, leading: 0, bottom: insets.bottom, trailing: insets.trailing),
                cornerRadius: 0,
                isPane: true)
        }
        let safeWidth = screen.width - insets.leading - insets.trailing
        let safeHeight = screen.height - insets.top - insets.bottom
        let width = max(0, min(safeWidth - 48, 620))
        let height = max(0, min(safeHeight - 32, 760))
        return Layout(
            frame: CGRect(
                x: insets.leading + (safeWidth - width) / 2,
                y: insets.top + (safeHeight - height) / 2,
                width: width,
                height: height),
            padding: EdgeInsets(),
            cornerRadius: 24,
            isPane: false)
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
