import AVFoundation
import F1TV
import Foundation
import Library
import Observation
import UIKit

/// Plays one feed at a time: asks F1 TV for the stream, drives an `AVPlayer`, saves the place
/// (bookmark and watch history) while playing, and tears everything down on `close()`.
/// Never logs or prints the stream URL, tokens or `PlayInfo`.
@MainActor
@Observable
final class PlayerController {
    /// The player to show; nil while loading or after an error.
    private(set) var player: AVPlayer?
    /// True from the moment a start is requested until `close()`: the full-screen cover follows it.
    private(set) var isPresented = false
    private(set) var isLoading = false
    var errorText: String?
    /// The resume banner's "×": hides it for this run.
    var resumeBannerDismissed = false

    @ObservationIgnored private let coordinator: PlayCoordinator
    @ObservationIgnored private let recents: RecentsStore
    @ObservationIgnored private let history: WatchHistory
    @ObservationIgnored private let catalogue: Catalogue

    @ObservationIgnored private var currentItem: CatalogItem?
    @ObservationIgnored private var currentChannel: Channel?
    /// Saving waits until the item is ready (and any resume seek is done), so a not-yet-seeked
    /// position 0 never overwrites a good bookmark.
    @ObservationIgnored private var canSave = false
    /// Where to start, decided against the real timeline once the item is ready.
    @ObservationIgnored private var pendingStart: Start = .position(0)
    /// The AVPlayerItem callbacks are for; anything from another item is dropped.
    @ObservationIgnored private var currentItemID: ObjectIdentifier?
    /// Bumped by every start, resume and close, so a slow answer for something superseded is dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var stopTask: Task<Void, Never>?

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var observedPlayer: AVPlayer?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var notificationTokens: [NSObjectProtocol] = []

    static let saveInterval: Double = 5

    init(coordinator: PlayCoordinator, recents: RecentsStore, history: WatchHistory, catalogue: Catalogue) {
        self.coordinator = coordinator
        self.recents = recents
        self.history = history
        self.catalogue = catalogue
    }

    isolated deinit {
        removeObservers()
    }

    // MARK: Starting

    /// Plays from a tile: a replay with a recent bookmark for this feed resumes there, any other
    /// replay starts at 0, and a live session at the live edge.
    func play(item: CatalogItem, channel: Channel) async {
        var start: Start = item.isLive ? .liveEdge : .position(0)
        if let bookmark = recents.all().first(where: { $0.contentId == item.contentId && $0.channelId == channel.id }) {
            start = ResumePlan.make(
                bookmark: bookmark,
                availableChannelIds: [channel.id],
                defaultChannelId: channel.id,
                isLiveNow: item.isLive,
                durationMs: item.durationSeconds.map { Int64($0) * 1_000 }).start
        }
        await self.start(item: item, channel: channel, startAt: start)
    }

    func start(item: CatalogItem, channel: Channel, startAt: Start) async {
        // Asking for what is already on screen changes nothing (and never sends a second PLAY).
        if player != nil, errorText == nil, currentItem?.contentId == item.contentId, currentChannel?.id == channel.id {
            isPresented = true
            return
        }
        generation += 1
        let mine = generation
        // Keep the place in the feed being left, then drop it.
        save()
        teardownPlayback()
        currentItem = item
        currentChannel = channel
        errorText = nil
        isLoading = true
        isPresented = true

        // A close() just before this must finish its stop() first, or it could end this play.
        if let stopTask { await stopTask.value }
        guard generation == mine else { return }

        let info: PlayInfo
        do {
            info = try await coordinator.play(contentId: item.contentId, channelId: channel.id)
        } catch is CancellationError {
            // Superseded (silent), or cancelled from outside with nothing newer: leave the player.
            if generation == mine { dismiss() }
            return
        } catch {
            guard generation == mine else { return }
            isLoading = false
            errorText = Self.message(for: error)
            return
        }
        guard generation == mine else { return }
        begin(url: info.url, startAt: startAt)
    }

    /// Resumes a bookmark: fetches the session's feeds, plans the start and plays.
    func resume(_ bookmark: WatchBookmark) async {
        generation += 1
        let mine = generation
        errorText = nil
        isLoading = true
        isPresented = true
        let detail: VideoDetail
        do {
            detail = try await catalogue.video(contentId: bookmark.contentId)
        } catch is CancellationError {
            if generation == mine { dismiss() }
            return
        } catch {
            guard generation == mine else { return }
            isLoading = false
            errorText = Self.message(for: error)
            return
        }
        guard generation == mine else { return }
        let channels = detail.channels
        let defaultId = (channels.first(where: \.isDefault) ?? channels.first)?.id
        let plan = ResumePlan.make(
            bookmark: bookmark,
            availableChannelIds: channels.map(\.id),
            defaultChannelId: defaultId,
            isLiveNow: bookmark.live,
            durationMs: bookmark.durationMs)
        let channel = channels.first(where: { $0.id == plan.channelId }) ?? Channel(id: plan.channelId, isDefault: true)
        let item = CatalogItem(
            contentId: bookmark.contentId,
            title: detail.title.isEmpty ? bookmark.title : detail.title,
            picturePath: bookmark.picturePath)
        await start(item: item, channel: channel, startAt: plan.start)
    }

    // MARK: Closing

    func close() {
        save()
        generation += 1
        teardownPlayback()
        currentItem = nil
        currentChannel = nil
        errorText = nil
        isLoading = false
        isPresented = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        let coordinator = coordinator
        let previous = stopTask
        stopTask = Task {
            await previous?.value
            await coordinator.stop()
        }
    }

    /// Hides the cover without a stop(): nothing was playing (a cancelled request).
    private func dismiss() {
        teardownPlayback()
        currentItem = nil
        currentChannel = nil
        isLoading = false
        isPresented = false
    }

    // MARK: Playback

    private func begin(url: URL, startAt: Start) {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        pendingStart = startAt
        let itemID = ObjectIdentifier(item)
        currentItemID = itemID
        canSave = false
        self.player = player
        observedPlayer = player

        // The callbacks may arrive on any thread: they carry only the item's identity, hop to the
        // main actor, and read the item there.
        statusObservation = item.observe(\.status, options: [.new]) { @Sendable [weak self] _, _ in
            Task { @MainActor [weak self] in self?.statusChanged(itemID: itemID) }
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: Self.saveInterval, preferredTimescale: 1), queue: .main
        ) { @Sendable [weak self] _ in
            MainActor.assumeIsolated { self?.tick(itemID: itemID) }
        }

        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main
        ) { @Sendable [weak self] note in
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            let reason = error?.localizedDescription ?? ""
            Task { @MainActor [weak self] in
                guard self?.currentItemID == itemID else { return }
                self?.feedStopped(reason: reason)
            }
        })
        notificationTokens.append(center.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                guard self?.currentItemID == itemID else { return }
                self?.save()
            }
        })
        // The one background save: no scenePhase involved, so nothing saves twice. Delivered on
        // the main queue, so it runs now, before the app can be suspended.
        notificationTokens.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { @Sendable [weak self] _ in
            MainActor.assumeIsolated { self?.save() }
        })
    }

    private func statusChanged(itemID: ObjectIdentifier) {
        guard itemID == currentItemID, let player, let item = player.currentItem,
              ObjectIdentifier(item) == itemID else { return }
        switch item.status {
        case .readyToPlay:
            isLoading = false
            guard !canSave else { return }
            let duration = item.duration
            let timeline: Timeline = duration.isIndefinite
                ? .live
                : .replay(durationMs: duration.isNumeric ? Int64((duration.seconds * 1_000).rounded()) : 0)
            let start = pendingStart.resolved(for: timeline)
            pendingStart = .position(0)
            if case .position(let ms) = start, ms > 0 {
                let target = CMTime(value: CMTimeValue(ms), timescale: 1_000)
                player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { @Sendable [weak self] _ in
                    Task { @MainActor [weak self] in
                        // Dropped if the item was replaced or closed while seeking.
                        guard let self, self.currentItemID == itemID, let current = self.player else { return }
                        self.canSave = true
                        current.play()
                    }
                }
            } else {
                // The live edge, or the beginning: AVKit starts there on its own.
                canSave = true
                player.play()
            }
        case .failed:
            feedStopped(reason: item.error?.localizedDescription ?? "")
        default:
            break
        }
    }

    private func feedStopped(reason: String) {
        guard player != nil else { return }
        save()
        teardownPlayback()
        isLoading = false
        errorText = Self.stoppedMessage(reason)
    }

    /// Every 5 s once saving is possible, playing or not, so a seek or pause just before the app
    /// is killed keeps its position. Paused ticks leave the watch history alone (it counts time).
    private func tick(itemID: ObjectIdentifier) {
        guard itemID == currentItemID, let player else { return }
        save(recordHistory: player.timeControlStatus == .playing)
    }

    /// Bookmark and watch history, together. Skipped until the item is ready.
    private func save(recordHistory: Bool = true) {
        guard canSave, let item = currentItem, let channel = currentChannel,
              let player, let playerItem = player.currentItem else { return }
        let duration = playerItem.duration
        let live = duration.isIndefinite
        let now = player.currentTime()
        let positionMs = live || !now.isNumeric ? 0 : max(Int64((now.seconds * 1_000).rounded()), 0)
        let durationMs = live || !duration.isNumeric ? 0 : max(Int64((duration.seconds * 1_000).rounded()), 0)
        recents.save(WatchBookmark(
            contentId: item.contentId,
            title: item.title,
            picturePath: item.picturePath,
            channelId: channel.id,
            positionMs: positionMs,
            durationMs: durationMs,
            live: live,
            savedAt: Date()))
        if recordHistory {
            history.record(contentId: item.contentId, positionMs: positionMs, durationMs: durationMs)
        }
    }

    private func teardownPlayback() {
        removeObservers()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        canSave = false
        pendingStart = .position(0)
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

    // MARK: Messages

    static func message(for error: Error) -> String {
        switch error {
        case F1TVError.protectedContent:
            return "This session is protected and can't play in this app yet"
        case F1TVError.refused, F1TVError.noVideoPlan:
            return "F1 TV won't play this on your account. Its plan may not include this session."
        case F1TVError.notSignedIn:
            return AppModel.signInPrompt
        case F1TVError.network(let reason):
            let text = sanitized(reason)
            return text.isEmpty ? "Couldn't load F1 TV." : "Couldn't load F1 TV: \(text)"
        default:
            return "Couldn't load F1 TV."
        }
    }

    static func stoppedMessage(_ reason: String) -> String {
        let text = sanitized(reason)
        return text.isEmpty ? "This feed stopped." : "This feed stopped: \(text)."
    }

    /// Drops anything that looks like a link (AVFoundation can put the stream URL in an error),
    /// then tidies what is left.
    static func sanitized(_ reason: String) -> String {
        var text = reason.replacingOccurrences(
            of: #"[A-Za-z][A-Za-z0-9+.\-]*://\S*"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let trim = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".:,;()-"))
        return text.trimmingCharacters(in: trim)
    }
}
