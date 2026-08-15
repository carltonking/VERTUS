//
//  RootView.swift
//  AlfredMacApp
//
//  The windowed companion's root: the same tab layout as the iOS app.
//  Ported from Alfred/Alfred/Views/RootView.swift — same AlfredTab enum, same
//  page-switching pattern (each page keeps its own view identity, hidden pages
//  don't swallow taps), same floating tab bar via safeAreaInset.
//
//  Deviation from iOS: the iOS RootView's `.task` blocks connect the phone to
//  the Mac (push registration, the live socket, the mail store). The menu-bar
//  Alfred app already owns those connections, so the companion's root is pure
//  presentation — the socket/mail wiring belongs to the views the other
//  sessions drop in.
//

import SwiftUI

enum AlfredTab: String, CaseIterable, Identifiable, Hashable {
    case home, chat, email, calendar, reminders, routines, code, courses, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .chat: return "Chat"
        case .email: return "Email"
        case .calendar: return "Calendar"
        case .reminders: return "Reminders"
        case .routines: return "Routines"
        case .code: return "Code"
        case .courses: return "Courses"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .chat: return "bubble.left.and.bubble.right.fill"
        case .email: return "envelope.fill"
        case .calendar: return "calendar"
        case .reminders: return "checklist"
        case .routines: return "bolt.fill"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .courses: return "graduationcap.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

/// Whether this page is the currently selected tab. The windowed root keeps
/// every page alive in a ZStack (so tab switches don't reset a half-typed
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

struct macOSRootView: View {
    @Environment(AppSettings.self) private var settings
    @State private var selection: AlfredTab = .home

    var body: some View {
        ZStack {
            // Each page keeps its own view identity, so switching tabs doesn't reset a half-typed
            // message or a scroll position the way rebuilding a single view would.
            page(.home) { HomeView(selection: $selection) }
            page(.chat) { ChatView(goBackHome: { selection = .home }) }
            page(.email) { EmailView() }
            page(.calendar) { CalendarView() }
            page(.reminders) { RemindersView() }
            page(.routines) { RoutinesView() }
            page(.code) { CodeView() }
            page(.courses) { NYUView() }
            page(.settings) { SettingsView() }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                // Chat owns the whole screen while it's open: the composer sits
                // over the inset every other tab gives the bar, so the bar would
                // bury it. Full-screen chat, navigable back to Home via its
                // leading button.
                if selection != .chat {
                    AlfredTabBar(selection: $selection)
                }

                // The statusbar stays under everything — including chat — like
                // Hermes' statusbar: the live link to the Mac is always legible.
                StatusBarView()
            }
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
