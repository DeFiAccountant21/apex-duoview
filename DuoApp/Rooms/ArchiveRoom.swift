import F1TV
import SwiftUI

/// "Popular races from the archive", then the seasons from this year back to 1981.
struct ArchiveRoom: View {
    let context: RoomContext

    @State private var races: LoadState<[CatalogItem]> = .loading
    @State private var attempt = 0

    private static let firstSeason = 1981

    private var seasons: [Int] {
        let current = Calendar.current.component(.year, from: Date())
        return Array((Self.firstSeason...max(current, Self.firstSeason)).reversed())
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    LoadStateView(state: races, retry: retry) { items in
                        RowView(title: "Popular races from the archive", items: items, now: Date())
                    }
                    Text("Seasons")
                        .heading()
                        .padding(.horizontal)
                        .accessibilityAddTraits(.isHeader)
                    LazyVStack(spacing: 0) {
                        ForEach(seasons, id: \.self) { year in
                            NavigationLink(value: Route.season(year)) {
                                HStack {
                                    Text(String(year)).rowTitle().monospacedDigit()
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(Theme.textTertiary)
                                }
                                .padding(.vertical, 12)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider().overlay(Theme.hairline)
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical)
            }
            .themedBackground()
            .navigationTitle("Archive")
            .roomChrome(context)
            .task(id: attempt) { if !races.isLoaded { await load() } }
            .refreshable { await load() }
        }
    }

    private func retry() {
        races = .loading
        attempt += 1
    }

    private func load() async {
        if let result = await LoadState.run(keeping: races, { try await context.model.catalogue.archiveRaces() }) {
            races = result
        }
    }
}
