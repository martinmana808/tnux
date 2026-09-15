import Foundation
import Testing
@testable import CmuxWorkspaces

private struct SnapshotFixture: SessionSnapshotRepresenting, Equatable {
    struct Window: Codable, Equatable, Sendable {
        var name: String
    }

    var version: Int
    var windows: [Window]

    var hasWindows: Bool { !windows.isEmpty }
}

/// Injected clock so cadence and retention are deterministic.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) { current = start }

    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(by interval: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(interval)
    }
}

@Suite("SessionSnapshotRepository rolling backups")
struct SessionSnapshotBackupTests {
    private let schemaVersion = 1
    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-session-backup-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeRepository(
        appSupport: URL,
        clock: TestClock,
        policy: SessionSnapshotBackupPolicy = .default
    ) -> SessionSnapshotRepository<SnapshotFixture> {
        SessionSnapshotRepository(
            schemaVersion: schemaVersion,
            bundleIdentifier: "com.cmuxterm.tests",
            appSupportDirectory: appSupport,
            backupPolicy: policy,
            now: { clock.now() }
        )
    }

    private func snapshot(_ names: String...) -> SnapshotFixture {
        SnapshotFixture(version: schemaVersion, windows: names.map { .init(name: $0) })
    }

    @Test("the first primary save records a backup automatically")
    func firstPrimarySaveRecordsBackup() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock(epoch)
        let repository = makeRepository(appSupport: dir, clock: clock)

        #expect(repository.save(snapshot("alpha"), fileURL: nil))

        let backups = repository.listSessionBackups()
        #expect(backups.count == 1)
        let backup = try #require(backups.first)
        #expect(
            backup.fileURL.deletingLastPathComponent().resolvingSymlinksInPath().path
                == repository.sessionBackupsDirectoryURL()?.resolvingSymlinksInPath().path
        )
        #expect(abs(backup.recordedAt.timeIntervalSince(epoch)) < 1)
        #expect(repository.load(fileURL: backup.fileURL) == snapshot("alpha"))
    }

    @Test("changed saves inside the minimum interval do not add backups; later saves do")
    func backupCadenceFollowsMinimumInterval() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock(epoch)
        let policy = SessionSnapshotBackupPolicy(minimumInterval: 300)
        let repository = makeRepository(appSupport: dir, clock: clock, policy: policy)

        #expect(repository.save(snapshot("a"), fileURL: nil))
        clock.advance(by: 60)
        #expect(repository.save(snapshot("a", "b"), fileURL: nil))
        #expect(repository.listSessionBackups().count == 1, "60s after the first backup is inside the interval")

        clock.advance(by: 300)
        #expect(repository.save(snapshot("a", "b", "c"), fileURL: nil))
        let backups = repository.listSessionBackups()
        #expect(backups.count == 2)
        #expect(repository.load(fileURL: try #require(backups.first).fileURL) == snapshot("a", "b", "c"))
        #expect(repository.load(fileURL: try #require(backups.last).fileURL) == snapshot("a"))
    }

    @Test("identical saves and non-primary saves never record backups")
    func identicalAndNonPrimarySavesSkipBackups() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock(epoch)
        let repository = makeRepository(appSupport: dir, clock: clock, policy: SessionSnapshotBackupPolicy(minimumInterval: 0))

        #expect(repository.save(snapshot("a"), fileURL: nil))
        clock.advance(by: 10)
        #expect(repository.save(snapshot("a"), fileURL: nil))
        #expect(repository.listSessionBackups().count == 1, "identical content is not rewritten and not backed up")

        clock.advance(by: 10)
        let backupURL = try #require(repository.manualRestoreSnapshotFileURL())
        #expect(repository.save(snapshot("manual"), fileURL: backupURL))
        #expect(repository.listSessionBackups().count == 1, "the -previous file is not a primary save")
    }

    @Test("retention keeps everything recent, one per hour, then one per day")
    func retentionTiers() throws {
        let now = epoch
        let policy = SessionSnapshotBackupPolicy(
            minimumInterval: 0,
            keepAllWindow: 3 * 3600,
            hourlyWindow: 3 * 86_400,
            dailyWindow: 30 * 86_400
        )
        var dates: [Date] = []
        // Every 5 minutes for the last 3 hours: 36 entries, all kept.
        for step in 0..<36 { dates.append(now.addingTimeInterval(-Double(step) * 300)) }
        // Every 20 minutes between 3h and 3d: pruned to one per hour.
        var t = 3 * 3600 + 1200.0
        while t < 3 * 86_400 { dates.append(now.addingTimeInterval(-t)); t += 1200 }
        // Every 6 hours between 3d and 30d: pruned to one per day.
        t = 3 * 86_400 + 6 * 3600
        while t < 30 * 86_400 { dates.append(now.addingTimeInterval(-t)); t += 6 * 3600 }
        // Older than 30d: dropped.
        dates.append(now.addingTimeInterval(-31 * 86_400))
        dates.append(now.addingTimeInterval(-90 * 86_400))

        let retained = policy.retainedDates(from: dates.shuffled(), now: now)

        let recent = dates.filter { now.timeIntervalSince($0) < 3 * 3600 }
        #expect(recent.allSatisfy(retained.contains))
        let hourly = retained.filter { let age = now.timeIntervalSince($0); return age >= 3 * 3600 && age < 3 * 86_400 }
        let hourBuckets = Set(hourly.map { Int(($0.timeIntervalSince1970 / 3600).rounded(.down)) })
        #expect(hourly.count == hourBuckets.count, "at most one per hour")
        #expect(hourly.count >= 60 && hourly.count <= 70)
        let daily = retained.filter { let age = now.timeIntervalSince($0); return age >= 3 * 86_400 && age < 30 * 86_400 }
        let dayBuckets = Set(daily.map { Int(($0.timeIntervalSince1970 / 86_400).rounded(.down)) })
        #expect(daily.count == dayBuckets.count, "at most one per day")
        #expect(daily.count >= 26 && daily.count <= 28)
        #expect(!retained.contains(now.addingTimeInterval(-31 * 86_400)))
        #expect(!retained.contains(now.addingTimeInterval(-90 * 86_400)))
    }

    @Test("saving prunes backups on disk that fall outside the retention window")
    func saveTrimsExpiredBackupsOnDisk() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock(epoch)
        let policy = SessionSnapshotBackupPolicy(
            minimumInterval: 0,
            keepAllWindow: 600,
            hourlyWindow: 1200,
            dailyWindow: 1800
        )
        let repository = makeRepository(appSupport: dir, clock: clock, policy: policy)

        #expect(repository.save(snapshot("old"), fileURL: nil))
        clock.advance(by: 2000)
        #expect(repository.save(snapshot("new"), fileURL: nil))

        let backups = repository.listSessionBackups()
        #expect(backups.count == 1)
        #expect(repository.load(fileURL: try #require(backups.first).fileURL) == snapshot("new"))
    }

    @Test("backups are listed newest first")
    func listOrdersNewestFirst() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock(epoch)
        let repository = makeRepository(appSupport: dir, clock: clock, policy: SessionSnapshotBackupPolicy(minimumInterval: 0))

        for name in ["one", "two", "three"] {
            #expect(repository.save(snapshot(name), fileURL: nil))
            clock.advance(by: 60)
        }
        let recorded = repository.listSessionBackups().map(\.recordedAt)
        #expect(recorded == recorded.sorted(by: >))
        #expect(recorded.count == 3)
    }
}
