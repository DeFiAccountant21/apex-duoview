import WebKit

/// Signs out of the model and clears what the web sign-in left in WebKit.
@MainActor
func signOutAndClearWebData(_ model: AppModel) {
    model.signOut()
    Task {
        await WKWebsiteDataStore.default().removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast)
    }
}
