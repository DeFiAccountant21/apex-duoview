import F1TV
import Foundation
import Library
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

    @ObservationIgnored let session: F1TVSession
    @ObservationIgnored let catalogue: Catalogue
    @ObservationIgnored let player: PlayCoordinator
    @ObservationIgnored let recents: RecentsStore
    @ObservationIgnored let history: WatchHistory

    init() {
        let session = F1TVSession(http: URLSessionHTTPClient())
        let store = UserDefaultsStore()
        self.session = session
        self.catalogue = Catalogue(session: session)
        self.player = PlayCoordinator(session: session)
        self.recents = RecentsStore(store: store)
        self.history = WatchHistory(store: store)
    }

    /// Launch: load the anonymous catalogue config, then sign in with the saved token.
    func restore() async {
        let saved = Keychain.loadToken()
        // With a saved token the sign-in screen must not show (or accept taps) while we prepare.
        if saved != nil { auth = .signingIn }
        // Browsing before sign-in needs the anonymous location; a failure here is retried by callers.
        try? await session.prepare()
        guard let token = saved else {
            auth = .signedOut
            message = Self.signInPrompt
            return
        }
        do {
            let account = try await session.signIn(token: token)
            auth = .signedIn(account)
            message = nil
        } catch is CancellationError {
            if Task.isCancelled { auth = .signedOut }
            return
        } catch F1TVError.refused {
            await session.signOut()
            auth = .signedOut
            message = Self.expiredMessage
        } catch {
            // The saved token stays: this may be only a bad connection.
            auth = .signedOut
            message = Self.failureMessage(error)
        }
    }

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
        auth = .signedOut
        message = Self.signInPrompt
        let session = session
        let player = player
        Task {
            await player.stop()
            await session.signOut()
        }
    }

    /// Foreground re-check of the saved sign-in.
    func revalidate() async {
        guard case .signedIn = auth, let token = Keychain.loadToken() else { return }
        do {
            let account = try await session.signIn(token: token)
            auth = .signedIn(account)
        } catch is CancellationError {
            return
        } catch F1TVError.refused {
            // Saved bookmark and recents stay; only the session and the signed-in state go.
            await session.signOut()
            auth = .signedOut
            message = Self.expiredMessage
        } catch {
            // A bad connection doesn't end a sign-in that may still be good.
        }
    }

    private static func failureMessage(_ error: Error) -> String {
        if case F1TVError.network(let reason) = error {
            return "Couldn't load F1 TV: \(reason)"
        }
        return "Couldn't load F1 TV."
    }
}
