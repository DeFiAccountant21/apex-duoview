import F1TV
import Foundation
import Library
import Multiview
import Observation

enum AuthState: Equatable {
    case signedOut
    case signingIn
    case signedIn(Account)
}

@MainActor
@Observable
final class AppModel {
    static let expiredMessage = "Your F1 TV sign-in has expired. Sign in again."
    static let signInPrompt = "Sign in to watch."

    var auth: AuthState = .signedOut
    var message: String?
    /// A token is saved but the last launch attempt failed for network or server reasons (not
    /// refused). Foreground and the banner's "Try again" retry it; a refusal never does.
    private(set) var restorePending = false

    @ObservationIgnored let session: F1TVSession
    @ObservationIgnored let catalogue: Catalogue
    @ObservationIgnored let player: PlayCoordinator
    @ObservationIgnored let recents: RecentsStore
    @ObservationIgnored let history: WatchHistory
    /// The one player, shown full screen by the root while it has something to show.
    @ObservationIgnored let playback: PlayerController
    /// The one multiview store: its writes are atomic per instance only.
    @ObservationIgnored let multiviewStore: MultiviewStore
    /// The multiview player, shown full screen by the root while it has something to show.
    @ObservationIgnored let multiview: MultiviewController
    /// Your driver (Settings › Multiview › My driver): their onboard is the second default feed.
    /// Mirrors the multiview store, which isn't observed.
    private(set) var favouriteDriver: String?

    init() {
        let session = F1TVSession(http: URLSessionHTTPClient())
        let store = UserDefaultsStore()
        let catalogue = Catalogue(session: session)
        let player = PlayCoordinator(session: session)
        let recents = RecentsStore(store: store)
        let history = WatchHistory(store: store)
        self.session = session
        self.catalogue = catalogue
        self.player = player
        self.recents = recents
        self.history = history
        self.playback = PlayerController(
            coordinator: player, recents: recents, history: history, catalogue: catalogue)
        let multiviewStore = MultiviewStore(store: store)
        self.multiviewStore = multiviewStore
        self.multiview = MultiviewController(
            coordinator: player, store: multiviewStore, recents: recents, history: history)
        favouriteDriver = multiviewStore.favouriteDriver
    }

    // MARK: Your driver

    /// The first-run "Pick your driver" sheet was answered (a driver, or Skip).
    var driverPromptShown: Bool { multiviewStore.driverPromptShown }

    /// The drivers to choose from, by racing number: the onboard feeds of the newest race replay
    /// of this season that has them. If this season has none (or can't load), the newest of the
    /// archive's races (F1 TV's 100 most watched). Empty when those races list no onboards.
    func driverChoices() async throws -> [Channel] {
        let season = Calendar.current.component(.year, from: Date())
        if let thisSeason = try? await catalogue.raceReplays(season: season),
           let drivers = try? await newestDrivers(in: thisSeason), !drivers.isEmpty {
            return drivers
        }
        return try await newestDrivers(in: try await catalogue.archiveRaces())
    }

    /// The onboards of the newest of these races that lists some, trying the newest three. Throws
    /// the last failure when none of them could be read.
    private func newestDrivers(in races: [CatalogItem]) async throws -> [Channel] {
        var lastError: Error?
        var readAny = false
        for race in DriverChoice.newestFirst(races).prefix(3) {
            do {
                let detail = try await catalogue.video(contentId: race.contentId)
                readAny = true
                let drivers = DriverChoice.drivers(in: detail.channels)
                if !drivers.isEmpty { return drivers }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        if !readAny, let lastError { throw lastError }
        return []
    }

    /// Settings › Multiview › My driver. Only the driver changes; the last-used feeds stay.
    func setFavouriteDriver(_ lastName: String?) {
        multiviewStore.favouriteDriver = lastName
        favouriteDriver = multiviewStore.favouriteDriver
    }

    /// The first-run sheet's answer: a driver (also resets the last-used feeds to the new
    /// default), or nil for "Skip". Either way it isn't asked again.
    func answerDriverPrompt(_ lastName: String?) {
        if let lastName {
            multiviewStore.favouriteDriver = lastName
            multiviewStore.resetToDefault()
            favouriteDriver = multiviewStore.favouriteDriver
        }
        multiviewStore.driverPromptShown = true
    }

    /// Opens a session's multiview where its bookmark left off (a live one at the live edge).
    /// The two players share one play session, so the single-feed one closes first, also when only
    /// its picture in picture is showing (never two windows at once).
    func openMultiview(item: CatalogItem, detail: VideoDetail) async {
        if playback.isPresented || playback.isInPictureInPicture { playback.close() }
        await multiview.open(item: item, detail: detail, startAt: multiview.resumeStart(for: item))
    }

    /// Launch: load the anonymous catalogue config, then sign in with the saved token.
    func restore() async {
        let saved = Keychain.loadToken()
        // With a saved token the sign-in screen must not show (or accept taps) while we prepare.
        if saved != nil { auth = .signingIn }
        // Browsing before sign-in needs the anonymous location; a failure here is retried by callers.
        try? await session.prepare()
        guard let token = saved else {
            restorePending = false
            auth = .signedOut
            message = Self.signInPrompt
            return
        }
        do {
            let account = try await session.signIn(token: token)
            restorePending = false
            auth = .signedIn(account)
            message = nil
        } catch is CancellationError {
            if Task.isCancelled { auth = .signedOut }
            return
        } catch F1TVError.refused {
            await expire(message: Self.expiredMessage)
        } catch {
            // The saved token stays: this may be only a bad connection. Foreground and
            // "Try again" retry it.
            restorePending = true
            auth = .signedOut
            message = Self.failureMessage(error)
        }
    }

    /// Retries a launch that failed for network or server reasons. Does nothing otherwise, and
    /// never retries a refused token (that token is already deleted).
    func retryRestore() async {
        guard restorePending, auth == .signedOut else { return }
        await restore()
    }

    func dismissMessage() { message = nil }

    func signIn(token: String) async {
        auth = .signingIn
        message = nil
        do {
            let account = try await session.signIn(token: token)
            Keychain.saveToken(token)
            auth = .signedIn(account)
        } catch is CancellationError {
            if Task.isCancelled { auth = .signedOut }
            return
        } catch F1TVError.refused {
            // A refused fresh paste leaves any saved token and the pending restore alone.
            await session.signOut()
            auth = .signedOut
            message = "F1 TV didn't accept that sign-in. Try again."
        } catch {
            auth = .signedOut
            message = Self.failureMessage(error)
        }
    }

    func signOut() {
        Keychain.deleteToken()
        restorePending = false
        auth = .signedOut
        message = Self.signInPrompt
        // Closing also stops the play session and keeps the bookmark.
        playback.close()
        multiview.close()
        let session = session
        let player = player
        Task {
            await player.stop()
            await session.signOut()
        }
    }

    /// Foreground re-check of the saved sign-in.
    func revalidate() async {
        if case .signedOut = auth, restorePending {
            await retryRestore()
            return
        }
        guard case .signedIn = auth, let token = Keychain.loadToken() else { return }
        do {
            let account = try await session.signIn(token: token)
            // A sign-out the user made while we waited stands.
            guard case .signedIn = auth else { return }
            auth = .signedIn(account)
        } catch is CancellationError {
            return
        } catch F1TVError.refused {
            guard case .signedIn = auth else { return }
            await expire(message: Self.expiredMessage)
        } catch {
            // A bad connection doesn't end a sign-in that may still be good.
        }
    }

    /// The one path for a refused sign-in (restore, sign-in, foreground check): the same as
    /// signing out, plus the reason. The bookmark and recents stay; the token, playback and the
    /// play session go.
    private func expire(message newMessage: String) async {
        Keychain.deleteToken()
        restorePending = false
        // Saves the bookmark first, then closes the players and stops the play session.
        playback.close()
        multiview.close()
        await player.stop()
        await session.signOut()
        auth = .signedOut
        message = newMessage
    }

    private static func failureMessage(_ error: Error) -> String {
        if case F1TVError.network(let reason) = error {
            return "Couldn't load F1 TV: \(reason)"
        }
        return "Couldn't load F1 TV."
    }
}
