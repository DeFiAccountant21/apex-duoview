import AVFoundation
import F1TV
import Foundation
import Library
import Multiview
import Observation
import UIKit

/// Plays up to four feeds of one session together, from one multiview PLAY: one `AVPlayer` per
/// filled slot, every feed kept in step with slot 0 (the main feed). The sound is on one feed of
/// the viewer's choice (`audioChannelId`), the main one when the multiview opens.
/// Owned by the app model, not by a view, so a layout or fold change never stops or recreates a
/// player; tiles only show a player's picture.
/// Never logs or prints a stream URL, token or `MultiPlayInfo`.
@MainActor
@Observable
final class MultiviewController {
    static let slotCount = 4
    static let unavailableMessage = "Not available for this race"
    /// Saves every 10 ticks of 0.5 s: every 5 s, as the single-feed player does.
    static let saveEveryTicks = 10
    /// The access log is read every 2 ticks (1 s) for the dropped-frame count.
    static let sampleEveryTicks = 2
    /// The others start without a feed that is still not ready this long after the main one is.
    static let startDeadline: TimeInterval = 8
    /// A sync seek blocks further sync actions on its feed until it completes or this passes.
    static let seekTimeout: TimeInterval = 2
    /// Frozen feeds come back after this long without a stall.
    static let unfreezeAfter: TimeInterval = 30
    /// At most one fresh PLAY for expired links in this long.
    static let refreshSpacing: TimeInterval = 60
    /// Starting, seeking, swapping and speed changes drop frames anyway: struggle counts only
    /// after this long of steady playback (Android's `STEADY_MS`).
    static let steadyAfter: TimeInterval = 10
    /// Bit-rate cap for the feeds that are not the main one.
    static let otherPeakBitRate: Double = 2_500_000
    /// The resolution cap for a non-main feed until its tile reports its size.
    static let defaultOtherResolution = CGSize(width: 960, height: 540)
    /// How far ahead a sync seek aims at first, in seconds of wall time; learned per feed after.
    static let initialLead: Double = 0.5
    static let maximumLead: Double = 3

    /// True from the moment `open` is called until `close()`: the full-screen cover follows it.
    private(set) var isPresented = false
    private(set) var isLoading = false
    private(set) var errorText: String?
    /// Four entries; index 0 is the main feed (the biggest spot, and the one the others keep in
    /// step with). nil is an empty slot.
    private(set) var slots: [Channel?] = [nil, nil, nil, nil]
    /// The one feed that is heard. Chosen per tile, apart from the main spot: swapping, dragging,
    /// folding and layout changes never move it. Opening starts on the main feed; when this feed
    /// leaves the slots, stops or ends, the sound goes to the main feed. Not saved.
    private(set) var audioChannelId: Int?
    /// The session's feeds that the multiview PLAY returned a stream for.
    private(set) var channels: [Channel] = []
    private(set) var isPaused = false
    /// The speed chosen for every feed; sync nudges go on top of it.
    private(set) var rate: Double = 1
    /// The phone couldn't keep up: every feed but the main one and the one with the sound is
    /// paused on its last frame.
    private(set) var othersFrozen = false
    /// Why a feed other than the main one stopped, by channel id; its tile shows it.
    private(set) var feedProblems: [Int: String] = [:]
    /// Observed, so a tile picks up a player created after it appeared (a swap or a refresh).
    private var players: [Int: AVPlayer] = [:]
    /// Bumped when a layout choice is stored: the store isn't observed, this makes views re-read it.
    private var layoutRevision = 0

    @ObservationIgnored private let coordinator: PlayCoordinator
    @ObservationIgnored private let store: MultiviewStore
    @ObservationIgnored private let recents: RecentsStore
    @ObservationIgnored private let history: WatchHistory

    @ObservationIgnored private var currentItem: CatalogItem?
    @ObservationIgnored private var defaultChannelId: Int?
    @ObservationIgnored private var feedURLs: [Int: URL] = [:]
    /// Every feed the session lists, whether or not the PLAY returned a stream for it.
    @ObservationIgnored private var sessionChannels: [Channel] = []
    /// What each slot asks for, parallel to `slots` (moved with them). A pick whose feed this
    /// session lacks stays here, so saving `lastUsed` after a change never forgets it.
    @ObservationIgnored private var picks: [FeedPick?] = [nil, nil, nil, nil]
    @ObservationIgnored private var feeds: [Int: MultiviewFeed] = [:]
    /// Each tile's size in pixels, by channel id: the resolution cap for a non-main feed.
    @ObservationIgnored private var tilePixels: [Int: CGSize] = [:]
    /// Where the main feed starts once it is ready; a refresh sets it to the main feed's place.
    @ObservationIgnored private var pendingStart: Start = .position(0)
    /// The feeds were started together (or there was nothing to start).
    @ObservationIgnored private var started = false
    /// When the main feed was first in place, for the start deadline.
    @ObservationIgnored private var mainPlacedAt: Date?
    @ObservationIgnored private var steadySince: Date?
    @ObservationIgnored private var struggle = StruggleMonitor()
    @ObservationIgnored private var frozenAt: Date?
    @ObservationIgnored private var lastStallAt: Date?
    @ObservationIgnored private var lastRefreshAt: Date?
    @ObservationIgnored private var refreshing = false
    /// Set on leaving the foreground while playing: the system pauses video players then.
    @ObservationIgnored private var resumeOnActive = false
    /// Bumped by every open and close, so a slow answer for something superseded is dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var ticks = 0
    @ObservationIgnored private var appTokens: [NSObjectProtocol] = []

    init(coordinator: PlayCoordinator, store: MultiviewStore, recents: RecentsStore, history: WatchHistory) {
        self.coordinator = coordinator
        self.store = store
        self.recents = recents
        self.history = history
    }

    isolated deinit {
        tickTask?.cancel()
        for feed in feeds.values { feed.removeObservers() }
        for token in appTokens { NotificationCenter.default.removeObserver(token) }
    }

    /// The player showing this feed; nil while it loads or after it stopped.
    func player(for channelId: Int) -> AVPlayer? {
        players[channelId]
    }

    /// Where a session starts: a replay with a recent bookmark resumes there, any other replay
    /// starts at 0, and a live session at the live edge.
    func resumeStart(for item: CatalogItem) -> Start {
        guard let bookmark = recents.all().first(where: { $0.contentId == item.contentId }) else {
            return item.isLive ? .liveEdge : .position(0)
        }
        return ResumePlan.make(
            bookmark: bookmark,
            availableChannelIds: [bookmark.channelId],
            defaultChannelId: bookmark.channelId,
            isLiveNow: item.isLive,
            durationMs: item.durationSeconds.map { Int64($0) * 1_000 }).start
    }

    // MARK: Opening

    /// Sends one multiview PLAY for the session, fills the slots from the last-used picks and
    /// starts every filled slot together at `startAt`.
    func open(item: CatalogItem, detail: VideoDetail, startAt: Start) async {
        // Asking for what is already open changes nothing (and never sends a second PLAY).
        if isPresented, errorText == nil, currentItem?.contentId == item.contentId { return }
        generation += 1
        let mine = generation
        // Keep the place in the session being left, then drop it.
        save()
        teardownAll()
        var showing = item
        if showing.title.isEmpty { showing.title = detail.title }
        currentItem = showing
        defaultChannelId = (detail.channels.first(where: \.isDefault) ?? detail.channels.first)?.id
        resetSlots()
        feedURLs = [:]
        errorText = nil
        isPaused = false
        rate = 1
        pendingStart = startAt
        lastRefreshAt = nil
        isLoading = true
        isPresented = true

        // A close() just before this must finish its stop() first, or it could end this PLAY.
        if let stopTask { await stopTask.value }
        guard generation == mine else { return }

        let info: MultiPlayInfo
        do {
            info = try await coordinator.playMultiview(contentId: item.contentId, defaultChannelId: defaultChannelId)
        } catch is CancellationError {
            // Superseded (silent), or cancelled from outside with nothing newer: leave.
            if generation == mine { dismiss() }
            return
        } catch {
            guard generation == mine else { return }
            isLoading = false
            errorText = Self.message(for: error)
            return
        }
        guard generation == mine else { return }

        feedURLs = info.feeds
        // Links can't have expired seconds after this PLAY: a failure in the first minute is an
        // ordinary failure with its real message, never a second PLAY.
        lastRefreshAt = Date()
        sessionChannels = detail.channels
        channels = Self.playable(sessionChannels, in: info.feeds)
        // A remembered feed this session lacks leaves its slot empty; nothing else fills it.
        var remembered = Array(store.lastUsed.prefix(Self.slotCount))
        while remembered.count < Self.slotCount { remembered.append(nil) }
        picks = remembered
        slots = FeedPick.resolve(picks, in: channels)
        promoteMainIfEmpty()
        // Each opening starts with the sound on the main feed.
        audioChannelId = slots[0]?.id

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
        observeApp()
        startTicking()
        for channel in slots.compactMap({ $0 }) { attach(channel) }
        applyRoles()
        // Nothing to start: four empty slots wait for a pick.
        if feeds.isEmpty { isLoading = false }
    }

    // MARK: Closing

    func close() {
        save()
        generation += 1
        teardownAll()
        currentItem = nil
        defaultChannelId = nil
        feedURLs = [:]
        resetSlots()
        errorText = nil
        isLoading = false
        isPaused = false
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
        teardownAll()
        currentItem = nil
        feedURLs = [:]
        resetSlots()
        isLoading = false
        isPresented = false
    }

    private func resetSlots() {
        sessionChannels = []
        slots = Array(repeating: nil, count: Self.slotCount)
        picks = Array(repeating: nil, count: Self.slotCount)
        channels = []
        feedProblems = [:]
        audioChannelId = nil
    }

    // MARK: Slots

    /// Swaps a feed into the main spot: the two trade places, so the same call on the old main's
    /// new slot puts them back. The sound stays where it is.
    func makeMain(slot: Int) {
        // A feed that stopped can't take the main spot (it has no player to keep the others in step).
        guard slot > 0, slots.indices.contains(slot), let id = slots[slot]?.id, canBeMain(channelId: id),
              !refreshing, errorText == nil else { return }
        // Choosing a feed counts as the tap that brings frozen feeds back.
        if othersFrozen { unfreezeOthers() }
        slots.swapAt(0, slot)
        picks.swapAt(0, slot)
        slotsChanged()
    }

    /// Trades two slots' places (press, hold and drag one tile onto another). No PLAY, and the
    /// sound stays where it is. When one of them is slot 0, the main feed (the sync reference)
    /// changes exactly as `makeMain` changes it, so the feed going into slot 0 must have a player.
    func moveFeed(from: Int, to: Int) {
        guard from != to, slots.indices.contains(from), slots.indices.contains(to),
              slots[from] != nil, !refreshing, errorText == nil else { return }
        if from == 0 || to == 0 {
            let incoming = from == 0 ? to : from
            guard let id = slots[incoming]?.id, canBeMain(channelId: id) else { return }
        }
        // Like a tap, handling a feed brings frozen feeds back.
        if othersFrozen { unfreezeOthers() }
        slots.swapAt(from, to)
        picks.swapAt(from, to)
        slotsChanged()
    }

    /// Moves the sound to this feed: it alone is unmuted. Only a feed in a slot that is playing
    /// (not stopped, not at its end) can take it.
    func setAudio(channelId: Int) {
        guard channelId != audioChannelId, slots.contains(where: { $0?.id == channelId }),
              let feed = feeds[channelId], !feed.ended, feedProblems[channelId] == nil,
              !refreshing, errorText == nil else { return }
        // Brought back first, so a frozen feed taking the sound is lined up again before it plays
        // on; the feed that had the sound kept playing and needs nothing.
        if othersFrozen { unfreezeOthers() }
        audioChannelId = channelId
        applyRoles()
    }

    /// Whether this feed can take the main spot: it has a player that hasn't reached its end.
    func canBeMain(channelId: Int) -> Bool {
        guard let feed = feeds[channelId] else { return false }
        return !feed.ended
    }

    /// Whether this feed is paused on its last frame to keep the main feed smooth. The main feed
    /// and the feed with the sound never are.
    func isFrozen(channelId: Int) -> Bool {
        othersFrozen && slots[0]?.id != channelId && audioChannelId != channelId
    }

    // MARK: Layout choice

    /// The layout chosen for this posture and feed count (remembered across sessions), or the
    /// posture's default. `LayoutEngine.frames` falls back if it doesn't fit the screen.
    func layoutOption(for posture: Multiview.Posture, feedCount: Int) -> String {
        _ = layoutRevision
        let count = Self.layoutCount(feedCount)
        let options = LayoutEngine.optionIDs(posture: posture, feedCount: count)
        if let saved = store.layoutChoice(for: LayoutKey(posture: posture, feedCount: count)),
           options.contains(saved) {
            return saved
        }
        return options[0]
    }

    /// "Switch layout": the next layout among `usable` (the options that fit this screen, from
    /// `LayoutEngine.usableOptionIDs`; all of the posture's options when nil), stored as the
    /// choice for this posture and feed count.
    func cycleLayout(posture: Multiview.Posture, feedCount: Int, usable: [String]? = nil) {
        let count = Self.layoutCount(feedCount)
        let options = usable ?? LayoutEngine.optionIDs(posture: posture, feedCount: count)
        guard options.count > 1 else { return }
        // A choice that doesn't fit shows the first option that does: cycle on from that one.
        let current = layoutOption(for: posture, feedCount: count)
        let shown = options.firstIndex(of: current) ?? 0
        store.setLayoutChoice(options[(shown + 1) % options.count], for: LayoutKey(posture: posture, feedCount: count))
        layoutRevision += 1
    }

    private static func layoutCount(_ feedCount: Int) -> Int {
        min(max(feedCount, 1), slotCount)
    }

    /// Puts a feed in a slot, or empties it (nil). A feed already in another slot swaps places
    /// with this slot's: one feed never fills two slots. Emptying the main slot moves the next
    /// feed into it; emptying the slot with the sound moves the sound to the main feed.
    func setFeed(_ channel: Channel?, at slot: Int) {
        guard slots.indices.contains(slot), currentItem != nil, !refreshing, errorText == nil else { return }
        if othersFrozen { unfreezeOthers() }
        if let channel {
            guard let id = channel.id, feedURLs[id] != nil,
                  let chosen = channels.first(where: { $0.id == id }) else { return }
            if let other = slots.firstIndex(where: { $0?.id == id }) {
                if other == slot {
                    // Picking a feed that stopped again tries it once more.
                    guard feeds[id] == nil else { return }
                    attach(chosen)
                } else {
                    slots.swapAt(slot, other)
                    picks.swapAt(slot, other)
                }
            } else {
                if let old = slots[slot]?.id { detach(old) }
                slots[slot] = chosen
                picks[slot] = FeedPick(chosen)
                attach(chosen)
            }
        } else {
            guard let old = slots[slot]?.id else { return }
            detach(old)
            slots[slot] = nil
            picks[slot] = nil
            promoteMainIfEmpty()
        }
        slotsChanged()
    }

    private func slotsChanged() {
        // A feed put in (or moved out of) the slots never leaves the main spot empty while
        // another slot has a feed.
        promoteMainIfEmpty()
        keepAudioOnAFeed()
        applyRoles()
        // The new main feed may be mid-nudge, or parked waiting for the old main feed's moment:
        // it is the reference now, so it plays from where it is.
        if let main = mainFeed {
            if main.parked {
                main.parked = false
                updatePlayback(main)
            }
            setRunningRate(main, rate)
        }
        steadySince = Date()
        placeWaiting()
        maybeStart()
        store.lastUsed = picks
    }

    /// An empty main slot takes the first filled one: the main spot goes to the next feed.
    private func promoteMainIfEmpty() {
        guard slots[0] == nil, let first = slots.firstIndex(where: { $0 != nil }) else { return }
        slots.swapAt(0, first)
        picks.swapAt(0, first)
    }

    /// The sound goes to the main feed when its feed left the slots, stopped or reached its end.
    /// Judged by the slots, not by `feeds`: a link refresh empties `feeds` while the slots stay.
    /// The caller applies the roles.
    private func keepAudioOnAFeed() {
        if let id = audioChannelId, slots.contains(where: { $0?.id == id }), feedProblems[id] == nil,
           feeds[id]?.ended != true {
            return
        }
        let main = slots[0]?.id
        if audioChannelId != main { audioChannelId = main }
    }

    // MARK: Playback controls

    func play() {
        // A finished main feed plays again only after a seek back.
        guard !refreshing, currentItem != nil, mainFeed?.ended != true else { return }
        isPaused = false
        resumeOnActive = false
        steadySince = Date()
        for feed in feeds.values { updatePlayback(feed) }
    }

    func pause() {
        guard currentItem != nil else { return }
        isPaused = true
        resumeOnActive = false
        for feed in feeds.values {
            feed.measureLead = false
            updatePlayback(feed)
        }
    }

    /// Moves every feed by the same amount as the main one, so they stay in step.
    func seek(toSeconds seconds: Double) {
        guard seconds.isFinite, !refreshing, let main = mainFeed, main.positioned else { return }
        var target = max(seconds, 0)
        let duration = main.item.duration
        if duration.isNumeric, !duration.isIndefinite { target = min(target, max(duration.seconds, 0)) }
        let now = main.player.currentTime()
        let shift = now.isNumeric ? target - now.seconds : 0
        for feed in feeds.values {
            feed.ended = false
            feed.parked = false
        }
        seek(main, toSeconds: target, purpose: .move)
        // Frozen feeds are lined up again when they come back.
        for feed in otherFeeds where feed.positioned && !isFrozen(feed) {
            let time = feed.player.currentTime()
            guard time.isNumeric else { continue }
            seek(feed, toSeconds: time.seconds + shift, purpose: .move)
        }
        steadySince = Date()
    }

    /// One speed for every feed. A paused feed keeps it for when it plays.
    func setRate(_ newRate: Double) {
        guard newRate.isFinite, newRate > 0 else { return }
        rate = newRate
        for feed in feeds.values {
            feed.player.defaultRate = Float(newRate)
            setRunningRate(feed, newRate)
        }
        steadySince = Date()
    }

    /// Brings frozen feeds back (a tap, or 30 s without a stall), in step with the main feed.
    func unfreezeOthers() {
        guard othersFrozen else { return }
        // The feed with the sound kept playing in step: only the frozen ones are lined up again.
        let frozen = otherFeeds.filter { isFrozen($0) }
        othersFrozen = false
        frozenAt = nil
        // The stalls that froze them are still in the monitor's window: forget them.
        struggle.reset()
        steadySince = Date()
        for feed in otherFeeds { feed.droppedTotal = nil }
        for feed in frozen {
            guard feed.positioned else { continue }
            // Any seek still pending from before the freeze no longer counts.
            feed.seekToken += 1
            feed.seekStartedAt = nil
            feed.positioned = false
            feed.parked = false
            place(feed)
        }
    }

    /// A tile's size on screen in pixels (points × screen scale): the most a non-main feed
    /// loads. Rounded up in steps so a resize doesn't ask for new renditions on every frame.
    func setTileSize(_ pixels: CGSize, for channelId: Int) {
        guard pixels.width.isFinite, pixels.height.isFinite, pixels.width >= 1, pixels.height >= 1 else { return }
        let stepped = CGSize(
            width: (pixels.width / 64).rounded(.up) * 64,
            height: (pixels.height / 36).rounded(.up) * 36)
        guard tilePixels[channelId] != stepped else { return }
        tilePixels[channelId] = stepped
        if let feed = feeds[channelId] { applyRole(feed) }
    }

    // MARK: Feeds

    private var mainFeed: MultiviewFeed? {
        slots[0]?.id.flatMap { feeds[$0] }
    }

    /// The feeds of slots 1–3, in slot order.
    private var otherFeeds: [MultiviewFeed] {
        slots.dropFirst().compactMap { $0?.id }.compactMap { feeds[$0] }
    }

    /// Every filled slot's feed, main first.
    private var slotFeeds: [MultiviewFeed] {
        slots.compactMap { $0?.id }.compactMap { feeds[$0] }
    }

    private func isMain(_ feed: MultiviewFeed) -> Bool {
        slots[0]?.id == feed.channelId
    }

    private func isFrozen(_ feed: MultiviewFeed) -> Bool {
        isFrozen(channelId: feed.channelId)
    }

    private func attach(_ channel: Channel) {
        guard let id = channel.id, feeds[id] == nil, let url = feedURLs[id] else { return }
        // These URLs come from a PLAY that identified as Android Chrome (F1 TV only sends every
        // feed to that header). They play with AVPlayer's default settings, as beta.1's single
        // feeds do. If a build shows HTTP 403 on them, the fix is an AVURLAsset with
        // `AVURLAssetHTTPUserAgentKey` set to `Endpoints.androidUserAgent`.
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.defaultRate = Float(rate)
        player.isMuted = true
        let feed = MultiviewFeed(channelId: id, player: player, item: item)
        feeds[id] = feed
        players[id] = player
        feedProblems[id] = nil
        observeFeed(feed)
        applyRole(feed)
    }

    private func detach(_ channelId: Int) {
        if let feed = feeds[channelId] { stopPlayer(feed) }
        feeds[channelId] = nil
        players[channelId] = nil
        feedProblems[channelId] = nil
    }

    private func stopPlayer(_ feed: MultiviewFeed) {
        feed.removeObservers()
        feed.player.pause()
        feed.player.replaceCurrentItem(with: nil)
    }

    /// Sound follows `audioChannelId`: that feed alone is heard. Quality follows the slot: the
    /// main feed is unlimited, the others are capped to their tile.
    private func applyRoles() {
        for feed in feeds.values { applyRole(feed) }
    }

    private func applyRole(_ feed: MultiviewFeed) {
        let muted = feed.channelId != audioChannelId
        if feed.player.isMuted != muted { feed.player.isMuted = muted }
        if isMain(feed) {
            feed.item.preferredMaximumResolution = .zero
            feed.item.preferredPeakBitRate = 0
        } else {
            feed.item.preferredMaximumResolution = tilePixels[feed.channelId] ?? Self.defaultOtherResolution
            feed.item.preferredPeakBitRate = Self.otherPeakBitRate
        }
    }

    private func observeFeed(_ feed: MultiviewFeed) {
        let channelId = feed.channelId
        let itemID = feed.itemID
        // The callbacks may arrive on any thread: they carry only plain values, hop to the main
        // actor, and read the item there.
        feed.statusObservation = feed.item.observe(\.status, options: [.new]) { @Sendable [weak self] _, _ in
            Task { @MainActor [weak self] in self?.statusChanged(channelId: channelId, itemID: itemID) }
        }
        let center = NotificationCenter.default
        feed.tokens.append(center.addObserver(
            forName: AVPlayerItem.playbackStalledNotification, object: feed.item, queue: .main
        ) { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in self?.stalled(channelId: channelId, itemID: itemID) }
        })
        feed.tokens.append(center.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: feed.item, queue: .main
        ) { @Sendable [weak self] note in
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            let expired = MultiviewController.isExpiredLink(error)
            let reason = error?.localizedDescription ?? ""
            Task { @MainActor [weak self] in
                self?.feedFailed(channelId: channelId, itemID: itemID, expired: expired, reason: reason)
            }
        })
        feed.tokens.append(center.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: feed.item, queue: .main
        ) { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in self?.feedEnded(channelId: channelId, itemID: itemID) }
        })
    }

    private func liveFeed(_ channelId: Int, _ itemID: ObjectIdentifier) -> MultiviewFeed? {
        guard let feed = feeds[channelId], feed.itemID == itemID else { return nil }
        return feed
    }

    private func statusChanged(channelId: Int, itemID: ObjectIdentifier) {
        guard let feed = liveFeed(channelId, itemID) else { return }
        switch feed.item.status {
        case .readyToPlay:
            guard !feed.ready else { return }
            feed.ready = true
            place(feed)
            maybeStart()
        case .failed:
            let error = feed.item.error
            feedFailed(
                channelId: channelId, itemID: itemID,
                expired: Self.isExpiredLink(error), reason: error?.localizedDescription ?? "")
        default:
            break
        }
    }

    private func feedEnded(channelId: Int, itemID: ObjectIdentifier) {
        guard let feed = liveFeed(channelId, itemID) else { return }
        feed.ended = true
        guard isMain(feed) else {
            // The feed with the sound ended: the sound goes to the main feed.
            keepAudioOnAFeed()
            applyRoles()
            return
        }
        save()
        isPaused = true
        for other in feeds.values { updatePlayback(other) }
    }

    private func feedFailed(channelId: Int, itemID: ObjectIdentifier, expired: Bool, reason: String) {
        guard let feed = liveFeed(channelId, itemID) else { return }
        if expired, canRefresh {
            refreshLinks()
            return
        }
        let text = PlayerController.stoppedMessage(reason)
        if isMain(feed) {
            // As beta.1: the main feed stopping ends the multiview, with the reason.
            save()
            teardownAll()
            isLoading = false
            errorText = text
        } else {
            // Like Android's tiles: only this feed stops, and its tile says why.
            detach(channelId)
            feedProblems[channelId] = text
            keepAudioOnAFeed()
            applyRoles()
            maybeStart()
        }
    }

    // MARK: Starting together

    /// Puts a ready feed in place: in step with a feed already in place, or (the main feed, when
    /// none is) at the start position. Anything else waits for the main feed.
    private func place(_ feed: MultiviewFeed) {
        guard feed.ready, !feed.positioned, feed.seekStartedAt == nil else { return }
        if let reference = referenceFeed(excluding: feed) {
            join(feed, to: reference)
        } else if isMain(feed) {
            positionStart(feed)
        }
    }

    private func placeWaiting() {
        for feed in slotFeeds { place(feed) }
    }

    /// The feed others line up with: the main one, or while it isn't in place, any that is.
    private func referenceFeed(excluding feed: MultiviewFeed) -> MultiviewFeed? {
        if let main = mainFeed, main !== feed, main.positioned { return main }
        return slotFeeds.first { $0 !== feed && $0.positioned }
    }

    private func positionStart(_ feed: MultiviewFeed) {
        let duration = feed.item.duration
        let timeline: Timeline = duration.isIndefinite
            ? .live
            : .replay(durationMs: duration.isNumeric ? Int64((duration.seconds * 1_000).rounded()) : 0)
        let start = pendingStart.resolved(for: timeline)
        if case .position(let ms) = start, ms > 0 {
            seek(feed, toSeconds: Double(ms) / 1_000, purpose: .start)
        } else {
            // The live edge, or the beginning: AVPlayer starts there on its own.
            placed(feed)
        }
    }

    /// Lines a feed up with the reference: by program date when both streams carry one,
    /// otherwise by position. Once playing, it aims ahead by what the seek is expected to cost.
    private func join(_ feed: MultiviewFeed, to reference: MultiviewFeed) {
        let time = feed.player.currentTime()
        guard let offset = offsetSeconds(of: feed, from: reference), time.isNumeric else {
            placed(feed)
            return
        }
        let moving = started && !isPaused && reference.player.rate != 0
        let lead = moving ? feed.lead * rate : 0
        let target = time.seconds - offset + lead
        // This stream begins after the reference's moment: wait at its start until the
        // reference gets there, rather than seek to 0 again and again.
        // The main feed never parks: it is what the others wait for.
        feed.parked = target < 0 && !isMain(feed)
        seek(feed, toSeconds: target, purpose: .join)
    }

    private func placed(_ feed: MultiviewFeed) {
        feed.positioned = true
        feed.measureLead = started && !isPaused && !feed.parked
        if isMain(feed), mainPlacedAt == nil { mainPlacedAt = Date() }
        updatePlayback(feed)
        placeWaiting()
        maybeStart()
    }

    /// Starts every feed in the same main-actor turn once all are in place, or once the
    /// deadline after the main feed passes (the late ones join when ready).
    private func maybeStart() {
        guard !started, !refreshing, let main = mainFeed, main.positioned else { return }
        let waiting = slotFeeds.contains { !$0.positioned }
        let overdue = mainPlacedAt.map { Date().timeIntervalSince($0) >= Self.startDeadline } ?? false
        guard !waiting || overdue else { return }
        started = true
        isLoading = false
        steadySince = Date()
        struggle.reset()
        for feed in feeds.values { updatePlayback(feed) }
    }

    private func shouldPlay(_ feed: MultiviewFeed) -> Bool {
        started && feed.positioned && !feed.ended && !feed.parked && !isPaused && !refreshing
            && !isFrozen(feed)
    }

    /// Plays or pauses a feed to match the multiview. `play()` uses the feed's `defaultRate`.
    private func updatePlayback(_ feed: MultiviewFeed) {
        if shouldPlay(feed) {
            if feed.player.rate == 0 { feed.player.play() }
        } else if feed.player.rate != 0 {
            feed.player.pause()
        }
    }

    /// Changes the rate of a feed that is playing. Never touches a paused one: a non-zero rate
    /// would start it.
    private func setRunningRate(_ feed: MultiviewFeed, _ value: Double) {
        let target = Float(value)
        guard feed.player.rate != 0, feed.player.rate != target else { return }
        feed.player.rate = target
    }

    // MARK: Seeking

    private func seek(_ feed: MultiviewFeed, toSeconds seconds: Double, purpose: SeekPurpose) {
        feed.seekToken += 1
        let token = feed.seekToken
        feed.seekPurpose = purpose
        feed.seekStartedAt = Date()
        feed.measureLead = false
        let channelId = feed.channelId
        let itemID = feed.itemID
        let target = CMTime(seconds: max(seconds, 0), preferredTimescale: 600)
        feed.player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                self?.seekFinished(channelId: channelId, itemID: itemID, token: token)
            }
        }
    }

    private func seekFinished(channelId: Int, itemID: ObjectIdentifier, token: Int) {
        // Dropped if the feed was replaced, or the seek superseded or timed out.
        guard let feed = liveFeed(channelId, itemID), feed.seekToken == token, feed.seekStartedAt != nil else { return }
        finishSeek(feed)
    }

    private func finishSeek(_ feed: MultiviewFeed) {
        feed.seekStartedAt = nil
        switch feed.seekPurpose {
        case .start, .join:
            placed(feed)
        case .correct:
            // The first sync check after this measures where the seek landed.
            feed.measureLead = !isPaused
        case .move:
            break
        }
    }

    // MARK: The tick: sync, struggle, saving

    private func startTicking() {
        tickTask?.cancel()
        ticks = 0
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(500))
                } catch {
                    return
                }
                guard let self else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        ticks += 1
        let now = Date()
        // A sync seek that hasn't answered in 2 s no longer blocks its feed.
        for feed in feeds.values {
            if feed.seekPurpose == .correct, let since = feed.seekStartedAt,
               now.timeIntervalSince(since) >= Self.seekTimeout {
                feed.seekToken += 1
                finishSeek(feed)
            }
        }
        if !started {
            maybeStart()
        } else if !refreshing {
            followMain()
            sync()
            if ticks % Self.sampleEveryTicks == 0 { sampleDroppedFrames() }
            if othersFrozen {
                let quietSince = max(frozenAt ?? now, lastStallAt ?? .distantPast)
                if now.timeIntervalSince(quietSince) >= Self.unfreezeAfter { unfreezeOthers() }
            }
        }
        if ticks % Self.saveEveryTicks == 0 {
            // Paused ticks leave the watch history alone (it counts time).
            save(recordHistory: mainFeed?.player.timeControlStatus == .playing)
        }
    }

    /// The others follow the main feed. If something outside the app paused the main one
    /// (headphones unplugged, an interruption), the multiview counts as paused; otherwise a
    /// non-main feed the system paused is started again.
    private func followMain() {
        guard UIApplication.shared.applicationState == .active, let main = mainFeed, main.positioned else { return }
        if !isPaused, !main.ended, main.player.rate == 0 {
            isPaused = true
            for feed in feeds.values { updatePlayback(feed) }
            return
        }
        for feed in otherFeeds { updatePlayback(feed) }
    }

    /// Twice a second, like Android's `syncTick`: each other feed against the main one. Far off:
    /// a seek (aimed ahead by what that feed's seeks cost). Slightly off: a small rate nudge
    /// while playing. Feeds that are buffering, seeking or frozen are left alone; while the others
    /// are frozen, the feed with the sound is still kept in step.
    private func sync() {
        guard let main = mainFeed, main.positioned, main.seekStartedAt == nil, !main.ended else { return }
        let mainRunning = main.player.timeControlStatus == .playing
        // The main feed is buffering: wait for it rather than chase it.
        if !isPaused && !mainRunning { return }
        for feed in otherFeeds where !isFrozen(feed) {
            guard feed.positioned, feed.seekStartedAt == nil, !feed.ended else { continue }
            let offset = offsetSeconds(of: feed, from: main)
            if feed.parked {
                // Waiting at its start for the main feed to get there.
                if let offset, offset <= SyncPolicy.tolerance {
                    feed.parked = false
                    updatePlayback(feed)
                }
                continue
            }
            if !isPaused && feed.player.timeControlStatus != .playing { continue }
            if feed.measureLead {
                feed.measureLead = false
                // Ahead means the seek aimed too far; behind means it cost more than expected.
                if let offset, !isPaused {
                    feed.lead = min(max(feed.lead - offset / rate, 0), Self.maximumLead)
                }
            }
            switch SyncPolicy.action(offset: offset, baseRate: rate) {
            case .none:
                setRunningRate(feed, rate)
            case .nudge(rate: let nudged):
                if !isPaused { setRunningRate(feed, nudged) }
            case .seek(by: let shift):
                let time = feed.player.currentTime()
                guard time.isNumeric else { continue }
                setRunningRate(feed, rate)
                let lead = isPaused ? 0 : feed.lead * rate
                let target = time.seconds + shift + lead
                if target < 0 {
                    // Ahead of the main feed but already near its own start: park it there.
                    feed.parked = true
                    updatePlayback(feed)
                    seek(feed, toSeconds: 0, purpose: .move)
                } else {
                    seek(feed, toSeconds: target, purpose: .correct)
                }
            }
        }
    }

    /// This feed's time minus the reference's, in seconds (positive = ahead): by program date
    /// when both streams carry one, else by position. nil when neither can be compared.
    private func offsetSeconds(of feed: MultiviewFeed, from reference: MultiviewFeed) -> Double? {
        if let mine = feed.item.currentDate(), let theirs = reference.item.currentDate() {
            return mine.timeIntervalSince(theirs)
        }
        let mine = feed.player.currentTime()
        let theirs = reference.player.currentTime()
        guard mine.isNumeric, theirs.isNumeric else { return nil }
        return mine.seconds - theirs.seconds
    }

    // MARK: Struggling

    private func isSteady(_ now: Date) -> Bool {
        guard let steadySince else { return false }
        return now.timeIntervalSince(steadySince) >= Self.steadyAfter
    }

    /// Reads each playing non-main feed's access log. AVFoundation calls back on its own queue,
    /// so the callback is `@Sendable`, reads the count there and hands only that number over.
    private func sampleDroppedFrames() {
        guard !othersFrozen else { return }
        for feed in otherFeeds where feed.player.timeControlStatus == .playing {
            let channelId = feed.channelId
            let itemID = feed.itemID
            feed.item.fetchAccessLog(completionHandler: { @Sendable [weak self] log in
                guard let events = log?.events else { return }
                let dropped = events.reduce(0) { $0 + max($1.numberOfDroppedVideoFrames, 0) }
                Task { @MainActor [weak self] in
                    self?.droppedFramesRead(channelId: channelId, itemID: itemID, total: dropped)
                }
            })
        }
    }

    private func droppedFramesRead(channelId: Int, itemID: ObjectIdentifier, total: Int) {
        guard let feed = liveFeed(channelId, itemID) else { return }
        // The log's counts add up over the item's life: the monitor gets what is new.
        let previous = feed.droppedTotal
        feed.droppedTotal = total
        let now = Date()
        guard let previous, started, !othersFrozen, !isMain(feed), isSteady(now),
              feed.seekStartedAt == nil, feed.player.timeControlStatus == .playing else { return }
        struggle.record(
            droppedFrames: max(total - previous, 0),
            over: Double(Self.sampleEveryTicks) * 0.5,
            at: now)
        freezeIfStruggling(now)
    }

    private func stalled(channelId: Int, itemID: ObjectIdentifier) {
        guard let feed = liveFeed(channelId, itemID) else { return }
        let now = Date()
        lastStallAt = now
        guard started, !othersFrozen, !isMain(feed), isSteady(now), feed.seekStartedAt == nil else { return }
        struggle.record(stall: now)
        freezeIfStruggling(now)
    }

    /// When the phone can't keep up, the other feeds pause on their last frame; the main one and
    /// the one with the sound keep playing.
    private func freezeIfStruggling(_ now: Date) {
        guard !othersFrozen, struggle.shouldFreezeOthers(at: now) else { return }
        othersFrozen = true
        frozenAt = now
        for feed in otherFeeds where isFrozen(feed) {
            feed.measureLead = false
            updatePlayback(feed)
        }
    }

    // MARK: Expired links

    private var canRefresh: Bool {
        guard !refreshing, currentItem != nil else { return false }
        guard let lastRefreshAt else { return true }
        return Date().timeIntervalSince(lastRefreshAt) >= Self.refreshSpacing
    }

    /// One fresh multiview PLAY, then every slot reattached at the main feed's place, in step.
    /// A failed refresh leaves the coordinator with no session: the error shows and every player
    /// stays stopped. Never loops: at most one refresh in flight and one per minute.
    private func refreshLinks() {
        guard let item = currentItem else { return }
        refreshing = true
        lastRefreshAt = Date()
        if let start = mainStart() { pendingStart = start }
        teardownFeeds()
        isLoading = true
        let mine = generation
        let contentId = item.contentId
        let defaultChannelId = defaultChannelId
        let coordinator = coordinator
        Task { [weak self] in
            let result: Result<MultiPlayInfo, Error>
            do {
                result = .success(try await coordinator.playMultiview(
                    contentId: contentId, defaultChannelId: defaultChannelId, refresh: true))
            } catch {
                result = .failure(error)
            }
            self?.refreshed(result, generation: mine)
        }
    }

    private func refreshed(_ result: Result<MultiPlayInfo, Error>, generation mine: Int) {
        guard generation == mine, currentItem != nil else { return }
        refreshing = false
        switch result {
        case .failure(let error):
            teardownAll()
            isLoading = false
            errorText = Self.message(for: error)
        case .success(let info):
            feedURLs = info.feeds
            channels = Self.playable(sessionChannels, in: info.feeds)
            for index in slots.indices {
                if let id = slots[index]?.id, info.feeds[id] == nil { slots[index] = nil }
            }
            promoteMainIfEmpty()
            keepAudioOnAFeed()
            for channel in slots.compactMap({ $0 }) { attach(channel) }
            applyRoles()
            if feeds.isEmpty { isLoading = false }
        }
    }

    /// The session's feeds that a multiview PLAY returned a stream for.
    private static func playable(_ channels: [Channel], in feeds: [Int: URL]) -> [Channel] {
        channels.filter { channel in channel.id.map { feeds[$0] != nil } ?? false }
    }

    /// The main feed's place (or, while it isn't in place, another feed's), for starting again
    /// there: the live edge for a live stream.
    private func mainStart() -> Start? {
        let placedFeed: MultiviewFeed?
        if let main = mainFeed, main.positioned { placedFeed = main } else { placedFeed = slotFeeds.first(where: \.positioned) }
        guard let main = placedFeed else { return nil }
        if main.item.duration.isIndefinite { return .liveEdge }
        let now = main.player.currentTime()
        guard now.isNumeric else { return nil }
        return .position(max(Int64((now.seconds * 1_000).rounded()), 0))
    }

    /// Whether a feed failed because its signed link expired (HTTP 403 or 410). Unverified on a
    /// device: AVFoundation wraps HTTP failures in its own errors, so this walks the chain of
    /// underlying errors for the status as an error code, CoreMedia's code for HTTP 403
    /// (-12660), or "HTTP 403" / "HTTP 410" in a description.
    nonisolated static func isExpiredLink(_ error: (any Error)?) -> Bool {
        guard let error else { return false }
        var pending: [NSError] = [error as NSError]
        var visited = 0
        while !pending.isEmpty, visited < 16 {
            let next = pending.removeFirst()
            visited += 1
            if next.code == 403 || next.code == 410 { return true }
            if next.domain == "CoreMediaErrorDomain", next.code == -12660 { return true }
            let text = next.localizedDescription
            if text.contains("HTTP 403") || text.contains("HTTP 410") { return true }
            if let underlying = next.userInfo[NSUnderlyingErrorKey] as? NSError { pending.append(underlying) }
            if let several = next.userInfo["NSMultipleUnderlyingErrorsKey"] as? [NSError] {
                pending.append(contentsOf: several)
            }
        }
        return false
    }

    // MARK: Leaving and coming back

    private func observeApp() {
        let center = NotificationCenter.default
        // Delivered on the main queue, so the save runs now, before the app can be suspended.
        appTokens.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { @Sendable [weak self] _ in
            MainActor.assumeIsolated { self?.enteredBackground() }
        })
        appTokens.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { @Sendable [weak self] _ in
            MainActor.assumeIsolated { self?.becameActive() }
        })
    }

    private func enteredBackground() {
        save()
        // The system pauses video players in the background; they come back together.
        resumeOnActive = started && !isPaused
    }

    private func becameActive() {
        guard resumeOnActive else { return }
        resumeOnActive = false
        play()
    }

    // MARK: Saving

    /// Bookmark and watch history for the main feed's place. Skipped until the main feed is in
    /// place (and during a refresh), so a not-yet-seeked 0 never overwrites a good bookmark.
    private func save(recordHistory: Bool = true) {
        guard !refreshing, let item = currentItem, let channelId = slots[0]?.id,
              let main = feeds[channelId], main.positioned else { return }
        let duration = main.item.duration
        let live = duration.isIndefinite
        let now = main.player.currentTime()
        let positionMs = live || !now.isNumeric ? 0 : max(Int64((now.seconds * 1_000).rounded()), 0)
        let durationMs = live || !duration.isNumeric ? 0 : max(Int64((duration.seconds * 1_000).rounded()), 0)
        recents.save(WatchBookmark(
            contentId: item.contentId,
            title: item.title,
            picturePath: item.picturePath,
            channelId: channelId,
            positionMs: positionMs,
            durationMs: durationMs,
            live: live,
            savedAt: Date()))
        if recordHistory {
            history.record(contentId: item.contentId, positionMs: positionMs, durationMs: durationMs)
        }
    }

    // MARK: Teardown

    /// Stops every player; the slots stay.
    private func teardownFeeds() {
        for feed in feeds.values { stopPlayer(feed) }
        feeds = [:]
        players = [:]
        started = false
        mainPlacedAt = nil
        steadySince = nil
        othersFrozen = false
        frozenAt = nil
        lastStallAt = nil
        struggle.reset()
    }

    private func teardownAll() {
        teardownFeeds()
        tickTask?.cancel()
        tickTask = nil
        for token in appTokens { NotificationCenter.default.removeObserver(token) }
        appTokens = []
        refreshing = false
        resumeOnActive = false
    }

    // MARK: Messages

    /// Beta.1's messages, plus the multiview's own when F1 TV has no multiview for the race.
    static func message(for error: Error) -> String {
        if let error = error as? F1TVError, error == .multiviewUnavailable {
            return unavailableMessage
        }
        return PlayerController.message(for: error)
    }
}

/// Why a feed is seeking, so its completion knows what comes next.
private enum SeekPurpose {
    /// The main feed going to the start position.
    case start
    /// A feed lining up with the reference before it plays.
    case join
    /// A sync correction while playing.
    case correct
    /// A seek the viewer asked for.
    case move
}

/// One feed's player and what the controller knows about it.
@MainActor
private final class MultiviewFeed {
    let channelId: Int
    let player: AVPlayer
    let item: AVPlayerItem
    let itemID: ObjectIdentifier
    /// The item reported ready to play.
    var ready = false
    /// In place: at the start position (the main feed) or lined up with the others.
    var positioned = false
    var ended = false
    /// Its stream begins after the main feed's moment: paused at its start until the main feed
    /// gets there.
    var parked = false
    var seekToken = 0
    var seekPurpose: SeekPurpose = .start
    var seekStartedAt: Date?
    /// How far ahead a sync seek aims, in seconds of wall time.
    var lead: Double
    /// The next sync check measures where the last seek landed.
    var measureLead = false
    /// The access log's dropped-frame count at the last sample.
    var droppedTotal: Int?
    var statusObservation: NSKeyValueObservation?
    var tokens: [NSObjectProtocol] = []

    init(channelId: Int, player: AVPlayer, item: AVPlayerItem) {
        self.channelId = channelId
        self.player = player
        self.item = item
        self.itemID = ObjectIdentifier(item)
        self.lead = MultiviewController.initialLead
    }

    func removeObservers() {
        statusObservation?.invalidate()
        statusObservation = nil
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        tokens = []
    }
}
