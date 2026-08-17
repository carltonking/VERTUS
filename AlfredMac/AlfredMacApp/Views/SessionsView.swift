//
//  SessionsView.swift
//  AlfredMacApp
//
//  The Sessions tab: a completely blank page with the Alfred logo centered
//  as the background — scaled to 60% of the window size at 60% opacity.
//  The prompt bar stays anchored to the bottom of the window.
//

import SwiftUI

extension Foundation.Bundle {
    /// The resource bundle for Alfred's bundled assets (logos, Python scripts).
    /// AlfredMacApp is a library target with no resources of its own, so it reaches
    /// into the main Alfred executable's resource bundle (Alfred_Alfred.bundle).
    static let alfredResources: Bundle = {
        let mainPath = Bundle.main.bundleURL.appendingPathComponent("Alfred_Alfred.bundle").path
        // Build-time fallback path when running from a SwiftPM build dir.
        let buildPath = "/Users/carltonking/01 - PROJECTS/ALFRED/AlfredMac/.build/arm64-apple-macosx/release/Alfred_Alfred.bundle"
        let preferred = Bundle(path: mainPath) ?? Bundle(path: buildPath)
        guard let bundle = preferred else {
            fatalError("could not load Alfred_Alfred.bundle")
        }
        return bundle
    }()
}

struct SessionsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.palette) private var palette
    @State private var promptText = ""
    @State private var showingAddMenu = false
    @State private var showingModelMenu = false
    @State private var voiceOn = false
    @State private var readAloudOn = false
    @State private var wakeWordOn = false

    // MARK: - Sessions list

    @State private var sessionsExpanded = true
    @State private var expandedGroups: Set<String> = ["TODAY", "YESTERDAY", "EARLIER"]

    var body: some View {
        ZStack(alignment: .bottom) {
            // Solid dark background — RGB(25, 25, 25)
            Color(red: 25/255, green: 25/255, blue: 25/255)
                .ignoresSafeArea()

            // Alfred logo centered, 60% of the window, 60% opacity
            GeometryReader { geo in
                if let url = Bundle.alfredResources.url(forResource: "alfred-big-logo", withExtension: "png"),
                   let nsImage = NSImage(contentsOf: url) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geo.size.width * 0.6, height: geo.size.height * 0.6)
                        .opacity(0.60)
                        .allowsHitTesting(false)
                }
            }

            // Collapsible session list pinned to the top, above the logo.
            VStack(spacing: 0) {
                sessionsSection
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                Spacer(minLength: 0)
            }

            // Prompt bar pinned to the bottom of the window
            PromptBar(
                promptText: $promptText,
                showingAddMenu: $showingAddMenu,
                showingModelMenu: $showingModelMenu,
                voiceOn: $voiceOn,
                readAloudOn: $readAloudOn,
                wakeWordOn: $wakeWordOn
            )
        }
    }

    // MARK: - Sessions list

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    sessionsExpanded.toggle()
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: sessionsExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.textFaint)
                    Text("Sessions")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(palette.textPrimary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(sessionsExpanded ? "Collapse sessions" : "Expand sessions")
            .accessibilityIdentifier("sessions.section")

            if sessionsExpanded {
                ForEach(SampleSessionGroup.allGroups, id: \.name) { group in
                    sessionGroup(group)
                }
            }
        }
    }

    private func sessionGroup(_ group: SampleSessionGroup) -> some View {
        let expanded = expandedGroups.contains(group.name)
        return VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    if expanded {
                        expandedGroups.remove(group.name)
                    } else {
                        expandedGroups.insert(group.name)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(palette.textFaint)
                    Text(group.name)
                        .font(.system(size: 11, weight: .semibold))
                        .kerning(1)
                        .foregroundStyle(palette.textFaint)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(group.name)

            if expanded {
                ForEach(group.sessions) { session in
                    HStack(spacing: 8) {
                        Text(session.title)
                            .font(.system(size: 13))
                            .foregroundStyle(palette.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(session.timestamp)
                            .font(.system(size: 11))
                            .foregroundStyle(palette.textFaint)
                    }
                    .padding(.vertical, 3)
                    .padding(.leading, 14)
                }
            }
        }
    }
}

/// Hardcoded sample sessions while a real Sessions store doesn't exist yet.
private struct SampleSession: Identifiable {
    let title: String
    let timestamp: String
    var id: String { title }
}

private struct SampleSessionGroup {
    let name: String
    let sessions: [SampleSession]

    static let allGroups: [SampleSessionGroup] = [
        SampleSessionGroup(name: "TODAY", sessions: [
            SampleSession(title: "AlfredBar integration mockup", timestamp: "9:41 AM"),
            SampleSession(title: "Daily Work Task and Schedule", timestamp: "11:20 AM"),
        ]),
        SampleSessionGroup(name: "YESTERDAY", sessions: [
            SampleSession(title: "Unread Email Alert #2", timestamp: "8:15 PM"),
            SampleSession(title: "Ready for a night of tasks", timestamp: "3:30 PM"),
        ]),
        SampleSessionGroup(name: "EARLIER", sessions: [
            SampleSession(title: "Time for Retail Therapy", timestamp: "Jul 19"),
            SampleSession(title: "Building Hermes-Style interface", timestamp: "Jul 17"),
        ]),
    ]
}
