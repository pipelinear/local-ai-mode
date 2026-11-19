import Foundation

enum SessionStoreError: LocalizedError, Equatable {
    case sessionAlreadyActive
    case noActiveSession

    var errorDescription: String? {
        switch self {
        case .sessionAlreadyActive:
            return "An AI Mode session is already recorded. The original workspace snapshot will not be overwritten."
        case .noActiveSession:
            return "There is no recorded AI Mode session."
        }
    }
}

/// Persists the session journal and the last completed snapshot as JSON files in Application Support.
/// All writes are atomic (`Data.write(options: .atomic)`) so an interrupted write never leaves a corrupt journal.
final class SessionStore: @unchecked Sendable {
    let directory: URL
    private let lock = NSLock()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    var journalURL: URL { directory.appendingPathComponent("session-journal.json") }
    var lastSnapshotURL: URL { directory.appendingPathComponent("last-snapshot.json") }

    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("LocalAIMode", isDirectory: true)
    }

    init(directory: URL = SessionStore.defaultDirectory()) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }

    // MARK: Journal

    func loadJournal() -> SessionJournal? {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: journalURL) else { return nil }
        return try? decoder.decode(SessionJournal.self, from: data)
    }

    /// Whether a journal file exists on disk but cannot be decoded.
    var hasCorruptJournal: Bool {
        FileManager.default.fileExists(atPath: journalURL.path) && loadJournal() == nil
    }

    /// Starts a new session. Refuses to overwrite an existing journal so the original snapshot is never lost.
    @discardableResult
    func beginSession(snapshot: WorkspaceSnapshot, model: String?) throws -> SessionJournal {
        if loadJournal() != nil { throw SessionStoreError.sessionAlreadyActive }
        let journal = SessionJournal(phase: .activating, snapshot: snapshot, requestedModel: model)
        try write(journal)
        return journal
    }

    /// Applies a mutation to the recorded journal and saves it.
    @discardableResult
    func update(_ mutate: (inout SessionJournal) -> Void) throws -> SessionJournal {
        guard var journal = loadJournal() else { throw SessionStoreError.noActiveSession }
        let originalSnapshotID = journal.snapshot.id
        mutate(&journal)
        // Defensive: the snapshot identity can never be replaced mid-session.
        precondition(journal.snapshot.id == originalSnapshotID, "Session snapshot must not be replaced")
        journal.updatedAt = Date()
        try write(journal)
        return journal
    }

    /// Ends the session, keeping a copy of the snapshot for Emergency Workspace Restore.
    func endSession() {
        lock.lock(); defer { lock.unlock() }
        if let data = try? Data(contentsOf: journalURL),
           let journal = try? decoder.decode(SessionJournal.self, from: data),
           let snap = try? encoder.encode(journal.snapshot) {
            try? snap.write(to: lastSnapshotURL, options: .atomic)
        }
        try? FileManager.default.removeItem(at: journalURL)
    }

    /// Discards a journal that cannot be decoded (moved aside, not deleted, for inspection).
    func quarantineCorruptJournal() {
        let dest = directory.appendingPathComponent("session-journal.corrupt-\(Int(Date().timeIntervalSince1970)).json")
        try? FileManager.default.moveItem(at: journalURL, to: dest)
    }

    func loadLastSnapshot() -> WorkspaceSnapshot? {
        guard let data = try? Data(contentsOf: lastSnapshotURL) else { return nil }
        return try? decoder.decode(WorkspaceSnapshot.self, from: data)
    }

    private func write(_ journal: SessionJournal) throws {
        lock.lock(); defer { lock.unlock() }
        let data = try encoder.encode(journal)
        try data.write(to: journalURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
    }
}

/// Decides what to offer at launch based on the journal left on disk.
enum RecoveryAssessment: Equatable {
    case clean
    /// A previous process left an unfinished session (crash, restart, force quit).
    case interrupted(SessionJournal)
    /// AI Mode was exited without restoring apps.
    case restorePending(SessionJournal)
    case corrupt

    static func assess(store: SessionStore) -> RecoveryAssessment {
        if store.hasCorruptJournal { return .corrupt }
        guard let journal = store.loadJournal() else { return .clean }
        if journal.phase == .restorePending { return .restorePending(journal) }
        return .interrupted(journal)
    }
}
