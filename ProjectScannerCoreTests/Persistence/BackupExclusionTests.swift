import Darwin
import Foundation
import XCTest
@testable import ProjectScannerCore

final class BackupExclusionTests: XCTestCase {
    func testStateDirectoryIsExcludedFromBackup() async throws {
        let fixture = try await StateStoreFixture.make(); defer { fixture.remove() }
        XCTAssertEqual(try fixture.stateDirectory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    func testBackupExclusionFollowsThePinnedDirectoryAcrossRename() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("backup-\(UUID())")
        let original = root.appendingPathComponent("original")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside"); try Data("unchanged".utf8).write(to: outside); let outsideBefore = try Data(contentsOf: outside)
        defer { try? FileManager.default.removeItem(at: root) }
        let descriptor = Darwin.open(original.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        defer { Darwin.close(descriptor) }
        var pinned = stat(); XCTAssertEqual(fstat(descriptor, &pinned), 0)
        try BackupExclusion.apply(pinnedDirectory: descriptor, state: SystemStateFileSystemOperations(), operations: ScriptedBackupExclusionOperations(mutation: .renameAfterReference))
        let moved = root.appendingPathComponent("renamed-pinned")
        var movedStatus = stat(); XCTAssertEqual(lstat(moved.path, &movedStatus), 0); XCTAssertEqual(movedStatus.st_ino, pinned.st_ino)
        XCTAssertEqual(try moved.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertEqual(try Data(contentsOf: outside), outsideBefore)
    }

    func testBackupExclusionRejectsReplacementBeforeFileReferenceValidation() async throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("replace-\(UUID())")
        let root = container.appendingPathComponent("pinned"); let outside = container.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); try Data("unchanged".utf8).write(to: outside); let before = try Data(contentsOf: outside)
        defer { try? FileManager.default.removeItem(at: container) }
        let descriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC); defer { Darwin.close(descriptor) }; var original = stat(); _ = fstat(descriptor, &original)
        XCTAssertThrowsError(try BackupExclusion.apply(pinnedDirectory: descriptor, state: SystemStateFileSystemOperations(), operations: ScriptedBackupExclusionOperations(mutation: .replaceBeforeReference))) {
            XCTAssertEqual($0 as? ProjectStateError, .backupExclusionFailed)
        }
        var replacement = stat(); _ = lstat(root.path, &replacement); var moved = stat(); _ = lstat(container.appendingPathComponent("original-pinned").path, &moved)
        XCTAssertNotEqual(replacement.st_ino, original.st_ino); XCTAssertEqual(moved.st_ino, original.st_ino); XCTAssertEqual(try Data(contentsOf: outside), before)
    }

    func testBackupExclusionFailureNeverTouchesOutsideCanary() async throws {
        for site in BackupResourceSite.allCases {
            let operations = ScriptedBackupExclusionOperations(failingSite: site)
            let container = FileManager.default.temporaryDirectory.appendingPathComponent("backup-fail-\(UUID())")
            let root = container.appendingPathComponent("pinned"); let outside = container.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("unchanged".utf8).write(to: outside); let before = try Data(contentsOf: outside); defer { try? FileManager.default.removeItem(at: container) }
            let descriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC); defer { Darwin.close(descriptor) }
            do {
                try BackupExclusion.apply(pinnedDirectory: descriptor, state: SystemStateFileSystemOperations(), operations: operations)
                XCTFail("Backup failure site \(site) was ignored")
            } catch {
                XCTAssertEqual(error as? ProjectStateError, .backupExclusionFailed)
                XCTAssertEqual(try Data(contentsOf: outside), before)
            }
        }
    }

    func testEachBackupResourceFailureIsInjectedAtTheNamedSite() async throws {
        for site in BackupResourceSite.allCases {
            let operations = ScriptedBackupExclusionOperations(failingSite: site)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("backup-matrix-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
            let descriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC); defer { Darwin.close(descriptor) }
            do {
                try BackupExclusion.apply(pinnedDirectory: descriptor, state: SystemStateFileSystemOperations(), operations: operations)
                XCTFail("Site did not fail")
            } catch {
                let events = operations.snapshot()
                let matches = events.indices.filter { events[$0] == site }
                XCTAssertEqual(matches.count, 1, "Injected backup site must be reached exactly once")
                if let index = matches.first {
                    XCTAssertTrue(events.dropFirst(index + 1).isEmpty, "Backup work continued after the injected failure")
                }
                XCTAssertEqual(error as? ProjectStateError, .backupExclusionFailed)
            }
        }
    }
}
