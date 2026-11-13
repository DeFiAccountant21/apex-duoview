import Multiview
import SwiftUI

/// The feeds editor's presets: tap one to load its feeds and layouts; its menu renames it,
/// updates it with the current feeds, or deletes it (a swipe deletes too). Up to 8.
struct PresetsSection: View {
    let controller: MultiviewController
    /// Opens the rename page for a preset.
    let onRename: (UUID) -> Void
    @State private var problem: String?

    /// Plain words for a refused preset change.
    static func message(for error: PresetError) -> String {
        switch error {
        case .emptyName:
            return "Give the preset a name."
        case .nameTooLong:
            return "Names can be up to 30 characters."
        case .duplicateName:
            return "You already have a preset with that name."
        case .full:
            return "You can save up to 8 presets."
        case .notFound:
            return "That preset isn't there any more."
        }
    }

    var body: some View {
        Section {
            if controller.presets.isEmpty {
                Text("No presets yet.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
            ForEach(controller.presets) { preset in
                row(preset)
            }
        } header: {
            Text("Presets").sectionLabel()
        } footer: {
            if let problem {
                Text(problem).foregroundStyle(Theme.textPrimary)
            } else {
                Text("A preset keeps its feeds and the layouts you chose. Up to 8.")
            }
        }
    }

    private func row(_ preset: Preset) -> some View {
        HStack(spacing: 8) {
            Button {
                problem = nil
                controller.apply(preset)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.name).rowTitle()
                    Text(Self.summary(preset.picks))
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityHint("Loads these feeds")
            Menu {
                Button("Rename") { onRename(preset.id) }
                Button("Update with these feeds") { update(preset) }
                Button("Delete", role: .destructive) { delete(preset) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .accessibilityLabel("Options for \(preset.name)")
        }
        .swipeActions {
            Button("Delete", role: .destructive) { delete(preset) }
        }
    }

    private func update(_ preset: Preset) {
        do {
            try controller.updatePreset(id: preset.id)
            problem = nil
        } catch let error as PresetError {
            problem = Self.message(for: error)
        } catch {
            problem = error.localizedDescription
        }
    }

    private func delete(_ preset: Preset) {
        problem = nil
        controller.deletePreset(id: preset.id)
    }

    /// "International · Norris · Tracker · Data"; an empty spot reads "Empty".
    static func summary(_ picks: [FeedPick?]) -> String {
        picks.prefix(MultiviewController.slotCount).map { pick in
            guard let pick else { return "Empty" }
            switch pick {
            case .worldFeed: return "International"
            case .f1Live: return "F1 Live"
            case .tracker: return "Tracker"
            case .data: return "Data"
            case .onboard(let lastName): return lastName
            case .other(let title): return title
            }
        }
        .joined(separator: " · ")
    }
}
