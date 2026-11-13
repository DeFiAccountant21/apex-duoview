import F1TV
import SwiftUI

/// Root shell: the three rooms, signed in or not (the catalogue loads anonymously; only playing
/// needs a sign-in). Sign-in lives behind a button and the Settings sheet.
struct RootView: View {
    let model: AppModel
    @State private var planDismissed = false
    @State private var sheet: ActiveSheet?

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
            .overlay(alignment: .top) {
                if case .signingIn = model.auth {
                    ProgressView("Signing in")
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                }
            }
            .sheet(item: sheetBinding) { active in
                switch active {
                case .settings:
                    SettingsPlaceholder(
                        model: model,
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
    }

    private var rooms: some View {
        TabView {
            Tab("Race Weekend", systemImage: "flag.checkered") {
                RaceWeekendRoom(context: context)
            }
            Tab("Paddock", systemImage: "person.2") {
                PaddockRoom(context: context)
            }
            Tab("Archive", systemImage: "clock.arrow.circlepath") {
                ArchiveRoom(context: context)
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }
}
