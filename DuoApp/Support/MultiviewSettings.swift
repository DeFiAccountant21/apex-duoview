import Multiview
import SwiftUI

/// Settings › Multiview: what to do when a feed is missing, and (for accounts with multiview)
/// your driver.
struct MultiviewSettingsSection: View {
    let model: AppModel

    private var hasMultiview: Bool {
        if case .signedIn(let account) = model.auth { return account.hasMultiview }
        return false
    }

    var body: some View {
        Section {
            Picker("When a feed is missing", selection: Binding(
                get: { model.multiview.fewerFeeds },
                set: { model.multiview.setFewerFeeds($0) })
            ) {
                Text("Ask").tag(FewerFeeds.ask)
                Text("Keep four spots").tag(FewerFeeds.keepSpots)
                Text("Fit to the screen").tag(FewerFeeds.fit)
            }
            if hasMultiview {
                NavigationLink {
                    MyDriverList(model: model)
                } label: {
                    LabeledContent("My driver", value: model.favouriteDriver ?? "None")
                }
            }
        } header: {
            Text("Multiview").sectionLabel()
        }
    }
}
