import F1TV
import SwiftUI

/// A season: its race weekends from 2018 on, its videos before that.
struct SeasonView: View {
    let season: Int
    let context: RoomContext

    @State private var weekends: LoadState<[Meeting]> = .loading
    @State private var videos: LoadState<[CatalogItem]> = .loading
    @State private var attempt = 0

    private var hasWeekends: Bool { season >= 2018 }

    var body: some View {
        ScrollView {
            if hasWeekends {
                LoadStateView(state: weekends, retry: retry) { meetings in
                    LazyVStack(spacing: 0) {
                        ForEach(Array(meetings.enumerated()), id: \.offset) { _, meeting in
                            NavigationLink(value: Route.weekend(meeting)) {
                                MeetingRow(meeting: meeting)
                            }
                            .buttonStyle(.plain)
                            Divider().overlay(Theme.hairline)
                        }
                    }
                    .padding(.horizontal)
                }
            } else {
                LoadStateView(state: videos, retry: retry) { items in
                    let now = Date()
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12, alignment: .top)], spacing: 16) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            TileView(item: item, now: now)
                        }
                    }
                    .padding()
                }
            }
        }
        .themedBackground()
        .navigationTitle(String(season))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: attempt) {
            if !(hasWeekends ? weekends.isLoaded : videos.isLoaded) { await load() }
        }
        .refreshable { await load() }
    }

    private func retry() {
        weekends = .loading
        videos = .loading
        attempt += 1
    }

    private func load() async {
        let catalogue = context.model.catalogue
        if hasWeekends {
            if let result = await LoadState.run(keeping: weekends, { try await catalogue.calendar(season: season) }) {
                weekends = result
            }
        } else if let result = await LoadState.run(keeping: videos, { try await catalogue.seasonVideos(season: season) }) {
            videos = result
        }
    }
}

private struct MeetingRow: View {
    let meeting: Meeting

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.name).rowTitle()
                Text(detail).font(.caption).monospacedDigit().foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(Theme.textTertiary)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        let dates = meeting.start.formatted(.dateTime.month(.abbreviated).day())
        let round = meeting.round.map { "Round \($0) · " } ?? ""
        return "\(round)\(meeting.place.isEmpty ? "" : meeting.place + " · ")\(dates)"
    }
}

/// One race weekend: its sessions, its videos and F1 TV's rows.
struct WeekendView: View {
    let meeting: Meeting
    let context: RoomContext

    @State private var state: LoadState<WeekendContent> = .loading
    @State private var attempt = 0

    var body: some View {
        ScrollView {
            LoadStateView(state: state, retry: retry) { content in
                let now = Date()
                VStack(alignment: .leading, spacing: 20) {
                    RowView(title: "Sessions", items: content.sessions, now: now)
                    RowView(title: "Highlights and shows", items: content.videos, now: now)
                    ForEach(Array(content.rows.enumerated()), id: \.offset) { _, row in
                        CatalogRowView(row: row, now: now)
                    }
                }
                .padding(.vertical)
            }
        }
        .themedBackground()
        .navigationTitle(meeting.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: attempt) { if !state.isLoaded { await load() } }
        .refreshable { await load() }
    }

    private func retry() {
        state = .loading
        attempt += 1
    }

    private func load() async {
        if let result = await LoadState.run(keeping: state, { try await context.model.catalogue.weekend(meeting) }) {
            state = result
        }
    }
}
