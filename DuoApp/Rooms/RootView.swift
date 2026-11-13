import F1TV
import SwiftUI

/// Root shell: the three rooms, signed in or not (the catalogue loads anonymously; only playing
/// needs a sign-in). Sign-in lives behind a button and the Settings sheet.
struct RootView: View {
    let model: AppModel
    @State private var planDismissed = false
    @State private var sheet: ActiveSheet?
    @State private var playbackNotice: String?

    private enum ActiveSheet: Identifiable {
        case settings
        case signIn
        var id: Self { self }
    }

    private var context: RoomContext {
        RoomContext(
            model: model,
            // Task 11 replaces this: it starts the player.
            onPlay: { _, _ in playbackNotice = "Playback comes in the next build" },
            onSignIn: { sheet = .signIn },
            onSettings: { sheet = .settings })
    }

    var body: some View {
        Group {
            if case .signingIn = model.auth {
                ProgressView("Signing in")
            } else {
                rooms
            }
        }
        .sheet(item: $sheet) { active in
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
            }
        }
        .alert(
            "Playback", isPresented: Binding(
                get: { playbackNotice != nil },
                set: { if !$0 { playbackNotice = nil } })
        ) {
            Button("OK") { playbackNotice = nil }
        } message: {
            Text(playbackNotice ?? "")
        }
        .onChange(of: model.auth) { _, auth in
            if case .signedIn = auth {
                if sheet == .signIn { sheet = nil }
                return
            }
            planDismissed = false
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
        .sheet(isPresented: planSheetBinding) {
            PlanSheet { signOutAndClearWebData(model) }
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
}
