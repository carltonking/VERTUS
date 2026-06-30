import Foundation
import SQLite3
import Contacts

// MARK: - MessagesReadCapability
//
// Local, zero-auth reading of recent iMessage/SMS history straight from the Messages SQLite store
// (~/Library/Messages/chat.db), read-only. No API, no token. Needs Full Disk Access (already used
// by the Obsidian connector). Routed through QuickCommands so it's instant.
//
// macOS Ventura+ stopped populating message.text for many rows and stores the body in a binary
// `attributedBody` typedstream blob instead — so we decode that blob to recover the text.
//
// v1 shows the handle (phone/email) per message. Reverse-resolving handles to contact names is a
// follow-up enhancement.

struct MessagesReadCapability {

    private static let dbPath = NSHomeDirectory() + "/Library/Messages/chat.db"

    static func detect(_ lowered: String) -> Bool {
        let triggers = ["read my messages", "recent messages", "recent texts", "my messages",
                        "my texts", "check my messages", "check my texts", "check messages",
                        "new messages", "any messages", "any new messages", "last messages",
                        "latest texts", "latest messages", "show my messages", "show me my messages",
                        "what are my messages", "recent imessages"]
        return triggers.contains { lowered.contains($0) }
    }

    /// Requests Contacts access if it hasn't been decided yet (prompts the user, binding the grant to
    /// the app's current signature). Without this, name resolution silently returns empty.
    static func ensureContactsAccess() async {
        guard CNContactStore.authorizationStatus(for: .contacts) == .notDetermined else { return }
        _ = await withCheckedContinuation { continuation in
            CNContactStore().requestAccess(for: .contacts) { granted, _ in continuation.resume(returning: granted) }
        }
    }

    /// Returns recent RECEIVED messages as "Name: text", grouped per sender, newest first. Skips the
    /// user's own sent messages (they asked for just what people sent them). Names come from Contacts.
    static func recent(limit: Int = 15) -> String {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return "Couldn't open Messages — grant Alfred Full Disk Access (System Settings → Privacy & Security → Full Disk Access → Alfred), then try again."
        }
        defer { sqlite3_close(db) }

        // is_from_me = 0 → received only; associated_message_type = 0 → real messages (no reactions).
        let sql = """
            SELECT m.text, m.attributedBody, h.id
            FROM message m
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            WHERE m.is_from_me = 0 AND m.associated_message_type = 0
            ORDER BY m.date DESC
            LIMIT \(limit)
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return "Couldn't read Messages (query failed)."
        }
        defer { sqlite3_finalize(stmt) }

        var rows: [(handle: String, body: String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var body = ""
            if let cText = sqlite3_column_text(stmt, 0) { body = String(cString: cText) }
            if body.isEmpty, sqlite3_column_type(stmt, 1) != SQLITE_NULL {
                let bytes = sqlite3_column_bytes(stmt, 1)
                if let blob = sqlite3_column_blob(stmt, 1), bytes > 0 {
                    body = decodeAttributedBody(Data(bytes: blob, count: Int(bytes))) ?? ""
                }
            }
            if body.isEmpty { body = "[attachment]" }
            let handle = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "Unknown"
            rows.append((handle, body.replacingOccurrences(of: "\n", with: " ")))
        }

        guard !rows.isEmpty else { return "No new messages." }

        // Build a phone/email → name index from ALL contacts once, then match by normalized digits.
        // Far more reliable than CNContact.predicateForContacts(matching:), which misses across
        // formatting differences (+1 prefixes, spaces, parens, the "(smsft)" RCS suffixes, etc.).
        let index = contactIndex()
        func name(for handle: String) -> String {
            let h = handle.lowercased()
            if h.contains("@") {
                let clean = h.split(separator: "(").first.map(String.init) ?? h
                return index[clean] ?? handle
            }
            let key = normalizePhone(handle)
            return index[key] ?? handle
        }

        // Group consecutive messages from the same sender → "Name: text1 · text2".
        var lines: [String] = []
        var i = 0
        while i < rows.count {
            let handle = rows[i].handle
            var texts: [String] = []
            var j = i
            while j < rows.count && rows[j].handle == handle {
                texts.append(String(rows[j].body.prefix(160))); j += 1
            }
            lines.append("\(name(for: handle)): \(texts.reversed().joined(separator: " · "))")
            i = j
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Sent-message read (voice learning)

    struct SentMessage { let rowid: Int64; let text: String }

    /// Recent SENT messages (is_from_me = 1) for learning the user's real writing voice, newest first.
    static func recentSentMessages(afterRowID: Int64 = 0, limit: Int = 500) -> [SentMessage] {
        sentMessages(afterRowID: afterRowID, limit: limit, dbPath: dbPath)
    }

    /// Core sent-message query against an explicit `dbPath` (so tests can point at a synthetic
    /// chat.db). Real messages only (associated_message_type = 0 → no tapbacks/reactions), non-empty
    /// body, ROWID > `afterRowID`, capped at `limit`, newest first. Opens read-only so the live
    /// Messages DB is never locked, and reuses `decodeAttributedBody` for Ventura+ rows where `text`
    /// is NULL and the body lives in the `attributedBody` typedstream blob.
    static func sentMessages(afterRowID: Int64, limit: Int, dbPath: String) -> [SentMessage] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db); return []
        }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT m.ROWID, m.text, m.attributedBody
            FROM message m
            WHERE m.is_from_me = 1 AND m.associated_message_type = 0 AND m.ROWID > ?
            ORDER BY m.ROWID DESC
            LIMIT \(max(0, limit))
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, afterRowID)

        var out: [SentMessage] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowid = sqlite3_column_int64(stmt, 0)
            var body = ""
            if let cText = sqlite3_column_text(stmt, 1) { body = String(cString: cText) }
            if body.isEmpty, sqlite3_column_type(stmt, 2) != SQLITE_NULL {
                let bytes = sqlite3_column_bytes(stmt, 2)
                if let blob = sqlite3_column_blob(stmt, 2), bytes > 0 {
                    body = decodeAttributedBody(Data(bytes: blob, count: Int(bytes))) ?? ""
                }
            }
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != "[attachment]" else { continue }
            out.append(SentMessage(rowid: rowid, text: trimmed))
        }
        return out
    }

    // MARK: - New-message detection (InboundWatcher)

    struct Received { let rowid: Int64; let handle: String; let name: String; let text: String }

    /// Highest ROWID among received messages — used to baseline the watcher's cursor on first run.
    static func maxReceivedRowID() -> Int64? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db); return nil
        }
        defer { sqlite3_close(db) }
        let sql = "SELECT MAX(ROWID) FROM message WHERE is_from_me = 0 AND associated_message_type = 0"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return sqlite3_column_type(stmt, 0) == SQLITE_NULL ? 0 : sqlite3_column_int64(stmt, 0)
    }

    /// Received messages with ROWID greater than `afterRowID`, oldest first. Returns [] if the store
    /// can't be opened (Full Disk Access missing) — the watcher treats that as "nothing new".
    static func recentReceived(afterRowID: Int64, limit: Int = 10) -> [Received] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db); return []
        }
        defer { sqlite3_close(db) }
        let sql = """
            SELECT m.ROWID, m.text, m.attributedBody, h.id
            FROM message m
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            WHERE m.is_from_me = 0 AND m.associated_message_type = 0 AND m.ROWID > ?
            ORDER BY m.ROWID ASC
            LIMIT \(limit)
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, afterRowID)

        let index = contactIndex()
        var out: [Received] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowid = sqlite3_column_int64(stmt, 0)
            var body = ""
            if let cText = sqlite3_column_text(stmt, 1) { body = String(cString: cText) }
            if body.isEmpty, sqlite3_column_type(stmt, 2) != SQLITE_NULL {
                let bytes = sqlite3_column_bytes(stmt, 2)
                if let blob = sqlite3_column_blob(stmt, 2), bytes > 0 {
                    body = decodeAttributedBody(Data(bytes: blob, count: Int(bytes))) ?? ""
                }
            }
            if body.isEmpty { body = "[attachment]" }
            let handle = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "Unknown"
            out.append(Received(rowid: rowid, handle: handle,
                                name: nameForHandle(handle, index: index),
                                text: body.replacingOccurrences(of: "\n", with: " ")))
        }
        return out
    }

    private static func nameForHandle(_ handle: String, index: [String: String]) -> String {
        let h = handle.lowercased()
        if h.contains("@") {
            let clean = h.split(separator: "(").first.map(String.init) ?? h
            return index[clean] ?? handle
        }
        let key = normalizePhone(handle)
        return index[key] ?? handle
    }

    /// Builds a lookup of every contact phone (last-10-digits) and email → display name.
    private static func contactIndex() -> [String: String] {
        var index: [String: String] = [:]
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return index }
        let store = CNContactStore()
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey,
                    CNContactOrganizationNameKey, CNContactPhoneNumbersKey,
                    CNContactEmailAddressesKey] as [CNKeyDescriptor]
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.unifyResults = true
        try? store.enumerateContacts(with: request) { contact, _ in
            let name = displayName(contact)
            guard !name.isEmpty else { return }
            for phone in contact.phoneNumbers {
                let key = normalizePhone(phone.value.stringValue)
                if !key.isEmpty { index[key] = name }
            }
            for email in contact.emailAddresses {
                index[(email.value as String).lowercased()] = name
            }
        }
        return index
    }

    private static func displayName(_ c: CNContact) -> String {
        let full = "\(c.givenName) \(c.familyName)".trimmingCharacters(in: .whitespaces)
        if !full.isEmpty { return full }
        if !c.nickname.isEmpty { return c.nickname }
        return c.organizationName.trimmingCharacters(in: .whitespaces)
    }

    /// Last 10 digits — the stable part across +1 prefixes, spaces, parens, and RCS suffixes.
    private static func normalizePhone(_ s: String) -> String {
        let digits = s.filter(\.isNumber)
        return digits.count >= 10 ? String(digits.suffix(10)) : digits
    }

    // MARK: - attributedBody decode (typedstream string extraction)

    /// Pulls the message text out of the `attributedBody` typedstream blob. The body is stored as an
    /// NSString: after the "NSString" class marker comes a '+' (0x2b), then a length, then the UTF-8
    /// bytes. Length is one byte when < 0x80, or 0x81 followed by a little-endian UInt16.
    static func decodeAttributedBody(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        guard let marker = firstIndex(of: [UInt8]("NSString".utf8), in: bytes) else { return nil }

        var i = marker + 8
        while i < bytes.count && bytes[i] != 0x2b { i += 1 }   // find the '+' length marker
        guard i < bytes.count else { return nil }
        i += 1
        guard i < bytes.count else { return nil }

        var length = 0
        let lenByte = bytes[i]
        if lenByte < 0x80 {
            length = Int(lenByte); i += 1
        } else if lenByte == 0x81 {
            guard i + 2 < bytes.count else { return nil }
            length = Int(bytes[i + 1]) | (Int(bytes[i + 2]) << 8); i += 3
        } else {
            return nil
        }
        guard length > 0, i + length <= bytes.count else { return nil }
        return String(bytes: bytes[i..<i + length], encoding: .utf8)
    }

    private static func firstIndex(of pattern: [UInt8], in bytes: [UInt8]) -> Int? {
        guard !pattern.isEmpty, bytes.count >= pattern.count else { return nil }
        for i in 0...(bytes.count - pattern.count) where Array(bytes[i..<i + pattern.count]) == pattern {
            return i
        }
        return nil
    }
}
