//
//  SidebarView.swift
//  AlfredMacApp
//
//  The window's side panel: six flat monochrome tabs (Home, Sessions, Email,
//  Calendar, Reminders, Routines) plus a gear icon pinned to the bottom-left.
//  Selection is a neutral gray wash — no accent colour — and the rail sits on
//  its own RGB(10, 10, 10) ground so it reads as a distinct column beside the
//  page.
//
//  Collapsible: when collapsed, only the icons are visible (no labels), and the
//  rail is narrower. The collapse toggle lives in RootView, pinned to the very
//  top-left of the window under the traffic-light controls.
//

import SwiftUI

struct SidebarView: View {
    @Environment(\.palette) private var palette

    @Binding var selection: AlfredTab
    @Binding var collapsed: Bool

    // MARK: - Content tabs

    /// The six tabs that appear in the sidebar before the gear icon. Sessions
    /// (which replaced Chat) sits at the bottom of the list.
    private var contentTabs: [AlfredTab] {
        [.home, .email, .calendar, .reminders, .routines, .sessions]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Six content tabs
            ForEach(contentTabs, id: \.self) { tab in
                row(for: tab)
            }

            Spacer(minLength: 0)

            // Gear icon only, bottom-left, no label
            Button {
                selection = .settings
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(palette.textFaint)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Settings")
            .accessibilityLabel("Settings")
            .accessibilityIdentifier("sidebar.settings")
            .padding(.bottom, 8)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, collapsed ? 4 : 8)
        .frame(width: collapsed ? 48 : 190)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(palette.sidebarBackground)
        .animation(.snappy(duration: 0.2), value: collapsed)
    }

    private func row(for tab: AlfredTab) -> some View {
        let selected = selection == tab
        return Button {
            selection = tab
        } label: {
            HStack(spacing: 10) {
                Image(systemName: tab.icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selected ? palette.textPrimary : palette.textFaint)
                    .frame(width: collapsed ? 32 : 18)

                if !collapsed {
                    Text(tab.title)
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? palette.textPrimary : palette.textSecondary)

                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, collapsed ? 0 : 10)
            .padding(.vertical, 6)
            .frame(width: collapsed ? 40 : nil)
            .background(selected ? palette.accent.opacity(0.16) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tab.title)
        .accessibilityLabel(tab.title)
        .accessibilityIdentifier("sidebar.\(tab.rawValue)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
