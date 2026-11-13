import Foundation

/// Asks F1 TV to play a feed, one play session at a time. A second PLAY request can end the
/// first session, so asking again for what is already playing (or loading) never sends one.
public actor PlayCoordinator {
    private struct Key: Equatable {
        var contentId: Int
        var channelId: Int?
        var multiview = false
    }

    /// What one PLAY request produced; single and multiview share the one-session logic.
    private enum Played: Sendable {
        case single(PlayInfo)
        case multi(MultiPlayInfo)
    }

    private struct Pending {
        var key: Key
        var generation: Int
        var task: Task<Played, Error>
    }

    private let session: F1TVSession
    private var playing: (key: Key, info: Played)?
    private var pending: Pending?
    /// Bumped by every new request and by `stop()`, so a result that arrives after either is dropped.
    private var generation = 0

    public init(session: F1TVSession) {
        self.session = session
    }

    public var active: (contentId: Int, channelId: Int?)? {
        playing.map { ($0.key.contentId, $0.key.channelId) }
    }

    public func play(contentId: Int, channelId: Int?) async throws -> PlayInfo {
        let key = Key(contentId: contentId, channelId: channelId)
        guard case .single(let info) = try await start(key: key, refresh: false) else {
            throw F1TVError.badResponse("Unexpected PLAY result")
        }
        return info
    }

    /// One PLAY request for every feed of a race. Same one-session rules as `play`; `refresh`
    /// always sends a new request, for when the feed URLs have gone stale.
    public func playMultiview(
        contentId: Int, defaultChannelId: Int?, refresh: Bool = false
    ) async throws -> MultiPlayInfo {
        let key = Key(contentId: contentId, channelId: defaultChannelId, multiview: true)
        guard case .multi(let info) = try await start(key: key, refresh: refresh) else {
            throw F1TVError.badResponse("Unexpected PLAY result")
        }
        return info
    }

    private func start(key: Key, refresh: Bool) async throws -> Played {
        if !refresh, let playing, playing.key == key { return playing.info }
        // The same item is already being requested: wait for that one request.
        if let pending, pending.key == key {
            let info: Played
            do {
                info = try await pending.task.value
            } catch {
                // Superseded or stopped meanwhile: the failure is a cancellation, not a network error.
                if generation != pending.generation { throw CancellationError() }
                throw error
            }
            if let playing, playing.key == key, generation == pending.generation { return playing.info }
            guard generation == pending.generation else { throw CancellationError() }
            return info
        }

        // A different item replaces whatever was playing or loading.
        pending?.task.cancel()
        playing = nil
        generation += 1
        let mine = generation
        let session = self.session
        let task = Task { try await Self.request(session: session, key: key) }
        pending = Pending(key: key, generation: mine, task: task)
        do {
            let info = try await task.value
            guard generation == mine else { throw CancellationError() }
            playing = (key, info)
            pending = nil
            return info
        } catch {
            // Superseded by a newer play or by stop(): a cancelled request surfaces from the session
            // as a network error, but the caller must see a cancellation.
            guard generation == mine else { throw CancellationError() }
            pending = nil
            throw error
        }
    }

    public func stop() {
        pending?.task.cancel()
        pending = nil
        playing = nil
        generation += 1
    }

    private static func request(session: F1TVSession, key: Key) async throws -> Played {
        var query = [("contentId", "\(key.contentId)"), ("player", key.multiview ? "player_tm" : "player_bm")]
        if let channelId = key.channelId { query.append(("channelId", "\(channelId)")) }
        let json = try await session.getJSON(
            path: "CONTENT/PLAY", version: .play, platform: key.multiview ? .webDASH : .webHLS,
            query: query, authorized: true, multiview: key.multiview)
        // A DRM-protected stream can't play in this app yet; it never becomes the active one.
        if key.multiview { return .multi(try Parsers.multiPlay(json)) }
        let info = try Parsers.play(json)
        if info.licenseURL != nil { throw F1TVError.protectedContent }
        return .single(info)
    }
}
