import Foundation
import SQLite3

// SQLITE_TRANSIENT is a C macro, invisible to Swift; -1 tells SQLite to copy the
// bound string before the statement is finalized.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Models

/// Which mail world an account belongs to. Drives the badge the phone shows on
/// each row and the colour of the account filter chip.
enum EmailProvider: String, Codable, CaseIterable, Sendable {
    case iCloud, google, nyu, other

    /// Inferred from the address: the big three get named, everything else is
    /// "other" — the distinction that matters on a phone is glanceability, and
    /// an address like someone@fastmail.com reads fine as "Other".
    static func infer(from email: String) -> EmailProvider {
        let lower = email.lowercased()
        if lower.contains("@icloud.com") || lower.contains("@me.com")
            || lower.contains("@mac.com") { return .iCloud }
        if lower.contains("@gmail.com") || lower.contains("@googlemail.com") { return .google }
        if lower.contains("@nyu.edu") || lower.contains("@stern.nyu.edu")
            || lower.contains("@cims.nyu.edu") { return .nyu }
        return .other
    }
}

/// One configured mail account — in practice one `[accounts.X]` section of the
/// Himalaya config. The id is the Himalaya account name, because that's what
/// every backend call addresses.
struct EmailAccount: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let email: String
    let provider: EmailProvider
    var lastSyncedAt: TimeInterval?
}

/// A mailbox on an account, as Himalaya lists it (with counts).
struct MailFolder: Codable, Equatable, Sendable {
    let account: String
    let id: String
    let name: String
    let role: String
    let total: Int
    let unseen: Int
}

/// The envelope of one message — everything the phone's list rows need. The
/// full body is fetched on demand from Himalaya, never cached.
struct MailMessage: Codable, Equatable, Sendable {
    let account: String
    let mailbox: String
    let uid: String
    let fromName: String
    let fromAddress: String
    let subject: String
    let date: TimeInterval?
    let snippet: String
    let isUnread: Bool
    let isFlagged: Bool
    let hasAttachments: Bool

    /// The wire id the phone uses to address this message: account + mailbox +
    /// uid is exactly the triple every action (read, flag, move) needs.
    var id: String { "\(account)\u{1F}\(mailbox)\u{1F}\(uid)" }
}

/// One attachment, as `message read --json` reports it. Bodies (and therefore
/// attachment bytes) are fetched on demand; this is just the envelope.
struct MailAttachment: Codable, Equatable, Sendable {
    let id: String
    let filename: String
    let mime: String
    let size: Int
}

/// What one sync pass did — what the phone shows when a sync completes.
struct MailSyncResult: Codable, Equatable, Sendable {
    let synced: Int
    let unread: Int
    let at: TimeInterval
    let failedAccounts: [String]
}

// MARK: - MailManager

/// The unified mail hub: every account Himalaya is configured with (iCloud
/// today; Google/NYU the moment they're added there), one SQLite cache, one
/// inbox the phone reads over the socket.
///
/// Himalaya stays the single transport (see EmailCapability): credentials live
/// in the login Keychain, and an account added to `~/.config/himalaya/config.toml`
/// appears here on the next sync — no second email client to configure.
///
/// Threading: the manager is MainActor for its public surface (the socket
/// server and app delegate are both main-actor). The slow work — Himalaya
/// subprocesses and SQLite writes — runs inside detached tasks, so a sync
/// never blocks the UI. Every DB helper is static and `nonisolated`: they only
/// touch the connection passed in (FULLMUTEX-serialized) and the immutable db
/// path, so the detached sync pass never needs the MainActor singleton.
@MainActor
final class MailManager {

    static let shared = MailManager()

    /// Fired after every completed sync — wired to push `mail.sync_complete`
    /// to phones in AppDelegate.
    var onSyncCompleted: ((MailSyncResult) -> Void)?
    /// Fired when the total unread count changes — wired to push
    /// `mail.unread_count_changed`.
    var onUnreadCountChanged: ((Int) -> Void)?

    /// How often the background sync runs. 5 minutes by default; the phone can
    /// force one any time with `mail.sync`.
    static let syncInterval: TimeInterval = 300

    nonisolated private static let databasePath = NSHomeDirectory() + "/.alfred/mail.db"

    private var timer: Timer?
    private var isSyncing = false
    private var cachedUnread = 0

    private init() {
        do {
            try FileManager.default.createDirectory(
                atPath: NSHomeDirectory() + "/.alfred", withIntermediateDirectories: true)
            let db = try Self.openDB()
            defer { sqlite3_close(db) }
            try Self.runMigration(db)
        } catch {
            NSLog("[mail] init failed: %@", error.localizedDescription)
        }
    }

    // MARK: - Lifecycle

    /// Kick off the first sync and start the recurring timer. Idempotent.
    func start() {
        guard timer == nil else { return }
        sync()   // fire once immediately so the phone has mail before the first tick
        let timer = Timer(timeInterval: Self.syncInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sync() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        NSLog("[mail] sync timer started (every \(Int(Self.syncInterval))s)")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Accounts

    /// Every account Himalaya is configured with, from its TOML. Accounts are
    /// cheap to re-read, so this is never cached across calls — a config edit
    /// (someone adds NYU) shows up immediately.
    var accounts: [EmailAccount] {
        Self.discoverAccounts()
    }

    /// The default send account: the one Himalaya marks `default = true`, or
    /// the first when none is marked.
    var defaultAccountID: String {
        Self.defaultAccountIDFromConfig() ?? accounts.first?.id ?? ""
    }

    /// True when Himalaya itself is missing — the phone should say so instead
    /// of showing a mysteriously empty inbox.
    var isBackendAvailable: Bool {
        let candidates = [
            "/opt/homebrew/bin/himalaya", "/usr/local/bin/himalaya",
            "\(NSHomeDirectory())/.local/bin/himalaya",
        ]
        return candidates.contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    var totalUnread: Int { cachedUnread }

    // MARK: - Sync

    /// Refresh every account's inbox into the cache. Runs the Himalaya fetches
    /// off the main actor; only the callbacks fire on it. Never throws — a
    /// failing account degrades to a logged skip, and the phone still gets a
    /// result.
    func sync() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        let accountList = accounts
        let result = await Task.detached(priority: .utility) {
            Self.performSync(accounts: accountList)
        }.value

        if cachedUnread != result.unread {
            cachedUnread = result.unread
            onUnreadCountChanged?(result.unread)
        }
        onSyncCompleted?(result)
    }

    func sync() {
        Task { await self.sync() }
    }

    /// The actual sync pass. Static and nonisolated so it can run detached:
    /// Himalaya subprocesses block, and SQLite connections are per-call and
    /// FULLMUTEX-serialized, so nothing here needs the main actor.
    private nonisolated static func performSync(accounts: [EmailAccount]) -> MailSyncResult {
        var synced = 0
        var unread = 0
        var failures: [String] = []
        let cap = EmailCapability.shared

        for account in accounts {
            do {
                // Folder counts first — the inbox id and the authoritative
                // unread number both come from here.
                let mailboxes = try cap.mailboxes(account: account.id)
                let folders = mailboxes.map {
                    MailFolder(account: account.id, id: $0.id, name: $0.name,
                               role: Self.role(for: $0.name),
                               total: $0.total, unseen: $0.unread)
                }
                let inboxID = Self.inboxFolderID(in: folders) ?? "Inbox"
                let inbox = folders.first { $0.id == inboxID }
                if let inbox { unread += inbox.unseen }
                try replaceFolders(account: account.id, folders: folders)

                // Envelopes for the inbox only — that's the list the phone
                // renders, and caching the archive would cost far more than
                // search over the inbox is worth.
                let envelopes = try cap.latestEnvelopes(
                    account: account.id, mailbox: inboxID, limit: 100)
                synced += try replaceMessages(
                    account: account.id, mailbox: inboxID, envelopes: envelopes)

                try touchAccount(account, at: Date().timeIntervalSince1970)
            } catch {
                NSLog("[mail] sync failed for \(account.id): %@", error.localizedDescription)
                failures.append(account.id)
            }
        }

        return MailSyncResult(
            synced: synced, unread: unread,
            at: Date().timeIntervalSince1970, failedAccounts: failures)
    }

    /// The account's inbox mailbox: the folder whose role maps to inbox, or the
    /// id literally named Inbox, or the first folder as a last resort.
    private nonisolated static func inboxFolderID(in folders: [MailFolder]) -> String? {
        if let inbox = folders.first(where: { $0.role == "inbox" }) { return inbox.id }
        if let named = folders.first(where: { $0.id.lowercased() == "inbox" }) { return named.id }
        return folders.first?.id
    }

    // MARK: - Inbox & search

    /// The cached inbox, newest first. `accountID` nil = the unified inbox.
    func inbox(accountID: String?, limit: Int = 100) -> [MailMessage] {
        guard let db = try? Self.openDB() else { return [] }
        defer { sqlite3_close(db) }

        var sql = """
            SELECT account, mailbox, uid, from_name, from_address, subject, date,
                   snippet, seen, flagged, has_attachments
            FROM mail_messages
            """
        var args: [Bind] = []
        if let accountID, !accountID.isEmpty {
            sql += " WHERE account = ?"
            args.append(.text(accountID))
        }
        sql += " ORDER BY date DESC LIMIT ?"
        args.append(.int(limit))

        var rows: [MailMessage] = []
        do {
            try Self.queryRows(db, sql: sql, args: args) { stmt in
                rows.append(Self.message(stmt))
            }
        } catch {
            NSLog("[mail] inbox query failed: %@", error.localizedDescription)
        }
        return rows
    }

    /// LIKE search across the cached inbox — subject, sender, and snippet.
    /// Instant (the cache is a few hundred rows) and good enough that FTS on a
    /// local envelope cache would be over-engineering.
    func search(query: String, accountID: String?, limit: Int = 100) -> [MailMessage] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return inbox(accountID: accountID, limit: limit) }
        guard let db = try? Self.openDB() else { return [] }
        defer { sqlite3_close(db) }

        let like = "%" + trimmed
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_") + "%"

        var sql = """
            SELECT account, mailbox, uid, from_name, from_address, subject, date,
                   snippet, seen, flagged, has_attachments
            FROM mail_messages
            WHERE (subject LIKE ? ESCAPE '\\' OR snippet LIKE ? ESCAPE '\\'
                   OR from_name LIKE ? ESCAPE '\\' OR from_address LIKE ? ESCAPE '\\')
            """
        var args: [Bind] = [.text(like), .text(like), .text(like), .text(like)]
        if let accountID, !accountID.isEmpty {
            sql += " AND account = ?"
            args.append(.text(accountID))
        }
        sql += " ORDER BY date DESC LIMIT ?"
        args.append(.int(limit))

        var rows: [MailMessage] = []
        do {
            try Self.queryRows(db, sql: sql, args: args) { stmt in
                rows.append(Self.message(stmt))
            }
        } catch {
            NSLog("[mail] search failed: %@", error.localizedDescription)
        }
        return rows
    }

    /// One cached envelope, by the (account, mailbox, uid) triple.
    func message(account: String, mailbox: String, uid: String) -> MailMessage? {
        inbox(accountID: account, limit: 1000).first {
            $0.account == account && $0.mailbox == mailbox && $0.uid == uid
        }
    }

    // MARK: - Folders

    /// Every folder on the account, fresh from Himalaya (counts included).
    func folders(accountID: String) async -> [MailFolder] {
        await Task.detached(priority: .utility) {
            (try? EmailCapability.shared.mailboxes(account: accountID)) ?? []
        }.value.map {
            MailFolder(account: accountID, id: $0.id, name: $0.name,
                       role: Self.role(for: $0.name),
                       total: $0.total, unseen: $0.unread)
        }
    }

    /// The mailbox to move "trash" / "archive" actions into, resolving the role
    /// against the account's real folder list. Falls back to the conventional
    /// iCloud names when the list is unreachable.
    func folder(forRole role: String, accountID: String) async -> String? {
        let folders = await folders(accountID: accountID)
        if let match = folders.first(where: { $0.role == role }) { return match.id }
        switch role {
        case "archive": return "Archive"
        case "trash": return "Deleted Messages"
        default: return nil
        }
    }

    // MARK: - Full message

    /// A message with its body, fresh from Himalaya. Structuring it here keeps
    /// the wire dictionary (and the phone) simple: one call, everything a
    /// reader screen needs.
    func messageParts(account: String, mailbox: String, uid: String) async throws
        -> EmailCapability.MessageParts {
        try await Task.detached(priority: .userInitiated) {
            try EmailCapability.shared.readMessageParts(
                id: uid, account: account, mailbox: mailbox)
        }.value
    }

    // MARK: - Actions

    /// Mark read/unread. The Himalaya round trip runs off the main actor; the
    /// cache flag updates locally so the next inbox render reflects it without
    /// waiting for a sync.
    func markRead(account: String, mailbox: String, uid: String, read: Bool) async throws {
        try await detachedHimalaya {
            try EmailCapability.shared.setFlags(
                account: account, mailbox: mailbox, messageID: uid, seen: read, flagged: nil)
        }
        Self.updateMessageFlags(account: account, mailbox: mailbox, uid: uid,
                                seen: read, flagged: nil)
    }

    /// Flag/unflag.
    func setFlag(account: String, mailbox: String, uid: String, flagged: Bool) async throws {
        try await detachedHimalaya {
            try EmailCapability.shared.setFlags(
                account: account, mailbox: mailbox, messageID: uid, seen: nil, flagged: flagged)
        }
        Self.updateMessageFlags(account: account, mailbox: mailbox, uid: uid,
                                seen: nil, flagged: flagged)
    }

    /// Move a message to a mailbox by role (trash/archive).
    func move(account: String, mailbox: String, uid: String, to role: String) async throws {
        guard let destination = await folder(forRole: role, accountID: account) else {
            throw MailError.unknownFolder(role)
        }
        try await detachedHimalaya {
            try EmailCapability.shared.moveMessage(
                account: account, fromMailbox: mailbox, toMailbox: destination, messageID: uid)
        }
        Self.deleteMessage(account: account, mailbox: mailbox, uid: uid)
    }

    /// Send a new message and save a copy to Sent. The From address is the
    /// account's configured address — Himalaya signs what it's configured to.
    func send(to: String, cc: String?, subject: String, body: String,
              accountID: String, inReplyTo: String?) async throws {
        let account = accounts.first { $0.id == accountID } ?? accounts.first
        guard let account else { throw MailError.noAccount }
        try await detachedHimalaya {
            _ = try EmailCapability.shared.sendMessage(
                to: to, cc: cc, subject: subject, body: body,
                inReplyTo: inReplyTo, account: account.id)
        }
    }

    // MARK: - Wire dictionaries

    /// Accounts as the phone expects them, with live unread counts.
    func accountsWire() -> [[String: Any]] {
        accounts.map { account in
            var dict: [String: Any] = [
                "id": account.id,
                "name": account.name,
                "email": account.email,
                "provider": account.provider.rawValue,
                "last_synced_at": account.lastSyncedAt ?? 0,
            ]
            dict["unread"] = Self.foldersUnread(for: account.id)
            return dict
        }
    }

    func messageWire(_ message: MailMessage) -> [String: Any] {
        [
            "id": message.id,
            "account_id": message.account,
            "mailbox": message.mailbox,
            "uid": message.uid,
            "from": message.fromName,
            "from_address": message.fromAddress,
            "subject": message.subject,
            "date": message.date ?? 0,
            "snippet": message.snippet,
            "seen": !message.isUnread,
            "flagged": message.isFlagged,
            "has_attachments": message.hasAttachments,
        ]
    }

    func folderWire(_ folder: MailFolder) -> [String: Any] {
        [
            "id": folder.id,
            "name": folder.name,
            "role": folder.role,
            "unseen": folder.unseen,
            "total": folder.total,
        ]
    }

    // MARK: - Config discovery

    /// Parse `~/.config/himalaya/config.toml` for `[accounts.X]` sections that
    /// carry an email and an IMAP server. Pure string scanning of a small,
    /// machine-written file — no TOML dependency needed.
    nonisolated private static func discoverAccounts() -> [EmailAccount] {
        let home = NSHomeDirectory()
        let paths = [
            home + "/.config/himalaya/config.toml",
            home + "/.himalayarc",
        ]
        guard let path = paths.first(where: { FileManager.default.fileExists(atPath: $0) }),
              let text = FileManager.default.contents(atPath: path),
              let content = String(data: text, encoding: .utf8)
        else { return [] }

        var accounts: [EmailAccount] = []
        var currentID: String?
        var currentEmail: String?
        var currentName: String?
        var hasIMAP = false

        func flush() {
            defer {
                currentID = nil; currentEmail = nil; currentName = nil; hasIMAP = false
            }
            guard let id = currentID, let email = currentEmail, hasIMAP else { return }
            let name = currentName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"")) ?? email
            accounts.append(EmailAccount(
                id: id,
                name: name.isEmpty ? email : name,
                email: email,
                provider: EmailProvider.infer(from: email),
                lastSyncedAt: nil))
        }

        for rawLine in content.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                flush()
                let section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                if section.hasPrefix("accounts.") {
                    currentID = String(section.dropFirst("accounts.".count))
                        .trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            guard currentID != nil else { continue }
            if let eq = line.firstIndex(of: "=") {
                let key = line[..<eq].trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: eq)...])
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                switch key {
                case "email": currentEmail = value
                case "display-name", "display_name": currentName = value
                case "imap.server": hasIMAP = true
                default: break
                }
            }
        }
        flush()

        // Hydrate lastSyncedAt from the DB, and prefer the config's default
        // account first so the phone's send picker defaults to the right one.
        let synced = syncedAccounts()
        var ordered = accounts
        if let def = defaultAccountIDFromConfig(),
           let idx = ordered.firstIndex(where: { $0.id == def }) {
            let account = ordered.remove(at: idx)
            ordered.insert(account, at: 0)
        }
        return ordered.map { account in
            var copy = account
            copy.lastSyncedAt = synced[account.id]
            return copy
        }
    }

    nonisolated private static func defaultAccountIDFromConfig() -> String? {
        let home = NSHomeDirectory()
        let path = home + "/.config/himalaya/config.toml"
        guard let text = FileManager.default.contents(atPath: path),
              let content = String(data: text, encoding: .utf8)
        else { return nil }

        var currentID: String?
        var defaultID: String?
        var firstID: String?
        for rawLine in content.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                let section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                if section.hasPrefix("accounts.") {
                    currentID = String(section.dropFirst("accounts.".count))
                        .trimmingCharacters(in: .whitespaces)
                    if firstID == nil { firstID = currentID }
                } else {
                    currentID = nil
                }
                continue
            }
            guard let id = currentID, defaultID == nil else { continue }
            _ = id
            if line.hasPrefix("default") && line.contains("true") {
                defaultID = currentID
            }
        }
        return defaultID ?? firstID
    }

    // MARK: - SQLite plumbing (all static + nonisolated: connections are per-call)

    nonisolated private static func openDB() throws -> OpaquePointer {
        var db: OpaquePointer?
        // FULLMUTEX: syncs run off the main actor while the phone can query —
        // serialize connections across threads.
        let rc = sqlite3_open_v2(databasePath, &db,
                                 SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                                 nil)
        guard rc == SQLITE_OK, let db else {
            throw MailError.database("could not open \(databasePath) (\(rc))")
        }
        return db
    }

    nonisolated private static func lastErrorMessage(_ db: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(db))
    }

    nonisolated private static func runMigration(_ db: OpaquePointer) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, migrationDDL, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let message = errMsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errMsg)
            throw MailError.database(message)
        }
    }

    nonisolated private static let migrationDDL = """
    CREATE TABLE IF NOT EXISTS mail_accounts (
        id              TEXT PRIMARY KEY,
        name            TEXT NOT NULL,
        email           TEXT NOT NULL,
        provider        TEXT NOT NULL,
        last_synced_at  REAL
    );

    CREATE TABLE IF NOT EXISTS mail_folders (
        account     TEXT NOT NULL,
        id          TEXT NOT NULL,
        name        TEXT NOT NULL,
        role        TEXT NOT NULL DEFAULT 'folder',
        total       INTEGER NOT NULL DEFAULT 0,
        unseen      INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (account, id)
    );

    CREATE TABLE IF NOT EXISTS mail_messages (
        account         TEXT NOT NULL,
        mailbox         TEXT NOT NULL,
        uid             TEXT NOT NULL,
        from_name       TEXT NOT NULL DEFAULT '',
        from_address    TEXT NOT NULL DEFAULT '',
        subject         TEXT NOT NULL DEFAULT '',
        date            REAL,
        snippet         TEXT NOT NULL DEFAULT '',
        seen            INTEGER NOT NULL DEFAULT 0,
        flagged         INTEGER NOT NULL DEFAULT 0,
        has_attachments INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (account, mailbox, uid)
    );

    CREATE INDEX IF NOT EXISTS idx_mail_messages_date ON mail_messages(date);
    CREATE INDEX IF NOT EXISTS idx_mail_messages_account ON mail_messages(account);
    """

    private enum Bind {
        case text(String)
        case double(Double)
        case int(Int)
    }

    private enum MailError: LocalizedError {
        case database(String)
        case noAccount
        case unknownFolder(String)

        var errorDescription: String? {
            switch self {
            case .database(let message): return "mail store error: \(message)"
            case .noAccount: return "No mail account is configured on the Mac."
            case .unknownFolder(let role): return "No \(role) mailbox on that account."
            }
        }
    }

    nonisolated private static func exec(_ db: OpaquePointer, sql: String, args: [Bind] = []) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw MailError.database(lastErrorMessage(db))
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, args)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw MailError.database(lastErrorMessage(db))
        }
    }

    nonisolated private static func queryRows(_ db: OpaquePointer, sql: String, args: [Bind] = [],
                                             row: (OpaquePointer) -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw MailError.database(lastErrorMessage(db))
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, args)
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            row(stmt)
            rc = sqlite3_step(stmt)
        }
        if rc != SQLITE_DONE {
            throw MailError.database(lastErrorMessage(db))
        }
    }

    nonisolated private static func bind(_ stmt: OpaquePointer, _ args: [Bind]) {
        for (index, arg) in args.enumerated() {
            let i = Int32(index + 1)
            switch arg {
            case .text(let value):
                sqlite3_bind_text(stmt, i, value, -1, SQLITE_TRANSIENT)
            case .double(let value):
                sqlite3_bind_double(stmt, i, value)
            case .int(let value):
                sqlite3_bind_int64(stmt, i, Int64(value))
            }
        }
    }

    nonisolated private static func textColumn(_ stmt: OpaquePointer, _ index: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: c)
    }

    nonisolated private static func intColumn(_ stmt: OpaquePointer, _ index: Int32) -> Int {
        Int(sqlite3_column_int64(stmt, index))
    }

    nonisolated private static func doubleColumn(_ stmt: OpaquePointer, _ index: Int32) -> Double {
        sqlite3_column_double(stmt, index)
    }

    nonisolated private static func nullableDoubleColumn(_ stmt: OpaquePointer, _ index: Int32) -> Double? {
        sqlite3_column_type(stmt, index) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, index)
    }

    /// Read a mail_messages row into a MailMessage.
    nonisolated private static func message(_ stmt: OpaquePointer) -> MailMessage {
        MailMessage(
            account: textColumn(stmt, 0),
            mailbox: textColumn(stmt, 1),
            uid: textColumn(stmt, 2),
            fromName: textColumn(stmt, 3),
            fromAddress: textColumn(stmt, 4),
            subject: textColumn(stmt, 5),
            date: nullableDoubleColumn(stmt, 6),
            snippet: textColumn(stmt, 7),
            isUnread: intColumn(stmt, 8) == 0,
            isFlagged: intColumn(stmt, 9) != 0,
            hasAttachments: intColumn(stmt, 10) != 0)
    }

    // MARK: - DB mutations

    /// Upsert one account's sync timestamp.
    nonisolated private static func touchAccount(_ account: EmailAccount, at: TimeInterval) throws {
        let db = try openDB()
        defer { sqlite3_close(db) }
        try exec(db, sql: """
            INSERT INTO mail_accounts (id, name, email, provider, last_synced_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name, email = excluded.email,
                provider = excluded.provider, last_synced_at = excluded.last_synced_at
            """, args: [.text(account.id), .text(account.name), .text(account.email),
                        .text(account.provider.rawValue), .double(at)])
    }

    nonisolated private static func syncedAccounts() -> [String: TimeInterval] {
        guard let db = try? openDB() else { return [:] }
        defer { sqlite3_close(db) }
        var result: [String: TimeInterval] = [:]
        do {
            try queryRows(db, sql: "SELECT id, last_synced_at FROM mail_accounts") { stmt in
                if let at = nullableDoubleColumn(stmt, 1) {
                    result[textColumn(stmt, 0)] = at
                }
            }
        } catch { }
        return result
    }

    /// Replace one account's folder rows (counts drift on every sync; the
    /// folder list is the source of truth).
    nonisolated private static func replaceFolders(account: String,
                                                   folders: [MailFolder]) throws {
        let db = try openDB()
        defer { sqlite3_close(db) }
        try exec(db, sql: "DELETE FROM mail_folders WHERE account = ?",
                 args: [.text(account)])
        for folder in folders {
            try exec(db, sql: """
                INSERT INTO mail_folders (account, id, name, role, total, unseen)
                VALUES (?, ?, ?, ?, ?, ?)
                """, args: [
                    .text(account), .text(folder.id), .text(folder.name),
                    .text(folder.role), .int(folder.total), .int(folder.unseen),
                ])
        }
    }

    /// Replace one mailbox's message rows with a fresh envelope fetch. Returns
    /// how many rows landed. Deleting-then-inserting keeps the cache honest
    /// with the server (a message moved or deleted remotely disappears here)
    /// at the cost of one small table rewrite per sync.
    nonisolated private static func replaceMessages(account: String, mailbox: String,
                                                    envelopes: [EmailCapability.MailEnvelope]) throws -> Int {
        let db = try openDB()
        defer { sqlite3_close(db) }
        try exec(
            db, sql: "DELETE FROM mail_messages WHERE account = ? AND mailbox = ?",
            args: [.text(account), .text(mailbox)])

        for env in envelopes {
            try exec(db, sql: """
                INSERT INTO mail_messages
                    (account, mailbox, uid, from_name, from_address, subject,
                     date, snippet, seen, flagged, has_attachments)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, args: [
                    .text(account), .text(mailbox), .text(env.id),
                    .text(env.fromName ?? ""), .text(env.fromEmail),
                    .text(env.subject ?? "(no subject)"),
                    .double(env.date?.timeIntervalSince1970 ?? 0),
                    .text(String((env.subject ?? "").prefix(120))),
                    .int(env.isUnread ? 0 : 1),
                    .int(0),   // envelope list carries no flagged state
                    .int(0),
                ])
        }
        return envelopes.count
    }

    /// Local flag update after a successful Himalaya call — the next inbox
    /// render reflects it without waiting for a sync.
    nonisolated private static func updateMessageFlags(account: String, mailbox: String, uid: String,
                                                       seen: Bool?, flagged: Bool?) {
        guard let db = try? openDB() else { return }
        defer { sqlite3_close(db) }
        var sets: [String] = []
        var args: [Bind] = []
        if let seen {
            sets.append("seen = ?")
            args.append(.int(seen ? 1 : 0))
        }
        if let flagged {
            sets.append("flagged = ?")
            args.append(.int(flagged ? 1 : 0))
        }
        guard !sets.isEmpty else { return }
        args.append(.text(account))
        args.append(.text(mailbox))
        args.append(.text(uid))
        try? exec(db, sql: """
            UPDATE mail_messages SET \(sets.joined(separator: ", "))
            WHERE account = ? AND mailbox = ? AND uid = ?
            """, args: args)
    }

    /// Remove a message from the cache after it moved away.
    nonisolated private static func deleteMessage(account: String, mailbox: String, uid: String) {
        guard let db = try? openDB() else { return }
        defer { sqlite3_close(db) }
        try? exec(db, sql: """
            DELETE FROM mail_messages WHERE account = ? AND mailbox = ? AND uid = ?
            """, args: [.text(account), .text(mailbox), .text(uid)])
    }

    /// Unread total for one account from the cached folder counts.
    nonisolated private static func foldersUnread(for accountID: String) -> Int {
        guard let db = try? openDB() else { return 0 }
        defer { sqlite3_close(db) }
        var total = 0
        do {
            try queryRows(db, sql: """
                SELECT unseen FROM mail_folders
                WHERE account = ? AND (role = 'inbox' OR id = 'Inbox')
                """, args: [.text(accountID)]) { stmt in
                total += intColumn(stmt, 0)
            }
        } catch { }
        return total
    }

    // MARK: - Concurrency helpers

    /// Run a Himalaya call off the main actor and await it. The closure is
    /// @Sendable-safe: EmailCapability is an immutable value type.
    private func detachedHimalaya(_ work: @escaping @Sendable () throws -> Void) async throws {
        try await Task.detached(priority: .userInitiated) {
            try work()
        }.value
    }
}

// MARK: - Folder role inference

/// Classify a mailbox name into the role the UI understands. Case-insensitive
/// and tolerant of the backends' names (iCloud's "Deleted Messages" is trash,
/// Gmail's "[Gmail]/All Mail" is archive).
extension MailManager {
    nonisolated static func role(for name: String) -> String {
        let lower = name.lowercased()
        if lower == "inbox" || lower.hasSuffix("]inbox") { return "inbox" }
        if lower.contains("sent") { return "sent" }
        if lower.contains("draft") { return "drafts" }
        if lower.contains("junk") || lower.contains("spam") { return "junk" }
        if lower.contains("trash") || lower.contains("deleted") || lower.contains("bin") {
            return "trash"
        }
        if lower.contains("archive") || lower.contains("all mail") { return "archive" }
        if lower.contains("flagged") { return "flagged" }
        return "folder"
    }
}
