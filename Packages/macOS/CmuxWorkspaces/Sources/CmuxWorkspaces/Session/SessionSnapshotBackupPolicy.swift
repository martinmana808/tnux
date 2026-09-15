public import Foundation

/// Retention rules for the rolling, timestamped copies of the primary session
/// snapshot that ``SessionSnapshotRepository`` writes on autosave.
///
/// The single `-previous` file only survives one bad relaunch. Rolling backups
/// give the user a way back to a known-good layout after a restart that came
/// up empty or cross-wired, without any manual step: the primary autosave
/// path records a backup whenever the newest one is older than
/// `minimumInterval`, then prunes with three tiers so disk use stays bounded
/// (roughly 36 + 72 + 30 files at the defaults).
public struct SessionSnapshotBackupPolicy: Sendable, Equatable {
    /// Minimum age of the newest backup before another one is recorded.
    public var minimumInterval: TimeInterval
    /// Backups younger than this are all kept.
    public var keepAllWindow: TimeInterval
    /// Between `keepAllWindow` and this age, one backup per hour is kept.
    public var hourlyWindow: TimeInterval
    /// Between `hourlyWindow` and this age, one backup per day is kept.
    public var dailyWindow: TimeInterval

    public init(
        minimumInterval: TimeInterval = 5 * 60,
        keepAllWindow: TimeInterval = 3 * 60 * 60,
        hourlyWindow: TimeInterval = 3 * 24 * 60 * 60,
        dailyWindow: TimeInterval = 30 * 24 * 60 * 60
    ) {
        self.minimumInterval = minimumInterval
        self.keepAllWindow = keepAllWindow
        self.hourlyWindow = hourlyWindow
        self.dailyWindow = dailyWindow
    }

    public static let `default` = SessionSnapshotBackupPolicy()

    /// Returns the subset of `dates` (any order) that the policy retains as of
    /// `now`. Ties inside an hourly or daily bucket keep the newest entry.
    public func retainedDates(from dates: [Date], now: Date) -> Set<Date> {
        var retained: Set<Date> = []
        var hourBuckets: Set<Int> = []
        var dayBuckets: Set<Int> = []
        for date in dates.sorted(by: >) {
            let age = now.timeIntervalSince(date)
            if age < keepAllWindow {
                retained.insert(date)
            } else if age < hourlyWindow {
                let bucket = Int((date.timeIntervalSince1970 / 3600).rounded(.down))
                if hourBuckets.insert(bucket).inserted {
                    retained.insert(date)
                }
            } else if age < dailyWindow {
                let bucket = Int((date.timeIntervalSince1970 / 86_400).rounded(.down))
                if dayBuckets.insert(bucket).inserted {
                    retained.insert(date)
                }
            }
        }
        return retained
    }
}

/// One rolling backup of the session snapshot on disk.
public struct SessionSnapshotBackup: Sendable, Equatable, Identifiable {
    public var id: URL { fileURL }
    public let fileURL: URL
    /// When the backup was recorded (parsed from the file name).
    public let recordedAt: Date

    public init(fileURL: URL, recordedAt: Date) {
        self.fileURL = fileURL
        self.recordedAt = recordedAt
    }
}

/// Backup file names carry a sortable local-time stamp so the user can pick
/// one by eye in an open panel: `2026-09-15_17-42-08`.
public enum SessionSnapshotBackupFileName {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter
    }()

    // Justification: DateFormatter is documented thread-safe on macOS 10.12+;
    // Foundation just does not mark it Sendable.
    public static func string(for date: Date) -> String {
        formatter.string(from: date)
    }

    public static func date(from name: String) -> Date? {
        formatter.date(from: name)
    }
}
