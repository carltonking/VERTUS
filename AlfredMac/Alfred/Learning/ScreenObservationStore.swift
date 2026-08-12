import CryptoKit
import Foundation

/// Persistent, searchable screen memory — now a thin facade over
/// `UnifiedMemoryLayer`, which owns the `screen_observations` table.
///
/// Kept as a class (rather than deleting it) so `ScreenMonitoringManager` and
/// every existing caller stays unchanged: the insert/search/prune contract is
/// identical, but the rows now live in the unified database alongside the
/// graph, conversations and vault mirror. JPEGs still land under
/// `~/.alfred/screen_captures/YYYY-MM/[hash].jpg`; only the DB write is
/// delegated.
final class ScreenObservationStore {

    static let shared = ScreenObservationStore()

    private let captureRoot: String

    private init() {
        let home = NSHomeDirectory()
        captureRoot = home + "/.alfred/screen_captures"
        try? FileManager.default.createDirectory(
            atPath: home + "/.alfred/db", withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(
            atPath: captureRoot, withIntermediateDirectories: true)
    }

    // MARK: - Public API (delegates to UnifiedMemoryLayer)

    /// Persist one capture. Silently skips when these exact JPEG bytes were
    /// already stored (content_hash dedup — consecutive frames of a static
    /// screen are byte-identical, so this is the main storage lever).
    func insert(capturedAt: TimeInterval, appBundleID: String, jpegData: Data,
                ocrText: String, ocrConfidence: Double?, width: Int, height: Int) throws {
        let hash = Self.sha256Hex(of: jpegData)
        // Dedup before writing the JPEG — a repeated frame costs nothing on
        // disk then.
        guard !UnifiedMemoryLayer.shared.hasScreenObservation(contentHash: hash) else { return }

        let dir = captureRoot + "/" + Self.monthFormatter.string(from: Date(timeIntervalSince1970: capturedAt))
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/" + hash + ".jpg"
        try jpegData.write(to: URL(fileURLWithPath: path), options: .atomic)

        let inserted = UnifiedMemoryLayer.shared.insertScreenObservation(
            capturedAt: capturedAt, appBundleID: appBundleID, imagePath: path,
            ocrText: ocrText, confidence: ocrConfidence, width: width, height: height,
            contentHash: hash)
        if inserted < 0 {
            // A concurrent writer won the dedup race — drop the JPEG we wrote.
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    /// Full-text search over OCR text; with an empty query, the latest captures
    /// filtered by app/time. Never throws — a failed search returns [].
    func search(query: String, app: String? = nil, since: TimeInterval? = nil,
                until: TimeInterval? = nil, limit: Int = 20) -> [ScreenObservation] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Over-fetch before the in-memory filters below: the unified layer's
        // SQL applies LIMIT before app/since/until are folded in here, so a
        // tight limit could otherwise return fewer rows than actually match.
        let fetchLimit = max(limit, min(500, limit * 8))
        var results: [ScreenObservation]
        if trimmed.isEmpty {
            results = UnifiedMemoryLayer.shared.getScreenObservationsByApp(
                bundleID: app ?? "", since: since, limit: fetchLimit)
        } else {
            results = UnifiedMemoryLayer.shared.searchScreenByOCR(query: trimmed, limit: fetchLimit)
        }
        // The unified layer's queries cover one dimension at a time; fold the
        // remaining filters here to keep the old contract.
        if let app, !app.isEmpty { results = results.filter { $0.appBundleID == app } }
        if let since { results = results.filter { $0.capturedAt >= since } }
        if let until { results = results.filter { $0.capturedAt < until } }
        return Array(results.prefix(limit))
    }

    /// Delete observations older than `retentionDays` and their JPEGs on disk.
    func prune(retentionDays: TimeInterval = 7) throws {
        UnifiedMemoryLayer.shared.pruneScreenObservations(retentionDays: retentionDays)
    }

    /// "YYYY-MM" folder for a timestamp — one directory per month on disk.
    func dayFolder(from timestamp: TimeInterval) -> String {
        Self.monthFormatter.string(from: Date(timeIntervalSince1970: timestamp))
    }

    // MARK: - Helpers

    private static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
