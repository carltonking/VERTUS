//
//  RootView.swift
//  AlfredMacApp
//
//  The windowed surface's root: a monochrome side panel (SidebarView) on the
//  left rail, the six pages in a ZStack on the right. Each page keeps its own
//  view identity, so switching tabs doesn't reset a half-typed message or a
//  scroll position — hidden pages don't swallow taps and don't contribute
//  toolbar items to the shared window toolbar.
//
//  Deviation from iOS: the iOS RootView's `.task` blocks connect the phone to
//  the Mac (push registration, the live socket, the mail store). The menu-bar
//  Alfred app already owns those connections, so the root is pure
//  presentation — the socket/mail wiring belongs to the views the other
//  sessions drop in.
//

import SwiftUI

enum AlfredTab: String, CaseIterable, Identifiable, Hashable {
    case home, email, calendar, reminders, routines, sessions, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .email: return "Email"
        case .calendar: return "Calendar"
        case .reminders: return "Reminders"
        case .routines: return "Routines"
        case .sessions: return "Sessions"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .email: return "envelope.fill"
        case .calendar: return "calendar"
        case .reminders: return "checklist"
        case .routines: return "bolt.fill"
        case .sessions: return "briefcase.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

/// Whether this page is the currently selected tab. The windowed root keeps
/// every page alive in a ZStack (so tab switches doesn't reset a half-typed
/// message or a scroll position), and macOS merges the toolbar items of every
/// mounted NavigationStack into the one window toolbar — so without this, the
/// Calendar/Routines/Reminders "+" buttons would all appear on whatever tab
/// you're on. Pages read it and emit no toolbar items when inactive.
private struct TabActiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var isTabActive: Bool {
        get { self[TabActiveKey.self] }
        set { self[TabActiveKey.self] = newValue }
    }
}

/// Attaches a page's toolbar items only while that page is the selected tab.
/// Done as a modifier rather than an `if` inside the page's
/// `@ToolbarContentBuilder`: a toolbar builder that reads `@Environment` inside
/// a conditional can crash on macOS while the ZStack of pages is being built.
struct TabToolbar<Items: ToolbarContent>: ViewModifier {
    @Environment(\.isTabActive) private var isTabActive

    private let items: () -> Items

    init(@ToolbarContentBuilder items: @escaping () -> Items) {
        self.items = items
    }

    func body(content: Content) -> some View {
        if isTabActive {
            content.toolbar { items() }
        } else {
            content
        }
    }
}

public struct macOSRootView: View {
    @Environment(AppSettings.self) private var settings
    @State private var selection: AlfredTab = .home
    @State private var sidebarCollapsed: Bool = false

    public init() {}

    public var body: some View {
        HStack(spacing: 0) {
            // The collapse toggle, moved out of the sidebar rail and pinned to
            // the very top-left of the window, right under the traffic-light
            // controls. A slim 24pt strip keeps it a permanent handle beside
            // the rail without overlapping the first tab.
            VStack(alignment: .leading, spacing: 0) {
                SidebarCollapseButton(collapsed: $sidebarCollapsed)
                    .padding(.leading, 4)
                    .padding(.top, 8)
                Spacer(minLength: 0)
            }
            .frame(width: 24)
            .background(Palette.mono.sidebarBackground)

            // The side panel: the content tabs + the settings gear pinned to
            // the bottom-left. Sits on its own RGB(10, 10, 10) ground so it
            // reads as a distinct rail beside the page.
            SidebarView(selection: $selection, collapsed: $sidebarCollapsed)

            ZStack {
                // Each page keeps its own view identity, so switching tabs doesn't reset a half-typed
                // message or a scroll position the way rebuilding a single view would.
                page(.home) { HomeView(selection: $selection) }
                page(.email) { EmailView() }
                page(.calendar) { CalendarView() }
                page(.reminders) { RemindersView() }
                page(.routines) { RoutinesView() }
                page(.sessions) { SessionsView() }
                // Settings is reachable only through the gear at the bottom of
                // the side panel — it is deliberately not a sidebar row.
                page(.settings) { SettingsView() }
            }
        }
        .safeAreaInset(edge: .bottom) {
            // The statusbar stays under everything — including sessions — like
            // Hermes' statusbar: the live link to the Mac is always legible.
            StatusBarView()
        }
        .environment(\.palette, .mono)
        .tint(Palette.mono.accentBright)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func page<Content: View>(_ tab: AlfredTab, @ViewBuilder content: () -> Content) -> some View {
        content()
            .opacity(selection == tab ? 1 : 0)
            // Hidden pages must not swallow taps meant for the visible one.
            .allowsHitTesting(selection == tab)
            .accessibilityHidden(selection != tab)
            // Hidden pages must not contribute items to the shared window toolbar.
            .environment(\.isTabActive, selection == tab)
    }
}

/// The sidebar collapse toggle. A small arrow-only button that lives at the
/// window's top-left, under the traffic-light controls: chevron-left to
/// collapse, chevron-right to expand.
private struct SidebarCollapseButton: View {
    @Environment(\.palette) private var palette

    @Binding var collapsed: Bool

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) {
                collapsed.toggle()
            }
        } label: {
            Image(systemName: collapsed ? "chevron.right" : "chevron.left")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(palette.textFaint)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(collapsed ? "Expand sidebar" : "Collapse sidebar")
        .accessibilityLabel(collapsed ? "Expand sidebar" : "Collapse sidebar")
        .accessibilityIdentifier("sidebar.toggle")
    }
}
