//
//  PromptBar.swift
//  AlfredMacApp
//
//  The sessions tab's prompt bar: a gray opaque rectangle anchored to the
//  bottom of the window. All on one line when empty — plus, inline text field,
//  then model / mic / sound / ear / send on the right. When the user starts
//  typing, the bar grows upward into a scrollable text area while the icon row
//  stays pinned to the bottom.
//
//  Bottom row, left → right:
//    plus icon       → opens Add menu (File / Folder / Image)
//    [inline field]  → only while collapsed
//    model name      → opens Model menu with an effort dropdown per model
//    mic icon        → toggle voice dictation
//    sound icon      → toggle read replies aloud
//    ear icon        → toggle wake word ("hey alfred")
//    send icon       → white circle + black upward arrow
//

import SwiftUI
import AppKit

// MARK: - Effort levels for each model

enum EffortLevel: String, CaseIterable, Identifiable {
    case low    = "Low"
    case medium = "Medium"
    case high   = "High"

    var id: String { rawValue }

    var displayName: String { rawValue }
}

// MARK: - Prompt bar

struct PromptBar: View {
    @Environment(\.palette) private var palette

    @Binding var promptText: String
    @Binding var showingAddMenu: Bool
    @Binding var showingModelMenu: Bool
    @Binding var voiceOn: Bool
    @Binding var readAloudOn: Bool
    @Binding var wakeWordOn: Bool

    @State private var selectedModel: NousModel = AlfredModelConfig.load().selectedModel
    @State private var modelEfforts: [NousModel: EffortLevel] = [
        .solarPro4FreeMax: .medium,
        .longcat2FreeMax: .medium,
        .hy3FreeMax: .medium,
        .lagunaS21FreeMax: .medium,
        .step37FlashFreeMax: .medium,
        .lagunaXs21FreeMax: .medium,
    ]

    @FocusState private var promptFocused: Bool

    /// False while the field is empty or a single line; true once the text
    /// grows to 2+ lines (a newline was typed or it wrapped past ~80 chars),
    /// which expands the text area above the icon row.
    private var isExpanded: Bool {
        let lineCount = promptText.components(separatedBy: .newlines).count
        return lineCount > 1 || promptText.count > 80
    }

    var body: some View {
        VStack(spacing: 0) {
            // Expanded text area — only visible once the user starts typing.
            // Icons stay at the bottom; the typing area moves above them.
            if isExpanded {
                textArea
            }

            iconRow
        }
        .background(palette.surface)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(palette.hairline)
                .frame(height: 1)
        }
        .frame(maxWidth: .infinity)
        .animation(.snappy(duration: 0.2), value: isExpanded)
    }

    // MARK: - Expanded text area

    /// The scrollable typing area shown once the user starts typing. The bar
    /// grows upward from the bottom; the icons stay in the row below.
    private var textArea: some View {
        ScrollView {
            TextField("Ask Alfred…", text: $promptText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...10)
                .font(.system(size: 16))
                .foregroundStyle(palette.textPrimary)
                .tint(palette.accentBright)
                .focused($promptFocused)
                .padding(10)
        }
        .frame(maxHeight: 260)
    }

    // MARK: - Icon row

    private var iconRow: some View {
        HStack(spacing: 4) {
            // Plus icon → Add menu
            addButton

            // The single-line field lives inline in the row while collapsed;
            // once typing starts it moves up into the expanded text area.
            if !isExpanded {
                TextField("Ask Alfred…", text: $promptText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1)
                    .font(.system(size: 15))
                    .foregroundStyle(palette.textPrimary)
                    .tint(palette.accentBright)
                    .focused($promptFocused)
            }

            Spacer(minLength: 6)

            // Model selector — shows the selected model (and its effort)
            modelButton

            // Mic — voice dictation
            toggleButton(
                icon: "mic.fill",
                active: voiceOn,
                action: { voiceOn.toggle() },
                tooltip: "Voice dictation"
            )

            // Sound — read replies aloud
            toggleButton(
                icon: "speaker.wave.2.fill",
                active: readAloudOn,
                action: { readAloudOn.toggle() },
                tooltip: "Read replies aloud"
            )

            // Ear — wake word
            toggleButton(
                icon: "ear.fill",
                active: wakeWordOn,
                action: { wakeWordOn.toggle() },
                tooltip: "Wake word (hey alfred)"
            )

            // Send — white circle + black up arrow
            sendButton
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .onChange(of: isExpanded) { _, expanded in
            // Keep the keyboard in the typing field when the inline row
            // collapses into the expanded area (and back).
            promptFocused = expanded
        }
    }

    // MARK: - Add button

    private var addButton: some View {
        Button {
            showingAddMenu = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(palette.textSecondary)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .help("Add file, folder, or image")
        .accessibilityLabel("Add")
        .popover(isPresented: $showingAddMenu, arrowEdge: .bottom) {
            AddMenuContent(isPresented: $showingAddMenu)
        }
    }

    // MARK: - Model button

    private var modelButton: some View {
        Button {
            showingModelMenu = true
        } label: {
            HStack(spacing: 4) {
                Text(selectedModel.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)

                Text(modelEfforts[selectedModel]?.displayName ?? "Medium")
                    .font(.system(size: 10))
                    .foregroundStyle(palette.textFaint)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(minWidth: 100, maxWidth: 170, alignment: .leading)
        }
        .buttonStyle(.plain)
        .help("Select model and effort")
        .accessibilityLabel("Model: \(selectedModel.displayName)")
        .popover(isPresented: $showingModelMenu, arrowEdge: .bottom) {
            ModelMenuContent(
                selectedModel: selectedModel,
                modelEfforts: modelEfforts,
                onSelectModel: { model in
                    selectedModel = model
                    // Persist the choice so the menu-bar app's next config
                    // write picks it up.
                    AlfredModelConfig(selectedModel: model).save()
                },
                onUpdateEffort: { model, level in
                    modelEfforts[model] = level
                }
            )
        }
    }

    // MARK: - Toggle button helper

    private func toggleButton(
        icon: String,
        active: Bool,
        action: @escaping () -> Void,
        tooltip: String
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(active ? palette.accentBright : palette.textSecondary)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .accessibilityLabel(tooltip)
    }

    // MARK: - Send button

    private var sendButton: some View {
        Button {
            // Send the prompt — the wiring to a live session lands separately;
            // for now this submits and clears the bar.
            let _ = promptText
            promptText = ""
        } label: {
            ZStack {
                Circle()
                    .fill(Color.white)
                    .frame(width: 32, height: 32)

                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.black)
            }
        }
        .buttonStyle(.plain)
        .disabled(promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .help("Send")
        .accessibilityLabel("Send")
    }
}

// MARK: - Add menu content

struct AddMenuContent: View {
    @Environment(\.palette) private var palette
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            menuItem("File", icon: "doc.fill") { isPresented = false }
            menuItem("Folder", icon: "folder.fill") { isPresented = false }
            menuItem("Image", icon: "photo.fill") { isPresented = false }
        }
        .background(palette.backgroundTop)
        .frame(width: 160)
    }

    private func menuItem(_ label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.accentBright)
                    .frame(width: 18)

                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(palette.textPrimary)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Model menu content

struct ModelMenuContent: View {
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss

    let selectedModel: NousModel
    let modelEfforts: [NousModel: EffortLevel]
    let onSelectModel: (NousModel) -> Void
    let onUpdateEffort: (NousModel, EffortLevel) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(NousModel.allCases) { model in
                modelRow(for: model)
                if model != NousModel.allCases.last {
                    Divider()
                        .background(palette.hairline)
                        .padding(.horizontal, 12)
                }
            }
        }
        .background(palette.backgroundTop)
        .frame(width: 280)
    }

    private func modelRow(for model: NousModel) -> some View {
        HStack(spacing: 0) {
            // Model name + select
            Button {
                onSelectModel(model)
                dismiss()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 6))
                        .foregroundStyle(model == selectedModel ? palette.accentBright : palette.textFaint)
                        .frame(width: 8)

                    Text(model.displayName)
                        .font(.system(size: 13))
                        .foregroundStyle(palette.textPrimary)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)

            // Effort dropdown — tap the effort label next to the model name
            // to step through Low → Medium → High.
            Button {
                let current = modelEfforts[model] ?? .medium
                let next: EffortLevel = current == .low ? .medium
                    : current == .medium ? .high : .low
                onUpdateEffort(model, next)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8))
                        .foregroundStyle(palette.textFaint)

                    Text(modelEfforts[model]?.displayName ?? "Medium")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.textSecondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(palette.surface.opacity(0.5))
                .frame(width: 80, alignment: .trailing)
            }
            .buttonStyle(.plain)
            .help("Tap to change effort level")
        }
    }
}
