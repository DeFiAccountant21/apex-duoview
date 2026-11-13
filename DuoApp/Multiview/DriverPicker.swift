import F1TV
import SwiftUI

/// A driver as the driver pickers show them: "#1 Norris", the team colour bar and the team, and
/// a check mark when chosen.
struct DriverRow: View {
    let channel: Channel
    var selected = false

    static func title(_ channel: Channel) -> String {
        guard let number = channel.racingNumber else { return channel.driverLastName }
        return "#\(number) \(channel.driverLastName)"
    }

    var body: some View {
        HStack(spacing: 12) {
            FeedRowLabel(channel: channel, title: Self.title(channel))
            Spacer()
            if selected {
                Image(systemName: "checkmark")
                    .foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : AccessibilityTraits())
    }
}

/// First run after signing in: the drivers of the latest race. A choice makes that driver's
/// onboard the second default feed (and resets the last-used feeds to the new default); "Skip"
/// leaves that spot as "Pick a feed". The root presents it and answers for it.
struct DriverPromptSheet: View {
    let drivers: [Channel]
    let onChoose: (String) -> Void
    let onSkip: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(drivers.enumerated()), id: \.offset) { _, driver in
                        Button {
                            onChoose(driver.driverLastName)
                        } label: {
                            DriverRow(channel: driver)
                        }
                    }
                } header: {
                    Text("Their onboard joins your multiview. You can change this any time in Settings › Multiview.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .textCase(nil)
                        .padding(.bottom, 4)
                }
                .listRowBackground(Theme.surface)
            }
            .scrollContentBackground(.hidden)
            .themedBackground()
            .navigationTitle("Pick your driver")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip", action: onSkip)
                }
            }
        }
    }
}

/// Settings › Multiview › My driver: "None" and the drivers of the latest race, loaded when the
/// page opens. Changing it changes only the driver: "Reset to default" in a multiview's Feeds
/// brings the new default in.
struct MyDriverList: View {
    let model: AppModel
    @State private var state: LoadState<[Channel]> = .loading
    @State private var attempt = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let favourite = model.favouriteDriver
        List {
            Section {
                Button {
                    choose(nil)
                } label: {
                    HStack {
                        Text("None").rowTitle()
                        Spacer()
                        if favourite == nil { checkmark }
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityAddTraits(favourite == nil ? .isSelected : AccessibilityTraits())
                // A driver chosen earlier who isn't in the latest race stays listed while chosen.
                if let favourite, let drivers = state.value, !drivers.contains(where: { Self.same($0, favourite) }) {
                    Button {
                        dismiss()
                    } label: {
                        HStack {
                            Text(favourite).rowTitle()
                            Spacer()
                            checkmark
                        }
                        .contentShape(Rectangle())
                    }
                    .accessibilityAddTraits(.isSelected)
                }
                switch state {
                case .loading:
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 60)
                case .loaded(let drivers):
                    if drivers.isEmpty {
                        Text("The latest race lists no onboard feeds.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    ForEach(Array(drivers.enumerated()), id: \.offset) { _, driver in
                        Button {
                            choose(driver.driverLastName)
                        } label: {
                            DriverRow(channel: driver, selected: favourite.map { Self.same(driver, $0) } ?? false)
                        }
                    }
                case .failed(let message):
                    LoadFailedView(message: message, retry: retry)
                }
            } footer: {
                Text("Your driver's onboard is the second of your default feeds. To see it in a multiview, use Reset to default in Feeds.")
            }
            .listRowBackground(Theme.surface)
        }
        .scrollContentBackground(.hidden)
        .themedBackground()
        .navigationTitle("My driver")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: attempt) { if !state.isLoaded { await load() } }
    }

    private var checkmark: some View {
        Image(systemName: "checkmark")
            .foregroundStyle(Theme.accent)
            .accessibilityHidden(true)
    }

    private static func same(_ driver: Channel, _ lastName: String) -> Bool {
        driver.driverLastName.compare(lastName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    private func retry() {
        state = .loading
        attempt += 1
    }

    private func load() async {
        let model = model
        guard let result = await LoadState.run(keeping: state, { try await model.driverChoices() }) else { return }
        state = result
    }

    private func choose(_ lastName: String?) {
        model.setFavouriteDriver(lastName)
        dismiss()
    }
}
