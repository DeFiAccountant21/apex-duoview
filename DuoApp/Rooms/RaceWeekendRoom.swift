import F1TV
import Library
import SwiftUI

private struct WeekendInfo {
    let meeting: Meeting
    let content: WeekendContent
}

/// Continue watching, Live now, the latest weekend's schedule and F1 TV's rows for it.
struct RaceWeekendRoom: View {
    let context: RoomContext

    @State private var bookmarks: [WatchBookmark] = []
    @State private var live: LoadState<[CatalogItem]> = .loading
    @State private var weekend: LoadState<WeekendInfo?> = .loading
    @State private var liveAttempt = 0
    @State private var weekendAttempt = 0
    @State private var now = Date()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    resumeBanner
                    continueWatching
                    LoadStateView(state: live, retry: retryLive) { items in
                        RowView(title: "Live now", items: items, now: now)
                    }
                    LoadStateView(state: weekend, retry: retryWeekend) { info in
                        if let info {
                            weekendSections(info)
                        }
                    }
                }
                .padding(.vertical)
            }
            .themedBackground()
            .navigationTitle("Race Weekend")
            .roomChrome(context)
            .onAppear { bookmarks = context.model.recents.all() }
            // Back from the player: the bookmark has moved.
            .onChange(of: context.model.playback.isPresented) { _, presented in
                if !presented { bookmarks = context.model.recents.all() }
            }
            // Re-runs "Live now" every 60 s while the room is visible; cancelled when it goes.
            .task(id: liveAttempt) { await liveLoop() }
            .task(id: weekendAttempt) { if !weekend.isLoaded { await loadWeekend() } }
            .refreshable {
                bookmarks = context.model.recents.all()
                await loadLive()
                await loadWeekend()
            }
        }
    }

    // MARK: Resume banner

    /// The latest bookmark, when it is under 3 days old, signed in, nothing is playing and the
    /// banner hasn't been dismissed this run.
    @ViewBuilder
    private var resumeBanner: some View {
        let playback = context.model.playback
        if context.isSignedIn, !playback.isPresented, !playback.isInPictureInPicture, !playback.resumeBannerDismissed,
           let latest = bookmarks.first, ResumeBanner.isFresh(latest) {
            ResumeBanner(
                bookmark: latest,
                onResume: { Task { await playback.resume(latest) } },
                onDismiss: { playback.resumeBannerDismissed = true })
        }
    }

    // MARK: Continue watching

    @ViewBuilder
    private var continueWatching: some View {
        if !bookmarks.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Continue watching")
                    .sectionLabel()
                    .padding(.horizontal)
                    .accessibilityAddTraits(.isHeader)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(Array(bookmarks.enumerated()), id: \.offset) { _, bookmark in
                            TileView(
                                title: bookmark.title,
                                subtitle: Self.timeLeft(bookmark),
                                picturePath: bookmark.picturePath,
                                route: .detail(CatalogItem(
                                    contentId: bookmark.contentId, title: bookmark.title,
                                    picturePath: bookmark.picturePath)),
                                progress: Self.progress(bookmark))
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }

    /// "Xh Ym left" (or "Ym left" under an hour), or "Live".
    static func timeLeft(_ bookmark: WatchBookmark) -> String {
        if bookmark.live { return "Live" }
        let minutes = Int(max(bookmark.durationMs - bookmark.positionMs, 0) / 60_000)
        let hours = minutes / 60
        return hours > 0 ? "\(hours)h \(minutes % 60)m left" : "\(minutes)m left"
    }

    static func progress(_ bookmark: WatchBookmark) -> Double? {
        guard !bookmark.live, bookmark.durationMs > 0 else { return nil }
        return Double(bookmark.positionMs) / Double(bookmark.durationMs)
    }

    // MARK: The weekend

    @ViewBuilder
    private func weekendSections(_ info: WeekendInfo) -> some View {
        let content = info.content
        let history = context.model.history
        if !content.scheduleOver(now: now) {
            ScheduleView(
                title: info.meeting.name, schedule: content.schedule, sessions: content.sessions,
                now: now, finished: { history.isFinished($0) })
        } else {
            RowView(title: info.meeting.name, items: content.sessions, now: now)
        }
        if content.rows.isEmpty {
            RowView(title: "More from the weekend", items: content.videos, now: now)
        } else {
            ForEach(Array(content.rows.enumerated()), id: \.offset) { _, row in
                CatalogRowView(row: row, now: now)
            }
        }
    }

    // MARK: Loading

    private func retryLive() {
        live = .loading
        liveAttempt += 1
    }

    private func retryWeekend() {
        weekend = .loading
        weekendAttempt += 1
    }

    private func liveLoop() async {
        while !Task.isCancelled {
            await loadLive()
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                return
            }
        }
    }

    private func loadLive() async {
        now = Date()
        // A failed refresh keeps what is already showing.
        guard let result = await LoadState.run(keeping: live, { try await context.model.catalogue.liveNow() })
        else { return }
        live = result
    }

    private func loadWeekend() async {
        let catalogue = context.model.catalogue
        let result = await LoadState<WeekendInfo?>.run(keeping: weekend) {
            let now = Date()
            let year = Calendar.current.component(.year, from: now)
            var meetings = try await catalogue.calendar(season: year)
            if meetings.isEmpty {
                // Early in January, before this season's calendar is up.
                meetings = try await catalogue.calendar(season: year - 1)
            }
            let sorted = meetings.sorted { $0.start < $1.start }
            guard let meeting = sorted.last(where: { $0.start <= now }) ?? sorted.first else { return nil }
            return WeekendInfo(meeting: meeting, content: try await catalogue.weekend(meeting))
        }
        if let result { weekend = result }
    }
}

/// A weekend's schedule by day, opened on the day `scheduleDayToOpen` picks. Upcoming events are
/// dimmed and can't be tapped.
private struct ScheduleView: View {
    let title: String
    let schedule: [CatalogItem]
    let sessions: [CatalogItem]
    let now: Date
    let finished: (Int) -> Bool

    @State private var selection: Int?

    private var days: [[CatalogItem]] {
        let calendar = Calendar.current
        func start(_ item: CatalogItem) -> Date { item.start ?? .distantPast }
        let sorted = schedule.sorted { start($0) < start($1) }
        var order: [Date] = []
        var buckets: [Date: [CatalogItem]] = [:]
        for item in sorted {
            let day = calendar.startOfDay(for: start(item))
            if buckets[day] == nil { order.append(day) }
            buckets[day, default: []].append(item)
        }
        // Live first within a day.
        return order.map { day in
            let items = buckets[day] ?? []
            return items.filter(\.isLive) + items.filter { !$0.isLive }
        }
    }

    var body: some View {
        let allDays = days
        let opened = openDay(allDays)
        let selected = min(max(selection ?? opened, 0), max(allDays.count - 1, 0))
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .sectionLabel()
                .accessibilityAddTraits(.isHeader)
            if allDays.count > 1 {
                Picker("Day", selection: Binding(get: { selected }, set: { selection = $0 })) {
                    ForEach(allDays.indices, id: \.self) { index in
                        Text(label(allDays[index])).tag(index)
                    }
                }
                .pickerStyle(.segmented)
            }
            if allDays.indices.contains(selected) {
                VStack(spacing: 8) {
                    ForEach(Array(allDays[selected].enumerated()), id: \.offset) { _, item in
                        ScheduleRow(item: item, now: now)
                    }
                }
            }
        }
        .padding(.horizontal)
    }

    private func label(_ day: [CatalogItem]) -> String {
        (day.first?.start ?? now).formatted(.dateTime.weekday(.abbreviated).day())
    }

    private func openDay(_ days: [[CatalogItem]]) -> Int {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let todayIndex = days.firstIndex { day in
            day.first?.start.map { calendar.startOfDay(for: $0) == today } ?? false
        } ?? -1
        return scheduleDayToOpen(
            days: days, today: todayIndex, now: now,
            sessions: Set(sessions.map(\.contentId)), finished: finished)
    }
}

private struct ScheduleRow: View {
    let item: CatalogItem
    let now: Date

    var body: some View {
        let upcoming = item.isUpcoming(now: now)
        NavigationLink(value: Route.forItem(item)) {
            HStack(spacing: 12) {
                Text(item.start?.formatted(date: .omitted, time: .shortened) ?? "")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 72, alignment: .leading)
                Text(item.title)
                    .rowTitle()
                    .multilineTextAlignment(.leading)
                Spacer()
                if item.isLive {
                    Text("LIVE").liveBadge()
                }
            }
            .padding(12)
            .card()
            .opacity(upcoming ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .disabled(upcoming)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let subtitle = item.subtitle(now: now, calendar: .current)
        return subtitle.isEmpty ? item.title : "\(item.title), \(subtitle)"
    }
}
