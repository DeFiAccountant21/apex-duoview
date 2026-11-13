import F1TV
import SwiftUI

/// The state of one load on a screen. Each load has its own, so "Try again" retries only that one.
enum LoadState<Value> {
    case loading
    case loaded(Value)
    case failed(String)

    var value: Value? {
        if case .loaded(let value) = self { return value }
        return nil
    }

    /// True once a value has loaded (also when that value is itself nil).
    var isLoaded: Bool {
        if case .loaded = self { return true }
        return false
    }

    /// Runs a refresh of a load that may already have content. Returns nil (leave the state alone)
    /// when cancelled, and also when the refresh failed but `current` already holds content: a
    /// failed refresh never replaces what is on screen.
    @MainActor
    static func run(keeping current: LoadState<Value>, _ operation: () async throws -> Value) async -> LoadState<Value>? {
        guard let result = await run(operation) else { return nil }
        if case .failed = result, current.isLoaded { return nil }
        return result
    }

    /// Runs one load. Returns nil when the task was cancelled (leave the state alone then).
    @MainActor
    static func run(_ operation: () async throws -> Value) async -> LoadState<Value>? {
        do {
            return .loaded(try await operation())
        } catch is CancellationError {
            return nil
        } catch {
            if Task.isCancelled { return nil }
            return .failed(loadMessage(error))
        }
    }
}

/// A short, plain reason for a failed load. Never contains URLs or tokens.
func loadMessage(_ error: Error) -> String {
    guard let error = error as? F1TVError else { return error.localizedDescription }
    switch error {
    case .notSignedIn: return "you're not signed in."
    case .refused(let status): return "F1 TV refused the request (\(status))."
    case .noVideoPlan: return "this account has no video plan."
    case .network(let reason): return reason
    case .server(let status, _): return "F1 TV answered with an error (\(status))."
    case .badResponse(let reason): return reason
    case .protectedContent: return "this content is protected."
    }
}

/// Shows a load's result, or its progress, or "Couldn't load F1 TV: …" with "Try again".
struct LoadStateView<Value, Content: View>: View {
    let state: LoadState<Value>
    let retry: @MainActor () -> Void
    @ViewBuilder let content: (Value) -> Content

    var body: some View {
        switch state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 80)
        case .loaded(let value):
            content(value)
        case .failed(let message):
            LoadFailedView(message: message, retry: retry)
        }
    }
}

struct LoadFailedView: View {
    let message: String
    let retry: @MainActor () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text("Couldn't load F1 TV: \(message)")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button("Try again", action: retry)
                .buttonStyle(.bordered)
                .tint(Theme.accent)
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}
