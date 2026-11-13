import AVFoundation
import F1TV
import Foundation
import Observation
import SwiftUI
import UIKit

/// Debug only: plays four feeds of one session at once, each with its own PLAY request, and
/// measures how the device copes. It bypasses `PlayCoordinator` (which allows one play at a time).
/// Never shows, logs or copies a stream URL, token or `PlayInfo`.
struct MultiviewProbeView: View {
    let model: AppModel
    @State private var probe = ProbeModel()
    @State private var contentIdText = "1000010431"
    @State private var copied = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            controls
            grid
        }
        .themedBackground()
        .navigationTitle("Multiview probe")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(copied ? "Copied" : "Copy report") {
                    UIPasteboard.general.string = probe.report()
                    copied = true
                }
                .disabled(probe.feeds.isEmpty)
            }
        }
        .task { await probe.refreshLoop() }
        .onDisappear { probe.stop() }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                TextField("Content ID", text: $contentIdText)
                    .keyboardType(.numberPad)
                    .font(.body.monospacedDigit())
                    .focused($fieldFocused)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                    .disabled(probe.isRunning)
                Button(probe.isRunning ? "Stop" : "Start") {
                    fieldFocused = false
                    copied = false
                    if probe.isRunning {
                        probe.stop()
                    } else if let id = Int(contentIdText.trimmingCharacters(in: .whitespaces)), id > 0 {
                        probe.start(contentId: id, app: model)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
            }
            HStack {
                Text(probe.status ?? "Starts four muted feeds, one PLAY each, a second apart.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                Spacer()
                Text("Elapsed").sectionLabel()
                Text(ProbeFormat.seconds(probe.elapsed))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: Grid

    private var grid: some View {
        VStack(spacing: 2) {
            HStack(spacing: 2) { cell(0); cell(1) }
            HStack(spacing: 2) { cell(2); cell(3) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func cell(_ slot: Int) -> some View {
        ProbeCell(feed: slot < probe.feeds.count ? probe.feeds[slot] : nil)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
    }
}

// MARK: - One cell

private struct ProbeCell: View {
    let feed: ProbeFeed?

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black
            if let feed {
                PlayerLayerView(player: feed.player)
                overlay(feed)
            } else {
                Text("No feed").font(.caption).foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private func overlay(_ feed: ProbeFeed) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(feed.title).rowTitle(.caption).lineLimit(1)
                Spacer(minLength: 4)
                Text(ProbeFormat.seconds(feed.elapsed))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
            }
            Text(feed.phaseText)
                .font(.caption2)
                .foregroundStyle(feed.isProblem ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(3)
            HStack(spacing: 6) {
                stat("Start", ProbeFormat.seconds(feed.firstFrameSeconds, decimals: 2))
                stat("Stalls", "\(feed.stalls)")
                stat("Dropped", "\(feed.droppedFrames)")
                stat("Bitrate", ProbeFormat.mbps(feed.indicatedBitrate))
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.65))
        .accessibilityElement(children: .combine)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).sectionLabel().lineLimit(1).minimumScaleFactor(0.6)
            Text(value)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Player layer

private final class PlayerLayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        // layerClass guarantees the type.
        layer as! AVPlayerLayer
    }
}

private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer?

    func makeUIView(context: Context) -> PlayerLayerUIView {
        let view = PlayerLayerUIView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: PlayerLayerUIView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}

// MARK: - Formatting

enum ProbeFormat {
    static func seconds(_ value: Double?, decimals: Int = 0) -> String {
        guard let value else { return "–" }
        return String(format: "%.\(decimals)fs", value)
    }

    static func mbps(_ bitsPerSecond: Double?) -> String {
        guard let bitsPerSecond, bitsPerSecond > 0 else { return "–" }
        return String(format: "%.1fM", bitsPerSecond / 1_000_000)
    }
}

// MARK: - Model

/// The run: finds the feeds, sends one PLAY per feed a second apart, owns the four `ProbeFeed`s.
@MainActor
@Observable
final class ProbeModel {
    private(set) var feeds: [ProbeFeed] = []
    private(set) var status: String?
    private(set) var isRunning = false
    private(set) var elapsed: Double = 0
    private(set) var feedsAvailable = 0
    private(set) var contentId: Int?

    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var startedAt: Double?

    static let maxFeeds = 4

    func start(contentId: Int, app: AppModel) {
        stop()
        self.contentId = contentId
        feeds = []
        feedsAvailable = 0
        elapsed = 0
        isRunning = true
        status = "Closing the current player…"
        startedAt = ProcessInfo.processInfo.systemUptime
        runTask = Task { [weak self] in
            await self?.run(contentId: contentId, app: app)
        }
    }

    /// Cancels the run and tears down all four players. Keeps the numbers for the report.
    func stop() {
        runTask?.cancel()
        runTask = nil
        refresh()
        for feed in feeds { feed.stop() }
        if isRunning { status = "Stopped." }
        isRunning = false
    }

    func refreshLoop() async {
        while !Task.isCancelled {
            refresh()
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func refresh() {
        if isRunning, let startedAt {
            elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        }
        for feed in feeds { feed.refresh() }
    }

    // MARK: Run

    private func run(contentId: Int, app: AppModel) async {
        // The probe's four PLAYs must be the only streams: end any single-feed playback first.
        app.playback.close()
        await app.player.stop()
        guard !Task.isCancelled else { return }

        status = "Loading the feed list…"
        let detail: VideoDetail
        do {
            detail = try await app.catalogue.video(contentId: contentId)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            status = PlayerController.message(for: error)
            isRunning = false
            return
        }
        guard !Task.isCancelled else { return }

        let picked = Self.pick(detail.channels)
        guard !picked.isEmpty else {
            status = "F1 TV lists no feeds for this content ID."
            isRunning = false
            return
        }
        feedsAvailable = picked.count
        feeds = picked.enumerated().map { ProbeFeed(slot: $0.offset, channel: $0.element) }
        status = "\(picked.count) of \(Self.maxFeeds) feeds available."

        for (index, feed) in feeds.enumerated() {
            if index > 0 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
            }
            await load(feed, contentId: contentId, app: app)
            guard !Task.isCancelled else { return }
        }
    }

    /// The same request `PlayCoordinator` makes, without its one-play-at-a-time bookkeeping.
    private func load(_ feed: ProbeFeed, contentId: Int, app: AppModel) async {
        feed.markRequesting()
        var query = [("contentId", "\(contentId)"), ("player", "player_bm")]
        if let channelId = feed.channelId { query.append(("channelId", "\(channelId)")) }
        do {
            let json = try await app.session.getJSON(
                path: "CONTENT/PLAY", version: .play, platform: .webHLS, query: query, authorized: true)
            guard !Task.isCancelled else { return }
            let info = try Parsers.play(json)
            if info.licenseURL != nil {
                feed.skip(reason: "Protected stream, skipped.")
                return
            }
            feed.begin(url: info.url)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            feed.fail(reason: PlayerController.message(for: error))
        }
    }

    /// The default feed, then the first three onboards.
    static func pick(_ channels: [Channel]) -> [Channel] {
        guard let main = channels.first(where: \.isDefault) ?? channels.first else { return [] }
        let onboards = channels.filter { $0.isOnboard && $0.id != nil && $0.id != main.id }
        return [main] + onboards.prefix(maxFeeds - 1)
    }

    // MARK: Report

    /// Plain text for the owner to paste. No URLs, tokens or PlayInfo.
    func report() -> String {
        let device = UIDevice.current
        var lines = [
            "Apex DuoView multiview probe",
            "Device: \(device.model), iOS \(device.systemVersion)",
            "Content ID: \(contentId.map(String.init) ?? "-")",
            "Feeds available: \(feedsAvailable) of \(Self.maxFeeds); playing or tried: \(feeds.count)",
            String(format: "Elapsed: %.0f s", elapsed),
            "",
        ]
        for feed in feeds {
            let first = feed.firstFrameSeconds.map { String(format: "%.2f s", $0) } ?? "none"
            let bitrate = feed.indicatedBitrate.flatMap { $0 > 0 ? String(format: "%.2f Mbps", $0 / 1_000_000) : nil } ?? "n/a"
            lines.append("Feed \(feed.slot + 1) (\(feed.title)): \(feed.phaseText)")
            lines.append("  Start (play() to ready + time advancing): \(first)")
            lines.append("  Stalls: \(feed.stalls)")
            lines.append("  Dropped frames: \(feed.droppedFrames)")
            lines.append("  Indicated bitrate: \(bitrate)")
            lines.append(String(format: "  Elapsed: %.0f s", feed.elapsed))
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - One feed

/// One feed's `AVPlayer`, its observers and its numbers. Observers hop to the main actor the way
/// `PlayerController` does.
@MainActor
@Observable
final class ProbeFeed {
    enum Phase: Equatable {
        case waiting, requesting, loading, playing, stopped
        case skipped(String)
        case failed(String)
    }

    let slot: Int
    let title: String
    let channelId: Int?

    private(set) var phase: Phase = .waiting
    private(set) var player: AVPlayer?
    private(set) var firstFrameSeconds: Double?
    private(set) var stalls = 0
    private(set) var droppedFrames = 0
    private(set) var indicatedBitrate: Double?
    private(set) var elapsed: Double = 0

    @ObservationIgnored private var playStartedAt: Double?
    @ObservationIgnored private var baselineTime: Double?
    @ObservationIgnored private var currentItemID: ObjectIdentifier?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var observedPlayer: AVPlayer?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var notificationTokens: [NSObjectProtocol] = []

    init(slot: Int, channel: Channel) {
        self.slot = slot
        self.channelId = channel.id
        self.title = channel.title.isEmpty ? "Feed \(slot + 1)" : channel.title
    }

    isolated deinit {
        removeObservers()
    }

    var phaseText: String {
        switch phase {
        case .waiting: "Waiting"
        case .requesting: "Requesting PLAY…"
        case .loading: "Loading…"
        case .playing: "Playing"
        case .stopped: "Stopped"
        case .skipped(let reason), .failed(let reason): reason
        }
    }

    var isProblem: Bool {
        switch phase {
        case .skipped, .failed: true
        default: false
        }
    }

    func markRequesting() { phase = .requesting }

    func skip(reason: String) { phase = .skipped(reason) }

    func fail(reason: String) {
        refresh()
        teardown()
        phase = .failed(reason)
    }

    /// Starts the muted player. The clock for "start" runs from this `play()` call.
    func begin(url: URL) {
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        let itemID = ObjectIdentifier(item)
        currentItemID = itemID
        self.player = player
        observedPlayer = player
        phase = .loading

        // The callbacks may arrive on any thread: they carry only the item's identity, hop to the
        // main actor, and read the item there.
        statusObservation = item.observe(\.status, options: [.new]) { @Sendable [weak self] _, _ in
            Task { @MainActor [weak self] in self?.statusChanged(itemID: itemID) }
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main
        ) { @Sendable [weak self] _ in
            MainActor.assumeIsolated { self?.tick(itemID: itemID) }
        }

        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(
            forName: AVPlayerItem.playbackStalledNotification, object: item, queue: .main
        ) { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.currentItemID == itemID else { return }
                self.stalls += 1
            }
        })
        notificationTokens.append(center.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main
        ) { @Sendable [weak self] note in
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            let reason = error?.localizedDescription ?? ""
            Task { @MainActor [weak self] in
                guard let self, self.currentItemID == itemID else { return }
                self.fail(reason: PlayerController.stoppedMessage(reason))
            }
        })

        playStartedAt = ProcessInfo.processInfo.systemUptime
        player.play()
    }

    /// Reads the access log and the clock. Called every second by the model.
    func refresh() {
        if let startedAt = playStartedAt, phase == .loading || phase == .playing {
            elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        }
        guard let item = player?.currentItem, let events = item.accessLog()?.events else { return }
        droppedFrames = events.reduce(0) { $0 + max($1.numberOfDroppedVideoFrames, 0) }
        if let last = events.last, last.indicatedBitrate > 0 { indicatedBitrate = last.indicatedBitrate }
    }

    /// Tears down the player and every observer. The numbers stay for the report.
    func stop() {
        refresh()
        teardown()
        switch phase {
        case .loading, .playing, .requesting, .waiting: phase = .stopped
        default: break
        }
    }

    // MARK: Callbacks

    private func statusChanged(itemID: ObjectIdentifier) {
        guard itemID == currentItemID, let item = player?.currentItem,
              ObjectIdentifier(item) == itemID, item.status == .failed else { return }
        fail(reason: PlayerController.stoppedMessage(item.error?.localizedDescription ?? ""))
    }

    /// "Start" is the first time the time advances after the item is ready: a decoded frame is
    /// on its way, but this is not `isReadyForDisplay`, so it can read slightly early or late.
    private func tick(itemID: ObjectIdentifier) {
        guard itemID == currentItemID, firstFrameSeconds == nil, let player,
              player.currentItem?.status == .readyToPlay else { return }
        let time = player.currentTime()
        guard time.isNumeric, let startedAt = playStartedAt else { return }
        guard let baseline = baselineTime else {
            baselineTime = time.seconds
            return
        }
        if time.seconds > baseline + 0.05 {
            firstFrameSeconds = ProcessInfo.processInfo.systemUptime - startedAt
            phase = .playing
        }
    }

    private func teardown() {
        removeObservers()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        currentItemID = nil
    }

    private func removeObservers() {
        if let timeObserver, let observedPlayer {
            observedPlayer.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        observedPlayer = nil
        statusObservation?.invalidate()
        statusObservation = nil
        for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
        notificationTokens = []
    }
}
