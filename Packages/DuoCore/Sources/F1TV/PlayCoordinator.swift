import Foundation

/// Asks F1 TV to play a feed, one play session at a time. A second PLAY request can end the
/// first session, so asking again for what is already playing (or loading) never sends one.
public actor PlayCoordinator {
    private struct Key: Equatable {
        var contentId: Int
        var channelId: Int?
    }

    private struct Pending {
        var key: Key
        var generation: Int
        var task: Task<PlayInfo, Error>
    }

    private let session: F1TVSession
    private var playing: (key: Key, info: PlayInfo)?
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
        if let playing, playing.key == key { return playing.info }
        // The same item is already being requested: wait for that one request.
        if let pending, pending.key == key {
            let info = try await pending.task.value
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
            if generation == mine { pending = nil }
            throw error
        }
    }

    public func stop() {
        pending?.task.cancel()
        pending = nil
        playing = nil
        generation += 1
    }

    private static func request(session: F1TVSession, key: Key) async throws -> PlayInfo {
        var query = [("contentId", "\(key.contentId)"), ("player", "player_bm")]
        if let channelId = key.channelId { query.append(("channelId", "\(channelId)")) }
        let json = try await session.getJSON(
            path: "CONTENT/PLAY", version: .play, platform: .webHLS, query: query, authorized: true)
        let info = try Parsers.play(json)
        // A DRM-protected stream can't play in this app yet; it never becomes the active one.
        if info.licenseURL != nil { throw F1TVError.protectedContent }
        return info
    }
}
