import AVKit
import SwiftUI

/// AVKit's own player (its audio menu, scrubber, picture in picture and AirPlay), no custom
/// controls. The view controller comes from `PlayerController`, which keeps it while picture in
/// picture plays with the cover hidden, so the cover coming back shows the same one.
struct PlayerView: UIViewControllerRepresentable {
    let controller: PlayerController
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        controller.playerViewController(for: player)
    }

    func updateUIViewController(_ viewController: AVPlayerViewController, context: Context) {
        if viewController.player !== player { viewController.player = player }
    }
}

/// The full-screen cover: the player, a spinner while loading, or the error with Close.
struct PlayerCover: View {
    let controller: PlayerController

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player = controller.player {
                PlayerView(controller: controller, player: player).ignoresSafeArea()
            }
            if controller.isLoading {
                ProgressView().controlSize(.large).tint(.white)
            }
            if let text = controller.errorText {
                VStack(spacing: 16) {
                    Text(text)
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                    Button("Close") { controller.close() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                }
                .padding(24)
            }
        }
        .overlay(alignment: .topLeading) {
            if controller.errorText == nil {
                Button {
                    controller.close()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.5))
                }
                .padding(12)
                .accessibilityLabel("Close")
            }
        }
        .statusBarHidden(controller.player != nil)
    }
}
