import F1TV
import SwiftUI

@main
struct DuoApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .preferredColorScheme(.dark)
                .tint(Theme.textPrimary)
                .foregroundStyle(Theme.textPrimary)
                .task { await model.restore() }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task { await model.revalidate() }
                }
        }
    }
}
