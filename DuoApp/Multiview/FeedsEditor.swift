import F1TV
import Multiview
import SwiftUI

/// A page inside the feeds editor's navigation.
enum FeedsEditorPage: Hashable {
    /// Choosing the feed for one slot.
    case slot(Int)
    case saveAsPreset
    case renamePreset(UUID)
}

/// The feeds editor, a sheet over the multiview: the four slots by position ("Main", 2, 3, 4),
/// tap one to choose its feed from the session's feeds or "Empty"; "Clear all", "Reset to
/// default", "Make these my default", "Save as preset"; and the presets.
/// Every change goes through the controller's slot machinery, so it never sends a PLAY.
struct FeedsEditor: View {
    let controller: MultiviewController
    @State private var path: [FeedsEditorPage]
    /// "Make these my default" was tapped and the feeds haven't changed since.
    @State private var madeDefault = false
    @Environment(\.dismiss) private var dismiss

    /// `startSlot` opens straight on that slot's feed list (a "Pick a feed" tile was tapped).
    init(controller: MultiviewController, startSlot: Int?) {
        self.controller = controller
        _path = State(initialValue: startSlot.map { [FeedsEditorPage.slot($0)] } ?? [])
    }

    /// Slots are named by position: the biggest spot, then 2, 3 and 4.
    static func slotName(_ slot: Int) -> String {
        slot == 0 ? "Main" : "\(slot + 1)"
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                slotsSection.listRowBackground(Theme.surface)
                actionsSection.listRowBackground(Theme.surface)
                PresetsSection(controller: controller) { id in
                    path.append(.renamePreset(id))
                }
                .listRowBackground(Theme.surface)
            }
            .scrollContentBackground(.hidden)
            .themedBackground()
            .navigationTitle("Feeds")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: FeedsEditorPage.self) { page in
                switch page {
                case .slot(let slot):
                    FeedChoiceList(controller: controller, slot: slot)
                case .saveAsPreset:
                    PresetNameView(controller: controller, presetID: nil)
                case .renamePreset(let id):
                    PresetNameView(controller: controller, presetID: id)
                }
            }
        }
        .onChange(of: controller.slots) { _, _ in madeDefault = false }
    }

    private var slotsSection: some View {
        Section {
            ForEach(0..<MultiviewController.slotCount, id: \.self) { slot in
                NavigationLink(value: FeedsEditorPage.slot(slot)) {
                    HStack(spacing: 12) {
                        Text(Self.slotName(slot))
                            .font(.subheadline.bold())
                            .fontWidth(.condensed)
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 44, alignment: .leading)
                        if let channel = controller.slots[slot] {
                            FeedRowLabel(channel: channel)
                        } else {
                            Text("Pick a feed")
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }
        } header: {
            Text("Feeds").sectionLabel()
        }
    }

    private var actionsSection: some View {
        Section {
            Button("Clear all", role: .destructive) { controller.clearAll() }
            Button("Reset to default") { controller.resetToDefault() }
            Button("Make these my default") {
                controller.makeCurrentFeedsDefault()
                madeDefault = true
            }
            Button("Save as preset") { path.append(.saveAsPreset) }
        } footer: {
            if madeDefault {
                Text("These are now your default feeds.")
            }
        }
    }
}

// MARK: - One slot's feed

/// The session's feeds for one slot, plus "Empty". A feed that is in another slot trades places
/// with this slot's feed. Goes back to the editor after a choice.
struct FeedChoiceList: View {
    let controller: MultiviewController
    let slot: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let current = controller.slots.indices.contains(slot) ? controller.slots[slot]?.id : nil
        // As the session's feed list orders them: the default feed first, then F1 TV's order.
        let ordered = controller.channels.filter(\.isDefault) + controller.channels.filter { !$0.isDefault }
        List {
            Section {
                Button {
                    choose(nil)
                } label: {
                    HStack {
                        Text("Empty").rowTitle()
                        Spacer()
                        if current == nil { checkmark }
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityAddTraits(current == nil ? .isSelected : AccessibilityTraits())
            }
            .listRowBackground(Theme.surface)
            Section {
                ForEach(Array(ordered.enumerated()), id: \.offset) { _, channel in
                    let selected = channel.id != nil && channel.id == current
                    Button {
                        choose(channel)
                    } label: {
                        HStack(spacing: 12) {
                            FeedRowLabel(channel: channel)
                            Spacer()
                            if !selected, let other = otherSlot(of: channel) {
                                Text("In \(FeedsEditor.slotName(other))")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            if selected { checkmark }
                        }
                        .contentShape(Rectangle())
                    }
                    .accessibilityAddTraits(selected ? .isSelected : AccessibilityTraits())
                }
            } header: {
                Text("This session's feeds").sectionLabel()
            }
            .listRowBackground(Theme.surface)
        }
        .scrollContentBackground(.hidden)
        .themedBackground()
        .navigationTitle(FeedsEditor.slotName(slot))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var checkmark: some View {
        Image(systemName: "checkmark")
            .foregroundStyle(Theme.accent)
            .accessibilityHidden(true)
    }

    private func otherSlot(of channel: Channel) -> Int? {
        guard let id = channel.id else { return nil }
        return controller.slots.firstIndex { $0?.id == id }
    }

    private func choose(_ channel: Channel?) {
        controller.setFeed(channel, at: slot)
        dismiss()
    }
}

// MARK: - Preset name

/// Names a new preset from the current feeds, or renames one. A refused name stays on the page
/// with the reason under the field.
struct PresetNameView: View {
    let controller: MultiviewController
    /// nil: save the current feeds as a new preset.
    let presetID: UUID?
    @State private var name: String
    @State private var problem: String?
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    init(controller: MultiviewController, presetID: UUID?) {
        self.controller = controller
        self.presetID = presetID
        let existing = presetID.flatMap { id in controller.presets.first { $0.id == id }?.name }
        _name = State(initialValue: existing ?? "")
        // A ninth preset can't be saved: say so straight away rather than after typing a name.
        let full = presetID == nil && controller.presets.count >= MultiviewStore.maxPresets
        _problem = State(initialValue: full ? PresetsSection.message(for: .full) : nil)
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit(save)
            } footer: {
                if let problem {
                    Text(problem).foregroundStyle(Theme.textPrimary)
                }
            }
            .listRowBackground(Theme.surface)
        }
        .scrollContentBackground(.hidden)
        .themedBackground()
        .navigationTitle(presetID == nil ? "Save as preset" : "Rename preset")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
            }
        }
        .onAppear { focused = true }
    }

    private func save() {
        do {
            if let presetID {
                try controller.renamePreset(id: presetID, to: name)
            } else {
                try controller.saveAsPreset(name: name)
            }
            dismiss()
        } catch let error as PresetError {
            problem = PresetsSection.message(for: error)
        } catch {
            problem = error.localizedDescription
        }
    }
}

// MARK: - Feed row

/// A feed as the session's feed list shows it (beta.1's `DetailView`): for an onboard, a bar in
/// the team colour, the name and the team under it; for any other feed, its name.
struct FeedRowLabel: View {
    let channel: Channel
    /// Instead of `displayTitle` (the driver pickers show "#1 Norris").
    var title: String?

    var body: some View {
        HStack(spacing: 12) {
            if channel.isOnboard {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(hex: channel.teamColorHex) ?? .gray)
                    .frame(width: 5, height: 32)
            } else {
                Color.clear.frame(width: 5, height: 32)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title ?? channel.displayTitle).rowTitle()
                if channel.isOnboard && !channel.teamName.isEmpty {
                    Text(channel.teamName)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
