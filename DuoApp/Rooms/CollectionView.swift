import F1TV
import SwiftUI

/// A show's or documentary's page: its description and episode rows.
struct CollectionView: View {
    let pageId: Int
    let title: String
    let context: RoomContext

    @State private var state: LoadState<CollectionPage> = .loading
    @State private var attempt = 0

    var body: some View {
        ScrollView {
            LoadStateView(state: state, retry: retry) { page in
                VStack(alignment: .leading, spacing: 20) {
                    if !page.description.isEmpty {
                        Text(page.description)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                    }
                    ForEach(Array(page.rows.enumerated()), id: \.offset) { _, row in
                        CatalogRowView(row: row, now: Date())
                    }
                }
                .padding(.vertical)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: attempt) { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        if let result = await LoadState.run({ try await context.model.catalogue.collection(pageId: pageId) }) {
            state = result
        }
    }

    private func retry() {
        state = .loading
        attempt += 1
    }
}
