import Foundation
import CryptoKit
import Security
import OSLog

private let logger = Logger(subsystem: "com.alfred.app", category: "BackupService")

@MainActor
final class MemoryBackupService {
    let backupDirectory: URL
    var autoBackupEnabled: Bool {
        didSet { UserDefaults.standard.set(autoBackupEnabled, forKey: backupEnabledKey) }
    }
    var autoBackupInterval: TimeInterval = 86400
    var maxBackupCount: Int {
        didSet { UserDefaults.standard.set(maxBackupCount, forKey: backupMaxCountKey) }
    }
    var encryptByDefault: Bool {
        didSet { UserDefaults.standard.set(encryptByDefault, forKey: backupEncryptDefaultKey) }
    }

    private var backupTimer: Timer?
    private var encryptionKey: SymmetricKey?
    private let queue = DispatchQueue(label: "com.alfred.backup", qos: .utility)
    private let backupEnabledKey = "autoBackupEnabled"
    private let backupMaxCountKey = "backupMaxBackupCount"
    private let backupEncryptDefaultKey = "backupEncryptByDefault"
    private let lastContentHashKey = "lastBackupContentHash"
    private let keychainAccount = "com.alfred.backup.key"
    private let magicHeader = "ALFREDBACKUP".data(using: .utf8)!
    private let currentBackupVersion = "1.0"
    private var retryAttempts: [Date: Int] = [:]
    private let maxRetryInterval: TimeInterval = 86400

    private weak var relationshipMemoryService: RelationshipMemoryService?
    private weak var memoryReflectionService: MemoryReflectionService?
    private weak var workflowDetectionService: WorkflowDetectionService?
    private weak var memoryLinkService: MemoryLinkService?

    init(relationshipService: RelationshipMemoryService, reflectionService: MemoryReflectionService) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        backupDirectory = home.appending(path: ".alfred/backups", directoryHint: .isDirectory)
        autoBackupEnabled = UserDefaults.standard.object(forKey: backupEnabledKey) as? Bool ?? true
        maxBackupCount = UserDefaults.standard.object(forKey: backupMaxCountKey) as? Int ?? 10
        encryptByDefault = UserDefaults.standard.object(forKey: backupEncryptDefaultKey) as? Bool ?? false
        relationshipMemoryService = relationshipService
        memoryReflectionService = reflectionService
    }

    func initialize() {
        try? FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        loadEncryptionKey()
        if autoBackupEnabled {
            startAutoBackup()
        }
    }

    func setWorkflowDetectionService(_ service: WorkflowDetectionService) {
        workflowDetectionService = service
    }

    func setMemoryLinkService(_ service: MemoryLinkService) {
        memoryLinkService = service
    }

    // MARK: - Encryption Key

    private func loadEncryptionKey() {
        if let data = BackupKeychainHelper.loadData(account: keychainAccount), data.count == 32 {
            encryptionKey = SymmetricKey(data: data)
            return
        }
        if encryptByDefault {
            let key = SymmetricKey(size: .bits256)
            let data = Data(key.withUnsafeBytes { Data($0) })
            BackupKeychainHelper.saveData(data, account: keychainAccount)
            encryptionKey = key
        }
    }

    private func ensureEncryptionKey() -> SymmetricKey {
        if let existing = encryptionKey { return existing }
        let key = SymmetricKey(size: .bits256)
        let data = Data(key.withUnsafeBytes { Data($0) })
        BackupKeychainHelper.saveData(data, account: keychainAccount)
        encryptionKey = key
        return key
    }

    // MARK: - Backup Creation

    @discardableResult
    func createBackup(encrypted: Bool = false) -> BackupMetadata? {
        guard let memService = relationshipMemoryService, let refService = memoryReflectionService else { return nil }

        let memories = memService.allMemoriesForAnalysis()
        let reflections = refService.getReflections(includeDismissed: true)
        let workflows = workflowDetectionService?.allWorkflows ?? []
        let links = memoryLinkService?.getAllLinks() ?? []

        let backupData = BackupData(
            version: currentBackupVersion,
            exportedAt: Date(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            relationshipMemories: memories,
            reflections: reflections,
            workflows: workflows,
            links: links,
            metadata: BackupDataMetadata(
                memoryCount: memories.count,
                reflectionCount: reflections.count,
                workflowCount: workflows.count,
                linkCount: links.count,
                sourceDevice: Host.current().localizedName ?? "unknown",
                alfredVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
            )
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        guard let jsonData = try? encoder.encode(backupData) else {
            logger.error("Failed to encode backup data")
            return nil
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = dateFormatter.string(from: Date())
        let isEncrypted = encrypted || encryptByDefault

        let filename: String
        let finalData: Data

        if isEncrypted {
            filename = "alfred_backup_\(timestamp).alfredbackup"
            guard let encData = encryptBackupData(jsonData) else {
                logger.error("Failed to encrypt backup")
                return nil
            }
            finalData = encData
        } else {
            filename = "alfred_backup_\(timestamp).json"
            finalData = jsonData
        }

        let fileURL = backupDirectory.appending(path: filename, directoryHint: .notDirectory)

        do {
            try finalData.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Failed to write backup: \(error.localizedDescription)")
            scheduleRetry()
            return nil
        }

        let metadata = BackupMetadata(
            id: UUID().uuidString,
            filename: filename,
            createdAt: Date(),
            size: Int64(finalData.count),
            encrypted: isEncrypted,
            memoryCount: memories.count,
            reflectionCount: reflections.count,
            workflowCount: workflows.count,
            linkCount: links.count,
            version: currentBackupVersion
        )

        updateContentHash(from: memories, reflections: reflections, workflows: workflows, links: links)
        pruneOldBackups()
        logger.info("Backup created: \(filename) (\(finalData.count) bytes)")

        return metadata
    }

    // MARK: - List Backups

    func listBackups() -> [BackupMetadata] {
        let files = (try? FileManager.default.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []

        var result: [BackupMetadata] = []
        for fileURL in files {
            let filename = fileURL.lastPathComponent
            guard filename.hasPrefix("alfred_backup_") else { continue }

            let isEncrypted = filename.hasSuffix(".alfredbackup")
            let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = resourceValues?.fileSize ?? 0
            let modDate = resourceValues?.contentModificationDate ?? Date()

            // Try to extract embedded metadata from unencrypted files
            var memoryCount = 0
            var reflectionCount = 0
            var workflowCount = 0
            var linkCount = 0
            var version = currentBackupVersion

            if !isEncrypted, let data = try? Data(contentsOf: fileURL) {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                if let backupData = try? decoder.decode(BackupData.self, from: data) {
                    memoryCount = backupData.metadata.memoryCount
                    reflectionCount = backupData.metadata.reflectionCount
                    workflowCount = backupData.metadata.workflowCount
                    linkCount = backupData.metadata.linkCount
                    version = backupData.version
                }
            }

            result.append(BackupMetadata(
                id: UUID().uuidString,
                filename: filename,
                createdAt: modDate,
                size: Int64(size),
                encrypted: isEncrypted,
                memoryCount: memoryCount,
                reflectionCount: reflectionCount,
                workflowCount: workflowCount,
                linkCount: linkCount,
                version: version
            ))
        }

        return result.sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - Restore

    func restoreFromBackup(url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else {
            logger.error("Cannot read backup file: \(url.lastPathComponent)")
            return false
        }

        let isEncrypted = url.pathExtension == "alfredbackup" || url.lastPathComponent.hasSuffix(".alfredbackup")
        let jsonData: Data

        if isEncrypted {
            guard let decrypted = decryptBackupData(data) else {
                logger.error("Failed to decrypt backup")
                return false
            }
            jsonData = decrypted
        } else {
            jsonData = data
        }

        guard validateBackupData(jsonData) else {
            logger.error("Backup validation failed")
            return false
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let backupData = try? decoder.decode(BackupData.self, from: jsonData) else {
            logger.error("Failed to decode backup data")
            return false
        }

        guard let memService = relationshipMemoryService, let refService = memoryReflectionService else {
            return false
        }

        // Clear existing
        memService.deleteAllMemories(includeArchived: true)
        refService.resetAll()

        // Import memories
        for memory in backupData.relationshipMemories {
            memService.forceSave(
                memory.content,
                category: memory.category,
                source: "backup_restore",
                importance: memory.importance,
                reasonSaved: memory.reasonSaved
            )
        }

        logger.info("Reflections from backup: \(backupData.reflections.count) (manual re-import needed)")

        if let wfService = workflowDetectionService {
            for workflow in backupData.workflows {
                wfService.addWorkflow(workflow)
            }
        }

        if let linkService = memoryLinkService {
            for link in backupData.links {
                linkService.addLink(link)
            }
        }

        logger.info("Restored from backup: \(backupData.metadata.memoryCount) memories, \(backupData.metadata.reflectionCount) reflections, \(backupData.workflows.count) workflows, \(backupData.links.count) links")
        return true
    }

    // MARK: - Merge Restore

    func mergeFromBackup(url: URL, strategy: MergeStrategy) -> MergeResult? {
        guard let data = try? Data(contentsOf: url) else { return nil }

        let isEncrypted = url.pathExtension == "alfredbackup" || url.lastPathComponent.hasSuffix(".alfredbackup")
        let jsonData: Data

        if isEncrypted {
            guard let decrypted = decryptBackupData(data) else { return nil }
            jsonData = decrypted
        } else {
            jsonData = data
        }

        guard validateBackupData(jsonData) else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let backupData = try? decoder.decode(BackupData.self, from: jsonData) else { return nil }

        guard let memService = relationshipMemoryService, let refService = memoryReflectionService else {
            return nil
        }

        switch strategy {
        case .replace:
            memService.deleteAllMemories(includeArchived: true)
            refService.resetAll()
            for memory in backupData.relationshipMemories {
                memService.forceSave(
                    memory.content,
                    category: memory.category,
                    source: "backup_restore",
                    importance: memory.importance,
                    reasonSaved: memory.reasonSaved
                )
            }
            if let linkService = memoryLinkService {
                for link in backupData.links {
                    linkService.addLink(link)
                }
            }
            return MergeResult(
                addedCount: backupData.relationshipMemories.count,
                updatedCount: 0,
                skippedCount: 0,
                conflictCount: 0,
                linkCount: backupData.links.count
            )

        case .merge:
            var added = 0
            var updated = 0
            var skipped = 0
            var conflicts = 0

            let existingMemories = memService.allMemoriesForAnalysis()
            let existingReflections = refService.getReflections(includeDismissed: true)

            let existingMemoryIds = Set(existingMemories.map { $0.id })
            let existingReflectionIds = Set(existingReflections.map { $0.id })
            let existingContentPairs = Set(existingMemories.map { "\($0.content):\($0.category.rawValue)" })

            for memory in backupData.relationshipMemories {
                let contentPair = "\(memory.content):\(memory.category.rawValue)"

                if existingMemoryIds.contains(memory.id) {
                    // Update existing
                    if let existingIdx = existingMemories.firstIndex(where: { $0.id == memory.id }) {
                        let existing = existingMemories[existingIdx]
                        if memory.lastReferenced > existing.lastReferenced {
                            memService.forceSave(
                                memory.content,
                                category: memory.category,
                                source: "backup_merge",
                                importance: memory.importance,
                                reasonSaved: memory.reasonSaved
                            )
                            updated += 1
                        } else {
                            skipped += 1
                        }
                    }
                } else if existingContentPairs.contains(contentPair) {
                    // Near-duplicate by content+category
                    if let existingIdx = existingMemories.firstIndex(where: {
                        $0.content == memory.content && $0.category == memory.category
                    }) {
                        if memory.lastReferenced > existingMemories[existingIdx].lastReferenced {
                            memService.forceSave(
                                memory.content,
                                category: memory.category,
                                source: "backup_merge",
                                importance: memory.importance,
                                reasonSaved: memory.reasonSaved
                            )
                            updated += 1
                        } else {
                            skipped += 1
                        }
                    }
                } else {
                    // New memory
                    memService.forceSave(
                        memory.content,
                        category: memory.category,
                        source: "backup_merge",
                        importance: memory.importance,
                        reasonSaved: memory.reasonSaved
                    )
                    added += 1
                }
            }

            for reflection in backupData.reflections {
                if existingReflectionIds.contains(reflection.id) {
                    skipped += 1
                } else {
                    conflicts += 1
                }
            }

            if let wfService = workflowDetectionService {
                for workflow in backupData.workflows {
                    wfService.addWorkflow(workflow)
                }
            }

            var linkMergeCount = 0
            if let linkService = memoryLinkService {
                let existingLinks = linkService.getAllLinks()
                let existingLinkIds = Set(existingLinks.map { $0.id })
                for link in backupData.links {
                    guard !existingLinkIds.contains(link.id) else { continue }
                    linkService.addLink(link)
                    linkMergeCount += 1
                }
            }

            return MergeResult(
                addedCount: added,
                updatedCount: updated,
                skippedCount: skipped,
                conflictCount: conflicts,
                linkCount: linkMergeCount
            )
        }
    }

    // MARK: - Pruning

    func pruneOldBackups() {
        let backups = listBackups()
        guard backups.count > maxBackupCount else { return }

        let toDelete = backups.sorted { $0.createdAt < $1.createdAt }.dropLast(maxBackupCount)
        for backup in toDelete {
            let fileURL = backupDirectory.appending(path: backup.filename, directoryHint: .notDirectory)
            try? FileManager.default.removeItem(at: fileURL)
        }
        logger.info("Pruned \(toDelete.count) old backup(s)")
    }

    // MARK: - Auto Backup

    func startAutoBackup() {
        stopAutoBackup()
        backupTimer = Timer.scheduledTimer(withTimeInterval: autoBackupInterval, repeats: true) { [weak self] _ in
            self?.performAutoBackup()
        }
        // Initial backup after 1 hour, not immediately
        DispatchQueue.global().asyncAfter(deadline: .now() + 3600) { [weak self] in
            guard let self else { return }
            if self.autoBackupEnabled {
                self.performAutoBackup()
            }
        }
        logger.info("Auto-backup started (interval: \(self.autoBackupInterval)s)")
    }

    func stopAutoBackup() {
        backupTimer?.invalidate()
        backupTimer = nil
    }

    private func performAutoBackup() {
        guard autoBackupEnabled else { return }
        guard hasContentChanged() else {
            logger.debug("Skipping auto-backup: no changes since last backup")
            return
        }
        queue.async { [weak self] in
            self?.createBackup()
        }
    }

    private func scheduleRetry() {
        let now = Date()
        retryAttempts[now] = 1
        // Clean old attempts
        retryAttempts = retryAttempts.filter { now.timeIntervalSince($0.key) < maxRetryInterval }

        let attemptCount = retryAttempts.count
        let delay = min(pow(2.0, Double(attemptCount)) * 3600, maxRetryInterval)

        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.autoBackupEnabled else { return }
            self.performAutoBackup()
        }
        logger.debug("Scheduled retry in \(delay)s (attempt \(attemptCount))")
    }

    // MARK: - Content Change Detection

    private func hasContentChanged() -> Bool {
        guard let memService = relationshipMemoryService, let refService = memoryReflectionService else { return false }
        let memories = memService.allMemoriesForAnalysis()
        let reflections = refService.getReflections(includeDismissed: true)
        let workflows = workflowDetectionService?.allWorkflows ?? []
        let links = memoryLinkService?.getAllLinks() ?? []
        return computeContentHash(from: memories, reflections: reflections, workflows: workflows, links: links) != lastContentHash
    }

    private var lastContentHash: String {
        UserDefaults.standard.string(forKey: lastContentHashKey) ?? ""
    }

    private func updateContentHash(from memories: [RelationshipMemory], reflections: [Reflection], workflows: [Workflow] = [], links: [MemoryLink] = []) {
        UserDefaults.standard.set(computeContentHash(from: memories, reflections: reflections, workflows: workflows, links: links), forKey: lastContentHashKey)
    }

    private func computeContentHash(from memories: [RelationshipMemory], reflections: [Reflection], workflows: [Workflow] = [], links: [MemoryLink] = []) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let sortedMemories = memories.sorted { $0.id.uuidString < $1.id.uuidString }
        let sortedReflections = reflections.sorted { $0.id.uuidString < $1.id.uuidString }
        let sortedWorkflows = workflows.sorted { $0.id.uuidString < $1.id.uuidString }
        let sortedLinks = links.sorted { $0.id.uuidString < $1.id.uuidString }
        guard let memData = try? encoder.encode(sortedMemories),
              let refData = try? encoder.encode(sortedReflections),
              let wfData = try? encoder.encode(sortedWorkflows),
              let linkData = try? encoder.encode(sortedLinks)
        else { return "" }
        var combined = Data()
        combined.append(memData)
        combined.append(refData)
        combined.append(wfData)
        combined.append(linkData)
        let hash = SHA256.hash(data: combined)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Sync Export / Import

    func exportForSync() -> Data? {
        guard let memService = relationshipMemoryService, let refService = memoryReflectionService else { return nil }

        let memories = memService.allMemoriesForAnalysis()
        let reflections = refService.getReflections(includeDismissed: true)
        let workflows = workflowDetectionService?.allWorkflows ?? []
        let links = memoryLinkService?.getAllLinks() ?? []

        let backupData = BackupData(
            version: currentBackupVersion,
            exportedAt: Date(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            relationshipMemories: memories,
            reflections: reflections,
            workflows: workflows,
            links: links,
            metadata: BackupDataMetadata(
                memoryCount: memories.count,
                reflectionCount: reflections.count,
                workflowCount: workflows.count,
                linkCount: links.count,
                sourceDevice: Host.current().localizedName ?? "unknown",
                alfredVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
            )
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        guard let jsonData = try? encoder.encode(backupData) else { return nil }

        if encryptByDefault {
            return encryptBackupData(jsonData)
        }
        return jsonData
    }

    func importFromSync(data: Data) -> Bool? {
        let payload: Data

        if data.count > magicHeader.count, data.prefix(magicHeader.count) == magicHeader {
            guard let decrypted = decryptBackupData(data) else { return nil }
            payload = decrypted
        } else {
            payload = data
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let backupData = try decoder.decode(BackupData.self, from: payload)
            return replaceWithBackupData(backupData)
        } catch {
            logger.error("Sync import decode failed: \(error.localizedDescription)")
            return false
        }
    }

    private func replaceWithBackupData(_ backupData: BackupData) -> Bool {
        guard let memService = relationshipMemoryService, let refService = memoryReflectionService else { return false }

        memService.deleteAllMemories(includeArchived: true)
        refService.resetAll()

        for memory in backupData.relationshipMemories {
            memService.forceSave(
                memory.content,
                category: memory.category,
                source: "sync_import",
                importance: memory.importance,
                reasonSaved: memory.reasonSaved
            )
        }

        if let wfService = workflowDetectionService {
            for workflow in backupData.workflows {
                wfService.addWorkflow(workflow)
            }
        }

        if let linkService = memoryLinkService {
            for link in backupData.links {
                linkService.addLink(link)
            }
        }

        logger.info("Sync import complete: \(backupData.metadata.memoryCount) memories, \(backupData.metadata.reflectionCount) reflections, \(backupData.workflows.count) workflows, \(backupData.links.count) links")
        return true
    }

    // MARK: - Delete All Backups

    func deleteAllBackups() {
        let backups = listBackups()
        for backup in backups {
            let fileURL = backupDirectory.appending(path: backup.filename, directoryHint: .notDirectory)
            try? FileManager.default.removeItem(at: fileURL)
        }
        logger.info("Deleted \(backups.count) backup(s)")
    }

    func deleteBackup(filename: String) {
        let fileURL = backupDirectory.appending(path: filename, directoryHint: .notDirectory)
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Encryption (CryptoKit AES-GCM)

    private func encryptBackupData(_ data: Data) -> Data? {
        let key = ensureEncryptionKey()
        guard let sealedBox = try? AES.GCM.seal(data, using: key) else { return nil }

        var result = Data()
        result.append(magicHeader)
        var nonceData = Data(count: 12)
        nonceData.withUnsafeMutableBytes { dest in
            sealedBox.nonce.withUnsafeBytes { src in
                dest.copyMemory(from: src)
            }
        }
        result.append(nonceData)
        result.append(sealedBox.ciphertext)
        result.append(sealedBox.tag)
        return result
    }

    func decryptBackupData(_ data: Data) -> Data? {
        guard data.count > magicHeader.count + 12 + 16 else { return nil }
        guard data.prefix(magicHeader.count) == magicHeader else { return nil }

        let key = ensureEncryptionKey()
        var offset = magicHeader.count
        let nonceData = Data(data[offset..<offset + 12])
        offset += 12
        let tagData = Data(data[data.count - 16..<data.count])
        let ciphertext = Data(data[offset..<data.count - 16])

        guard let nonce = try? AES.GCM.Nonce(data: nonceData) else { return nil }

        let sealedBox = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tagData)
        guard let box = sealedBox, let decrypted = try? AES.GCM.open(box, using: key) else { return nil }

        return decrypted
    }

    // MARK: - Validation

    private func validateBackupData(_ data: Data) -> Bool {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logger.error("Backup is not valid JSON")
            return false
        }

        guard json["version"] != nil else {
            logger.error("Backup missing version key")
            return false
        }

        guard let memories = json["relationshipMemories"] as? [[String: Any]] else {
            logger.error("Backup missing relationshipMemories array")
            return false
        }

        for memory in memories {
            guard memory["id"] as? String != nil,
                  memory["content"] as? String != nil,
                  memory["category"] as? String != nil,
                  memory["createdAt"] as? String != nil
            else {
                logger.error("Backup memory missing required fields")
                return false
            }
        }

        guard let reflections = json["reflections"] as? [[String: Any]] else {
            logger.error("Backup missing reflections array")
            return false
        }

        for reflection in reflections {
            guard reflection["id"] as? String != nil,
                  reflection["type"] as? String != nil,
                  reflection["content"] as? String != nil,
                  reflection["createdAt"] as? String != nil
            else {
                logger.error("Backup reflection missing required fields")
                return false
            }
        }

        return true
    }
}

// MARK: - Keychain Helper (Data variant)

private enum BackupKeychainHelper {
    static func saveData(_ data: Data, account: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassKey,
            kSecAttrAccount: account,
            kSecAttrService: "com.alfred.app",
            kSecAttrKeyType: kSecAttrKeyTypeAES,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    static func loadData(account: String) -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassKey,
            kSecAttrAccount: account,
            kSecAttrService: "com.alfred.app",
            kSecAttrKeyType: kSecAttrKeyTypeAES,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }
}
