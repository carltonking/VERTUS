//
//  AlfredTabBar.swift
//  Alfred
//
//  A hand-rolled bottom bar, because SwiftUI's TabView shows at most five tabs on iPhone and folds
//  the rest into a "More" list — a limit on the number of tabs, not on how wide their labels are, so
//  dropping the titles wouldn't have bought a sixth slot.
//
//  The titles are gone visually only. Every button still carries its name as an accessibility label,
//  since VoiceOver reads names rather than SF Symbols, and an unlabelled icon row is unusable to it.
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
        .accessibilityLabel(tab.title)
        .accessibilityIdentifier("tab.\(tab.rawValue)")
        .accessibilityAddTraits(selection == tab ? [.isButton, .isSelected] : .isButton)
    }

    private func icon(for tab: AlfredTab) -> some View {
        let isSelected = selection == tab
        return Image(systemName: tab.icon)
            .font(.system(size: 19, weight: .medium))
            .foregroundStyle(isSelected ? palette.accentBright : palette.textFaint)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
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
                .frame(width: 46, height: 32)
        }
    }

    private var barBackground: some View {
        Capsule()
            .fill(.ultraThinMaterial)
            .overlay(Capsule().fill(palette.surface.opacity(0.5)))
            .overlay(Capsule().strokeBorder(palette.surfaceBorder, lineWidth: 1))
    }
}
