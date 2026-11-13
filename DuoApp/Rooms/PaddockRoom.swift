import F1TV
import SwiftUI

/// F1 TV's home page: "Featured on F1 TV", then its rows (shows as posters).
struct PaddockRoom: View {
    let context: RoomContext

    @State private var state: LoadState<HomePage> = .loading
    @State private var attempt = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                LoadStateView(state: state, retry: retry) { page in
                    let now = Date()
                    VStack(alignment: .leading, spacing: 20) {
                        RowView(title: "Featured on F1 TV", items: page.featured, now: now)
                        ForEach(Array(page.rows.enumerated()), id: \.offset) { _, row in
                            CatalogRowView(row: row, now: now)
                        }
                    }
                    .padding(.vertical)
                }
            }
            .navigationTitle("Paddock")
            .roomChrome(context)
            .task(id: attempt) { await load() }
            .refreshable { await load() }
        }
    }

    private func retry() {
        state = .loading
        attempt += 1
    }

    private func load() async {
        if let result = await LoadState.run({ try await context.model.catalogue.home() }) {
            state = result
        }
    }
}
