import SwiftUI

/// The "Profile" tab in the menu-bar popover: the user-facing surface for the Hermes learning
/// system. Shows what Alfred has learned (local profile), the capture toggles (screen text +
/// meeting recording), and natural-language search over captured local data.
struct HermesDashboardView: View {
    let store: MemoryStore
    var screenTextMonitor: ScreenTextMonitor?
    var meetingManager: MeetingCaptureManager?
    var ownerName: String
    var onScreenTextToggle: (Bool) -> Void

    @State private var profileText = ""
    @State private var regenerating = false
    @State private var query = ""
    @State private var screenResults: [ScreenTextRecord] = []
    @State private var meetings: [MeetingRecord] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                profileSection
                Divider()
                if let screenTextMonitor {
                    ScreenCaptureToggle(monitor: screenTextMonitor, onToggle: onScreenTextToggle)
                }
                Divider()
                if let meetingManager {
                    MeetingRecorder(manager: meetingManager) { reloadMeetings() }
                }
                Divider()
                searchSection
            }
            .padding(12)
        }
        .onAppear {
            profileText = ProfileDigest.whatDoYouKnow()
            reloadMeetings()
        }
    }

    // MARK: - Profile

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("What Alfred knows about you", systemImage: "person.text.rectangle")
                    .font(.subheadline.bold())
                Spacer()
                Button { regenerate() } label: {
                    if regenerating { ProgressView().controlSize(.mini).scaleEffect(0.6) }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .buttonStyle(.plain).help("Rebuild profile on-device (Ollama)").disabled(regenerating)
            }
            Text(profileText.isEmpty ? "No profile yet." : profileText)
                .font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func regenerate() {
        // Only build a profile from real captured data — never fabricate from nothing.
        let screenCount = store.recentScreenText(limit: ProfileDigest.minScreenTextRecords + 1).count
        let meetingCount = store.recentMeetings(limit: 1).count
        guard ProfileDigest.hasEnoughData(screenTextCount: screenCount, meetingCount: meetingCount) else {
            profileText = ProfileDigest.notEnoughDataMessage
            return
        }
        regenerating = true
        let owner = ownerName
        let signals = gatherSignals()
        Task {
            await ProfileDigest.regenerate(ownerName: owner, signals: signals,
                                           screenTextCount: screenCount, meetingCount: meetingCount)
            await MainActor.run {
                profileText = ProfileDigest.whatDoYouKnow()
                regenerating = false
            }
        }
    }

    private func gatherSignals() -> [String] {
        var signals: [String] = []
        let recent = store.recentScreenText(limit: 40)
        if !recent.isEmpty {
            let apps = Array(Set(recent.map(\.app_name))).prefix(8)
            signals.append("Apps used recently: \(apps.joined(separator: ", "))")
            let titles = recent.compactMap { $0.window_title.isEmpty ? nil : $0.window_title }.prefix(8)
            if !titles.isEmpty { signals.append("Recent window titles: \(titles.joined(separator: " | "))") }
            for s in recent.prefix(3) { signals.append("Screen excerpt: \(String(s.text.prefix(300)))") }
        }
        for m in store.recentMeetings(limit: 3) where (m.summary?.isEmpty == false) {
            signals.append("Meeting summary: \(m.summary!)")
        }
        return signals
    }

    // MARK: - Search + recent meetings

    private var searchSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Search what you've seen & heard", systemImage: "magnifyingglass")
                .font(.subheadline.bold())
            HStack {
                TextField("Search captured screen text…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { runSearch() }
                Button("Search") { runSearch() }.controlSize(.small)
            }
            ForEach(screenResults, id: \.id) { r in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(r.app_name).font(.caption2.bold())
                        Text(Self.time(r.timestamp)).font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(r.text).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            }

            if !meetings.isEmpty {
                Label("Recent meetings", systemImage: "waveform").font(.subheadline.bold()).padding(.top, 4)
                ForEach(meetings, id: \.id) { m in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.title).font(.caption.bold())
                        Text(m.summary ?? String(m.transcript.prefix(160)))
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(4)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        screenResults = q.isEmpty ? [] : store.searchScreenText(q, limit: 20)
    }

    private func reloadMeetings() { meetings = store.recentMeetings(limit: 10) }

    // Cached instead of allocating per row in ForEach(screenResults).
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d, h:mm a"; return f
    }()

    private static func time(_ epoch: Double) -> String {
        Self.timeFormatter.string(from: Date(timeIntervalSince1970: epoch))
    }
}

// MARK: - Screen text capture toggle

private struct ScreenCaptureToggle: View {
    @ObservedObject var monitor: ScreenTextMonitor
    var onToggle: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(get: { monitor.isActive }, set: { onToggle($0) })) {
                Label("Capture screen text (on-device)", systemImage: "text.viewfinder")
                    .font(.subheadline.bold())
            }
            .toggleStyle(.switch).controlSize(.mini)
            Text(monitor.status).font(.caption2).foregroundStyle(.secondary)
            if monitor.captureCount > 0 {
                Text("\(monitor.captureCount) captures this session").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Meeting recorder

private struct MeetingRecorder: View {
    @ObservedObject var manager: MeetingCaptureManager
    var onSaved: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Meeting capture", systemImage: "waveform.badge.mic").font(.subheadline.bold())
                Spacer()
                Button {
                    Task {
                        let wasRecording = manager.isRecording
                        await manager.toggle()
                        if wasRecording { onSaved() }
                    }
                } label: {
                    Label(manager.isRecording ? "Stop" : "Record",
                          systemImage: manager.isRecording ? "stop.circle.fill" : "record.circle")
                        .foregroundStyle(manager.isRecording ? Color.red : Color.accentColor)
                }
                .buttonStyle(.plain)
            }
            Text(manager.status).font(.caption2).foregroundStyle(.secondary)
            if manager.isRecording && !manager.liveTranscript.isEmpty {
                Text(manager.liveTranscript)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}
