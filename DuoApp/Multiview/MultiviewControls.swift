import F1TV
import Multiview
import SwiftUI

/// The multiview's own controls, in the beta.1 style (dark translucent capsules, condensed
/// headings, red only for progress and LIVE), laid inside the safe area by `MultiviewView`.
///
/// - Top: Close, the session title, "Switch layout" (only with more than one usable layout) and
///   "Feeds".
/// - Bottom: one scrubber for every feed with the elapsed and remaining time, play/pause, LIVE for
///   live sessions, the speed (not at the live edge) and the audio language of the feed with the
///   sound (only with more than one option).
///
/// `MultiviewView` decides when they show. Hidden, they stay in place, see-through and untouchable
/// (an open menu isn't torn down when the timer fires), and a small handle at the top edge brings
/// them back. Only the buttons and the bottom panel take touches: the space between them reaches
/// the tiles underneath. A notice ("Caught up to live…") shows whether or not the controls do.
///
/// The time is read only by `MultiviewScrubber` and `MultiviewPlaybackBar`, so the twice-a-second
/// update redraws them alone, never the tiles.
struct MultiviewControls: View {
    let controller: MultiviewController
    let visible: Bool
    let canSwitchLayout: Bool
    /// True while the scrubber is held: the controls stay up.
    @Binding var scrubbing: Bool
    let onShow: @MainActor () -> Void
    /// Any use of the controls restarts the hide timer.
    let onInteraction: @MainActor () -> Void
    let onSwitchLayout: @MainActor () -> Void
    let onFeeds: @MainActor () -> Void

    var body: some View {
        // The error has its own Close, over everything.
        if controller.errorText == nil {
            ZStack {
                VStack(spacing: 0) {
                    MultiviewTopBar(
                        controller: controller,
                        canSwitchLayout: canSwitchLayout,
                        onInteraction: onInteraction,
                        onSwitchLayout: onSwitchLayout,
                        onFeeds: onFeeds)
                    Spacer(minLength: 0)
                    MultiviewPlaybackBar(controller: controller, scrubbing: $scrubbing, onInteraction: onInteraction)
                }
                .opacity(visible ? 1 : 0)
                .allowsHitTesting(visible)
                .accessibilityHidden(!visible)

                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        MultiviewControlsHandle(onShow: onShow)
                        Spacer(minLength: 0)
                    }
                    Spacer(minLength: 0)
                }
                .opacity(visible ? 0 : 1)
                .allowsHitTesting(!visible)
                .accessibilityHidden(visible)

                MultiviewNoticeView(controller: controller)
            }
            .animation(.easeOut(duration: 0.2), value: visible)
        }
    }
}

// MARK: - Top bar

/// Close and the title on the leading side; "Switch layout" and "Feeds" on the trailing side.
struct MultiviewTopBar: View {
    let controller: MultiviewController
    let canSwitchLayout: Bool
    let onInteraction: @MainActor () -> Void
    let onSwitchLayout: @MainActor () -> Void
    let onFeeds: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button {
                controller.close()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.5))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            if !controller.title.isEmpty {
                Text(controller.title)
                    .heading(.subheadline)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 32)
                    .background(Color.black.opacity(0.5), in: Capsule())
                    // Not a control: touches pass to the tile underneath.
                    .allowsHitTesting(false)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: 8)
            if canSwitchLayout {
                Button {
                    onInteraction()
                    onSwitchLayout()
                } label: {
                    MultiviewChromeLabel(title: "Switch layout", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.plain)
                .fixedSize()
            }
            if !controller.channels.isEmpty {
                Button {
                    onInteraction()
                    onFeeds()
                } label: {
                    MultiviewChromeLabel(title: "Feeds", systemImage: "rectangle.grid.2x2")
                }
                .buttonStyle(.plain)
                .fixedSize()
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }
}

/// A control's look: white condensed text on a dark capsule, in a 44 pt high hit area.
struct MultiviewChromeLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.footnote.bold())
            .fontWidth(.condensed)
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .background(Color.black.opacity(0.5), in: Capsule())
            .frame(minHeight: 44)
            .contentShape(Rectangle())
    }
}

/// While the controls are hidden: a small "•••" at the top edge that brings them back. In the
/// top-leading corner, where no tile has a button of its own.
struct MultiviewControlsHandle: View {
    let onShow: @MainActor () -> Void

    var body: some View {
        Button {
            onShow()
        } label: {
            Image(systemName: "ellipsis")
                .font(.footnote.bold())
                .foregroundStyle(.white)
                .frame(width: 36, height: 22)
                .background(Color.black.opacity(0.5), in: Capsule())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 12)
        .accessibilityLabel("Show controls")
    }
}

// MARK: - Bottom panel

/// The scrubber over a row of play/pause, LIVE, speed and audio language.
struct MultiviewPlaybackBar: View {
    let controller: MultiviewController
    @Binding var scrubbing: Bool
    let onInteraction: @MainActor () -> Void

    var body: some View {
        // Nothing to control before the feeds have started, or with no feed at all.
        if controller.slots[0] != nil, !controller.isLoading {
            panel
                .frame(maxWidth: 640)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            if let range = controller.timeline, range.upperBound - range.lowerBound >= 1 {
                MultiviewScrubber(
                    controller: controller, range: range, scrubbing: $scrubbing, onInteraction: onInteraction)
            }
            HStack(spacing: 8) {
                playButton
                if controller.isLive {
                    liveButton
                }
                Spacer(minLength: 8)
                if !controller.isAtLiveEdge {
                    speedMenu
                }
                if controller.audioOptions.count > 1 {
                    audioMenu
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var playButton: some View {
        let paused = controller.isPaused
        return Button {
            if paused { controller.play() } else { controller.pause() }
            onInteraction()
        } label: {
            Image(systemName: paused ? "play.fill" : "pause.fill")
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(paused ? "Play" : "Pause")
    }

    /// Red when at the live point; behind it, an outlined LIVE that returns there.
    private var liveButton: some View {
        let atEdge = controller.isAtLiveEdge
        return Button {
            controller.goLive()
            onInteraction()
        } label: {
            liveLabel(atEdge: atEdge)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(atEdge ? "Live" : "Go live")
    }

    @ViewBuilder
    private func liveLabel(atEdge: Bool) -> some View {
        if atEdge {
            Text("LIVE").liveBadge()
        } else {
            Text("LIVE")
                .font(.caption)
                .bold()
                .fontWidth(.condensed)
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .overlay { Capsule().strokeBorder(Theme.accent, lineWidth: 1.5) }
        }
    }

    private var speedMenu: some View {
        let current = controller.rate
        return Menu {
            ForEach(SyncPolicy.speeds, id: \.self) { speed in
                Button {
                    controller.setRate(speed)
                    onInteraction()
                } label: {
                    if speed == current {
                        Label(MultiviewClock.speedText(speed), systemImage: "checkmark")
                    } else {
                        Text(MultiviewClock.speedText(speed))
                    }
                }
            }
        } label: {
            Text(MultiviewClock.speedText(current))
                .font(.footnote.bold())
                .fontWidth(.condensed)
                .monospacedDigit()
                .foregroundStyle(current == 1 ? Theme.textSecondary : Color.white)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .accessibilityLabel("Speed \(MultiviewClock.speedText(current))")
    }

    /// The feed with the sound's audio choices, under its name.
    private var audioMenu: some View {
        let options: [MultiviewAudioOption] = controller.audioOptions
        let selected: Int? = controller.selectedAudioOption
        let chosenName: String = options.first(where: { $0.id == selected })?.name ?? "Audio"
        let audible: Int? = controller.audioChannelId
        let feed: Channel? = controller.slots.compactMap({ $0 }).first(where: { $0.id == audible })
        let feedTitle: String = feed?.displayTitle ?? ""
        return Menu {
            Section(feedTitle.isEmpty ? "Audio" : "Sound from \(feedTitle)") {
                ForEach(options) { option in
                    Button {
                        controller.selectAudioOption(option.id)
                        onInteraction()
                    } label: {
                        if option.id == selected {
                            Label(option.name, systemImage: "checkmark")
                        } else {
                            Text(option.name)
                        }
                    }
                }
            }
        } label: {
            Label(chosenName, systemImage: "waveform")
                .font(.footnote.bold())
                .fontWidth(.condensed)
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(maxWidth: 160)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .accessibilityLabel("Audio language, \(chosenName)")
    }
}

/// One scrubber for every feed, on the main feed's timeline. Dragging previews the time; letting
/// go seeks every feed together, once (no seeking while the finger moves).
struct MultiviewScrubber: View {
    let controller: MultiviewController
    let range: ClosedRange<Double>
    @Binding var scrubbing: Bool
    let onInteraction: @MainActor () -> Void

    /// Where the finger is, while it drags.
    @State private var preview: Double?

    var body: some View {
        let lower = range.lowerBound
        let upper = range.upperBound
        let shown: Double = min(max(preview ?? controller.position, lower), upper)
        HStack(spacing: 8) {
            Text(MultiviewClock.text(shown - lower))
                .font(.caption)
                .fontWidth(.condensed)
                .monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
                .accessibilityHidden(true)
            Slider(
                value: Binding(get: { shown }, set: { preview = $0 }),
                in: range,
                onEditingChanged: { editing in editingChanged(editing) })
                .tint(Theme.accent)
                .accessibilityLabel("Position")
                .accessibilityValue(MultiviewClock.text(shown - lower))
            Text(trailingText(shown: shown))
                .font(.caption)
                .fontWidth(.condensed)
                .monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
                .accessibilityHidden(true)
        }
    }

    /// The time left in a replay; live, how far behind the live point (nothing when at it).
    private func trailingText(shown: Double) -> String {
        let left = max(range.upperBound - shown, 0)
        if controller.isLive, left <= MultiviewController.liveEdgeSlack { return "" }
        return "−" + MultiviewClock.text(left)
    }

    private func editingChanged(_ editing: Bool) {
        if editing {
            scrubbing = true
        } else {
            if let preview { controller.seek(toSeconds: preview) }
            preview = nil
            scrubbing = false
        }
        onInteraction()
    }
}

// MARK: - Notice

/// One line in the middle, as Android's status line: tap to dismiss; it also clears itself.
struct MultiviewNoticeView: View {
    let controller: MultiviewController

    var body: some View {
        ZStack {
            if let text = controller.notice {
                notice(text)
            }
        }
        .animation(.easeOut(duration: 0.2), value: controller.notice)
    }

    private func notice(_ text: String) -> some View {
        Button {
            controller.dismissNotice()
        } label: {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .frame(maxWidth: 420)
        }
        .buttonStyle(.plain)
        .padding(24)
        .transition(.opacity)
    }
}

// MARK: - Text

enum MultiviewClock {
    /// "m:ss", or "h:mm:ss" from an hour, as the Android app's clock.
    static func text(_ seconds: Double) -> String {
        let total = seconds.isFinite ? max(Int(seconds.rounded(.down)), 0) : 0
        let hours = total / 3_600
        let minutes = total / 60 % 60
        let secs = total % 60
        let twoDigits: (Int) -> String = { $0 < 10 ? "0\($0)" : "\($0)" }
        if hours > 0 { return "\(hours):\(twoDigits(minutes)):\(twoDigits(secs))" }
        return "\(minutes):\(twoDigits(secs))"
    }

    /// "1×", "0.75×", "2×".
    static func speedText(_ speed: Double) -> String {
        "\(speed.formatted())×"
    }
}
