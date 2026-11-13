import F1TV
import SwiftUI

/// Where a tile leads.
enum Route: Hashable {
    case detail(CatalogItem)
    case collection(pageId: Int, title: String)
    case season(Int)
    case weekend(Meeting)

    static func forItem(_ item: CatalogItem) -> Route {
        if let pageId = item.pageId { return .collection(pageId: pageId, title: item.title) }
        return .detail(item)
    }
}

/// What every room needs from the root: the model and the actions only the root can do.
struct RoomContext {
    let model: AppModel
    /// Plays one feed of a session. Task 11 wires the player behind this.
    let onPlay: @MainActor (Int, Channel) -> Void
    let onSignIn: @MainActor () -> Void
    let onSettings: @MainActor () -> Void

    var isSignedIn: Bool {
        if case .signedIn = model.auth { return true }
        return false
    }
}

extension View {
    /// Settings (and Sign in, while signed out) buttons, plus the destinations every room shares.
    func roomChrome(_ context: RoomContext) -> some View {
        toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !context.isSignedIn {
                    Button("Sign in") { context.onSignIn() }
                }
                Button {
                    context.onSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
        }
        .navigationDestination(for: Route.self) { route in
            switch route {
            case .detail(let item):
                DetailView(item: item, context: context)
            case .collection(let pageId, let title):
                CollectionView(pageId: pageId, title: title, context: context)
            case .season(let year):
                SeasonView(season: year, context: context)
            case .weekend(let meeting):
                WeekendView(meeting: meeting, context: context)
            }
        }
    }
}
