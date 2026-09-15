public import Foundation
#if DEBUG
internal import CMUXDebugLog
#endif

/// File-backed store for the app session snapshot.
///
/// Faithful lift of the legacy `SessionPersistenceStore` namespace enum from
/// `Sources/SessionPersistence.swift`: JSON encode/decode (sorted keys),
/// atomic writes with identical-content skip, the primary/`-previous` backup
/// pair under `Application Support/cmux/`, and the unusable-primary recovery
/// path are unchanged. The legacy per-call `bundleIdentifier`/
/// `appSupportDirectory`/`FileManager` defaulted parameters became
/// constructor-injected state (they were constant per process), and the
/// schema version the legacy code read from `SessionSnapshotSchema` is
/// injected as `schemaVersion`.
///
/// Isolation: a stateless `Sendable` struct, not an actor. Every method is
/// synchronous because its callers are: `applicationWillTerminate` must
/// complete the save before returning, and the autosave path already hops to
/// a private serial queue app-side. There is no mutable state to protect.
public struct SessionSnapshotRepository<SnapshotValue: SessionSnapshotRepresenting>: SessionSnapshotStoring {
    private let schemaVersion: Int
    private let bundleIdentifier: String?
    private let appSupportDirectory: URL?
    // Justification: FileManager is documented thread-safe ("the methods of
    // the shared FileManager object can be called from multiple threads
    // safely") but Foundation does not mark it Sendable.
    private nonisolated(unsafe) let fileManager: FileManager
    private let backupPolicy: SessionSnapshotBackupPolicy
    private let now: @Sendable () -> Date

    /// Creates a repository.
    ///
    /// - Parameters:
    ///   - schemaVersion: The current snapshot schema version; persisted
    ///     snapshots with any other version are unusable.
    ///   - bundleIdentifier: The bundle identifier used to derive the
    ///     snapshot file name (pass `Bundle.main.bundleIdentifier` at the
    ///     composition root). Falls back to `com.cmuxterm.app` when nil or
    ///     blank.
    ///   - appSupportDirectory: Overrides the discovered user Application
    ///     Support directory (tests pass a temporary directory).
    ///   - fileManager: File system access, injected for testability.
    ///   - backupPolicy: Cadence and retention for rolling snapshot backups.
    ///   - now: Clock used to stamp and prune backups (tests inject a fixed
    ///     or advancing clock).
    public init(
        schemaVersion: Int,
        bundleIdentifier: String?,
        appSupportDirectory: URL? = nil,
        fileManager: FileManager = .default,
        backupPolicy: SessionSnapshotBackupPolicy = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.schemaVersion = schemaVersion
        self.bundleIdentifier = bundleIdentifier
        self.appSupportDirectory = appSupportDirectory
        self.fileManager = fileManager
        self.backupPolicy = backupPolicy
        self.now = now
    }

    public func loadOutcome(fileURL: URL) -> SessionSnapshotLoadOutcome<SnapshotValue> {
        guard fileManager.fileExists(atPath: fileURL.path) else { return .missing }
        guard let data = try? Data(contentsOf: fileURL) else { return .unusable }
        let decoder = JSONDecoder()
        guard let snapshot = try? decoder.decode(SnapshotValue.self, from: data) else { return .unusable }
        guard snapshot.version == schemaVersion else { return .unusable }
        guard snapshot.hasWindows else { return .unusable }
        return .loaded(snapshot)
    }

    public func load(fileURL: URL? = nil) -> SnapshotValue? {
        guard let fileURL = fileURL ?? defaultSnapshotFileURL() else { return nil }
        guard case .loaded(let snapshot) = loadOutcome(fileURL: fileURL) else { return nil }
        return snapshot
    }

    @discardableResult
    public func save(_ snapshot: SnapshotValue, fileURL: URL? = nil) -> Bool {
        guard let fileURL = fileURL ?? defaultSnapshotFileURL() else { return false }
        let directory = fileURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
            let data = try encodedSnapshotData(snapshot)
            if let existingData = try? Data(contentsOf: fileURL), existingData == data {
                return true
            }
            try data.write(to: fileURL, options: .atomic)
            if isPrimarySnapshotFileURL(fileURL) {
                recordBackupIfDue(data: data)
            }
            return true
        } catch {
            return false
        }
    }

    // MARK: - Rolling backups

    /// Directory holding rolling backups of the primary snapshot for this
    /// bundle identifier, or nil when Application Support cannot be resolved.
    public func sessionBackupsDirectoryURL() -> URL? {
        guard let primary = defaultSnapshotFileURL() else { return nil }
        return primary
            .deletingLastPathComponent()
            .appendingPathComponent("session-backups", isDirectory: true)
            .appendingPathComponent(sanitizedBundleIdentifier, isDirectory: true)
    }

    /// Rolling backups on disk, newest first.
    public func listSessionBackups() -> [SessionSnapshotBackup] {
        guard let directory = sessionBackupsDirectoryURL(),
              let contents = try? fileManager.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles]
              ) else {
            return []
        }
        return contents
            .compactMap { url -> SessionSnapshotBackup? in
                guard url.pathExtension == "json",
                      let recordedAt = SessionSnapshotBackupFileName.date(from: url.deletingPathExtension().lastPathComponent) else {
                    return nil
                }
                return SessionSnapshotBackup(fileURL: url, recordedAt: recordedAt)
            }
            .sorted { $0.recordedAt > $1.recordedAt }
    }

    private func isPrimarySnapshotFileURL(_ fileURL: URL) -> Bool {
        guard let primary = defaultSnapshotFileURL() else { return false }
        return primary.standardizedFileURL.path == fileURL.standardizedFileURL.path
    }

    /// Writes `data` as a new backup when the newest backup is older than the
    /// policy's minimum interval (or none exists), then prunes per the policy.
    /// Failures are swallowed: backups must never make the primary save fail.
    private func recordBackupIfDue(data: Data) {
        guard let directory = sessionBackupsDirectoryURL() else { return }
        let currentDate = now()
        let existing = listSessionBackups()
        if let newest = existing.first,
           currentDate.timeIntervalSince(newest.recordedAt) < backupPolicy.minimumInterval {
            return
        }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
            let fileURL = directory.appendingPathComponent(
                SessionSnapshotBackupFileName.string(for: currentDate) + ".json",
                isDirectory: false
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            return
        }
        pruneBackups(now: currentDate)
    }

    private func pruneBackups(now currentDate: Date) {
        let backups = listSessionBackups()
        let retained = backupPolicy.retainedDates(from: backups.map(\.recordedAt), now: currentDate)
        for backup in backups where !retained.contains(backup.recordedAt) {
            try? fileManager.removeItem(at: backup.fileURL)
        }
    }


    private func encodedSnapshotData(_ snapshot: SnapshotValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(snapshot)
    }

    public func removeSnapshot(fileURL: URL? = nil) {
        guard let fileURL = fileURL ?? defaultSnapshotFileURL() else { return }
        try? fileManager.removeItem(at: fileURL)
    }

    public func loadReopenSessionSnapshot(fileURL: URL? = nil) -> SnapshotValue? {
        guard let fileURL = fileURL ?? manualRestoreSnapshotFileURL() else {
            return nil
        }
        return load(fileURL: fileURL)
    }

    public func syncManualRestoreSnapshotCache() {
        guard let backupURL = manualRestoreSnapshotFileURL() else { return }
        guard let primaryURL = defaultSnapshotFileURL() else { return }
        switch loadOutcome(fileURL: primaryURL) {
        case .loaded(let snapshot):
            _ = save(snapshot, fileURL: backupURL)
        case .missing:
            removeSnapshot(fileURL: backupURL)
        case .unusable:
            // The primary snapshot exists but cannot be restored. Keep the
            // backup: it is the only remaining recovery path for the user's
            // sessions (startup fallback and `cmux restore-session`).
            break
        }
    }

    public func loadStartupSnapshot() -> SnapshotValue? {
        guard let primaryURL = defaultSnapshotFileURL() else { return nil }
        switch loadOutcome(fileURL: primaryURL) {
        case .loaded(let snapshot):
            return snapshot
        case .missing:
            return nil
        case .unusable:
            let backup = loadReopenSessionSnapshot(fileURL: nil)
#if DEBUG
            CMUXDebugLog.logDebugEvent(
                "session.restore.primaryUnusable path=\(primaryURL.path) " +
                    "backupRecovered=\(backup != nil ? 1 : 0)"
            )
#endif
            return backup
        }
    }

    public func defaultSnapshotFileURL() -> URL? {
        snapshotFileURL(suffix: "")
    }

    public func manualRestoreSnapshotFileURL() -> URL? {
        snapshotFileURL(suffix: "-previous")
    }

    private func snapshotFileURL(suffix: String) -> URL? {
        let resolvedAppSupport: URL
        if let appSupportDirectory {
            resolvedAppSupport = appSupportDirectory
        } else if let discovered = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            resolvedAppSupport = discovered
        } else {
            return nil
        }
        return resolvedAppSupport
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("session-\(sanitizedBundleIdentifier)\(suffix).json", isDirectory: false)
    }

    private var sanitizedBundleIdentifier: String {
        let bundleId = (bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? bundleIdentifier!
            : "com.cmuxterm.app"
        return bundleId.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "_",
            options: .regularExpression
        )
    }
}
