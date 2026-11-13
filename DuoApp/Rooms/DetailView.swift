import F1TV
import SwiftUI

/// A session's picture, title and feeds. One feed plays straight away; otherwise the default feed
/// comes first, then the onboards with number, driver and a bar in the team colour.
struct DetailView: View {
    let item: CatalogItem
    let context: RoomContext

    @State private var state: LoadState<VideoDetail> = .loading
    @State private var attempt = 0
    @State private var autoPlayed = false

    /// A tile's item, or just what a bookmark remembers.
    init(item: CatalogItem, context: RoomContext) {
        self.item = item
        self.context = context
    }

    init(contentId: Int, title: String, picturePath: String?, context: RoomContext) {
        self.init(item: CatalogItem(contentId: contentId, title: title, picturePath: picturePath), context: context)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                AsyncImage(url: item.pictureURL(width: 1200, height: 675)) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFill()
                    default: Rectangle().fill(Theme.raised)
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                .accessibilityHidden(true)

                Text(item.title)
                    .heading(.title2)

                // Signed out, the play button itself reads "Sign in to watch." and opens sign-in.
                if !context.isSignedIn {
                    Button {
                        context.onSignIn()
                    } label: {
                        Text(AppModel.signInPrompt).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .controlSize(.large)
                }

                LoadStateView(state: state, retry: retry) { detail in
                    // No per-feed play buttons while signed out.
                    if context.isSignedIn {
                        multiviewEntry(detail)
                        feeds(detail)
                    }
                }
            }
            .padding()
        }
        .themedBackground()
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: attempt) { if !state.isLoaded { await load() } }
    }

    private func retry() {
        state = .loading
        attempt += 1
    }

    private func load() async {
        let contentId = item.contentId
        guard let result = await LoadState.run(
            keeping: state, { try await context.model.catalogue.video(contentId: contentId) })
        else { return }
        state = result
        // A single feed plays straight away (once, and only when signed in).
        if case .loaded(let detail) = result, !Task.isCancelled, detail.channels.count == 1, context.isSignedIn, !autoPlayed {
            autoPlayed = true
            play(detail, detail.channels[0])
        }
    }

    private func play(_ detail: VideoDetail, _ channel: Channel) {
        guard context.isSignedIn else {
            context.onSignIn()
            return
        }
        var playing = item
        if playing.title.isEmpty { playing.title = detail.title }
        context.onPlay(playing, channel)
    }

    /// Multiview for sessions with two feeds or more: the button for accounts that have it, a
    /// line saying what it needs for the others.
    @ViewBuilder
    private func multiviewEntry(_ detail: VideoDetail) -> some View {
        if detail.channels.count >= 2, case .signedIn(let account) = context.model.auth {
            if account.hasMultiview {
                Button {
                    watchMultiview(detail)
                } label: {
                    Label("Watch multiview", systemImage: "rectangle.split.2x2").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .controlSize(.large)
            } else {
                Text("Multiview needs F1 TV Premium")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func watchMultiview(_ detail: VideoDetail) {
        var titled = item
        if titled.title.isEmpty { titled.title = detail.title }
        let playing = titled
        let model = context.model
        Task { await model.openMultiview(item: playing, detail: detail) }
    }

    @ViewBuilder
    private func feeds(_ detail: VideoDetail) -> some View {
        // Default feed first, then the rest in F1 TV's order.
        let ordered = detail.channels.filter(\.isDefault) + detail.channels.filter { !$0.isDefault }
        if ordered.count == 1 {
            Button {
                play(detail, ordered[0])
            } label: {
                Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .controlSize(.large)
        } else {
            VStack(spacing: 8) {
                ForEach(Array(ordered.enumerated()), id: \.offset) { _, channel in
                    ChannelRow(channel: channel) { play(detail, channel) }
                }
            }
        }
    }
}

private struct ChannelRow: View {
    let channel: Channel
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if channel.isOnboard {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(hex: channel.teamColorHex) ?? .gray)
                        .frame(width: 5, height: 32)
                } else {
                    Image(systemName: "play.fill").foregroundStyle(Theme.textPrimary).frame(width: 5)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(channel.displayTitle).rowTitle()
                    if channel.isOnboard && !channel.teamName.isEmpty {
                        Text(channel.teamName).font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer()
            }
            .padding(12)
            .card()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(channel.isOnboard && !channel.teamName.isEmpty
            ? "\(channel.displayTitle), \(channel.teamName)" : channel.displayTitle)
    }
}

extension Color {
    /// "#E10600" or "E10600"; nil for anything else.
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255)
    }
}
