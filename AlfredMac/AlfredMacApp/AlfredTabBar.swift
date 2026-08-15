//
//  AlfredTabBar.swift
//  AlfredMacApp
//
//  The floating capsule bottom bar, ported from
//  Alfred/Alfred/Views/AlfredTabBar.swift — same visual language: ultraThin
//  material capsule, selection pill, unread badge on Email. Each button keeps
//  its name as an accessibility label, since VoiceOver reads names rather than
//  SF Symbols.
//

import SwiftUI

struct AlfredTabBar: View {
    @Environment(\.palette) private var palette

    @Binding var selection: AlfredTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AlfredTab.allCases) { tab in
                button(for: tab)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(barBackground)
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
        .animation(.snappy(duration: 0.22), value: selection)
    }

    // Kept as small pieces rather than one chained expression: the whole-bar version pushed the
    // type checker past its time limit.
    private func button(for tab: AlfredTab) -> some View {
        Button {
            selection = tab
        } label: {
            icon(for: tab)
        }
        .buttonStyle(.plain)
        .help(tab.title)
        .accessibilityLabel(tab.title)
        .accessibilityIdentifier("tab.\(tab.rawValue)")
        .accessibilityAddTraits(selection == tab ? [.isButton, .isSelected] : .isButton)
    }

    /// Desktop density, not iOS touch targets: 36pt buttons with 16pt icons,
    /// matching the compact rows of the Hermes desktop app. The hover highlight
    /// (a faint accent wash) is the macOS pointer's substitute for iOS's tap
    /// affordances.
    private func icon(for tab: AlfredTab) -> some View {
        let isSelected = selection == tab
        return Image(systemName: tab.icon)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(isSelected ? palette.accentBright : palette.textFaint)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(selectionPill(visible: isSelected))
            .overlay(alignment: .topTrailing) {
                badge(for: tab)
            }
            .contentShape(Rectangle())
    }

    /// The unread count on the Email tab, fed by the Mac's mail pushes. Nothing
    /// on the other tabs — the badge is a mail-only signal.
    @ViewBuilder
    private func badge(for tab: AlfredTab) -> some View {
        if tab == .email {
            let unread = MacMailStore.shared.totalUnread
            if unread > 0 {
                Text(unread > 99 ? "99+" : "\(unread)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(palette.backgroundTop)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(palette.accentBright))
                    .offset(x: 8, y: -2)
            }
        }
    }

    @ViewBuilder
    private func selectionPill(visible: Bool) -> some View {
        if visible {
            Capsule()
                .fill(palette.accent.opacity(0.16))
                .frame(width: 40, height: 28)
        }
    }

    /// Borderless elevation, per the Hermes system: the capsule floats on a
    /// soft downward shadow with a single hairline stroke — never a framed box.
    private var barBackground: some View {
        Capsule()
            .fill(.ultraThinMaterial)
            .overlay(Capsule().fill(palette.surface.opacity(0.5)))
            .overlay(Capsule().strokeBorder(palette.surfaceBorder, lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
    }
}
