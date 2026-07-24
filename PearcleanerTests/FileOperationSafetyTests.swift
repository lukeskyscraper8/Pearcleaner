//
//  FileOperationSafetyTests.swift
//  PearcleanerTests
//
//  Added for the independently maintained Pearcleaner fork.
//

import Foundation
import XCTest
@testable import Pearcleaner

final class FileOperationSafetyTests: XCTestCase {
    func testProtectedFileOperationsNeverSelectDirectDispatcher() {
        XCTAssertEqual(
            fileOperationDispatchDecision(
                hasProtectedPaths: true
            ),
            .rejectProtected
        )
        XCTAssertEqual(
            fileOperationDispatchDecision(
                hasProtectedPaths: false
            ),
            .direct
        )
    }

    func testRootCLIFileOperationsAreRejected() {
        XCTAssertTrue(
            shouldRejectRootCLIFileOperation(
                isCLI: true,
                effectiveUserID: 0
            )
        )
        XCTAssertFalse(
            shouldRejectRootCLIFileOperation(
                isCLI: false,
                effectiveUserID: 0
            )
        )
        XCTAssertFalse(
            shouldRejectRootCLIFileOperation(
                isCLI: true,
                effectiveUserID: 501
            )
        )
        XCTAssertNotNil(cliRootTrashRefusalMessage(effectiveUserID: 0))
        XCTAssertNil(cliRootTrashRefusalMessage(effectiveUserID: 501))
    }

    func testManagedCLISymlinkValidationRequiresExpectedSymlinkTarget() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PearcleanerCLISymlink-\(UUID().uuidString)", isDirectory: true)
        let binDirectory = root.appendingPathComponent("bin", isDirectory: true)
        let executable = root.appendingPathComponent("Pearcleaner")
        let expectedLink = binDirectory.appendingPathComponent("pear")
        let wrongLink = binDirectory.appendingPathComponent("pear-wrong")
        let regularFile = binDirectory.appendingPathComponent("pear-file")
        try FileManager.default.createDirectory(
            at: binDirectory,
            withIntermediateDirectories: true
        )
        try Data().write(to: executable)
        try FileManager.default.createSymbolicLink(
            at: expectedLink,
            withDestinationURL: executable
        )
        try FileManager.default.createSymbolicLink(
            atPath: wrongLink.path,
            withDestinationPath: "../OtherExecutable"
        )
        try Data().write(to: regularFile)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertTrue(
            managedCLISymlinkMatchesExecutable(
                at: expectedLink.path,
                executablePath: executable.path
            )
        )
        XCTAssertFalse(
            managedCLISymlinkMatchesExecutable(
                at: wrongLink.path,
                executablePath: executable.path
            )
        )
        XCTAssertFalse(
            managedCLISymlinkMatchesExecutable(
                at: regularFile.path,
                executablePath: executable.path
            )
        )
    }

    func testPrivilegedCLISymlinkAncestryRejectsWritableOrSymlinkedDirectories() {
        let root = URL(fileURLWithPath: "/")
        let local = URL(fileURLWithPath: "/usr/local")
        let bin = URL(fileURLWithPath: "/usr/local/bin")
        let directories = [root, local, bin]
        let allPaths = Set(directories.map(\.path))

        XCTAssertTrue(
            cliSymlinkAncestryAllowsPrivilege(
                directories,
                isRealDirectory: { allPaths.contains($0.path) },
                isWritable: { _ in false }
            )
        )
        XCTAssertFalse(
            cliSymlinkAncestryAllowsPrivilege(
                directories,
                isRealDirectory: { $0 != local },
                isWritable: { _ in false }
            )
        )
        XCTAssertFalse(
            cliSymlinkAncestryAllowsPrivilege(
                directories,
                isRealDirectory: { _ in true },
                isWritable: { $0 == local }
            )
        )
    }

    func testDeletionResultReportsPartialOutcome() {
        let first = URL(fileURLWithPath: "/tmp/pearcleaner-first")
        let second = URL(fileURLWithPath: "/tmp/pearcleaner-second")
        let result = FileDeletionResult(
            requestedURLs: [first, second],
            movedURLs: [first],
            failedURLs: [second]
        )

        XCTAssertFalse(result.allSucceeded)
        XCTAssertTrue(result.isPartial)
        XCTAssertEqual(result.movedURLs, [first])
        XCTAssertEqual(result.failedURLs, [second])
    }

    func testRestoreRefusesToOverwriteExistingDestination() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PearcleanerRestoreTest-\(UUID().uuidString)", isDirectory: true)
        let trashRoot = root.appendingPathComponent(".Trash", isDirectory: true)
        let trashDirectory = trashRoot.appendingPathComponent(
            "Pearcleaner_2026-07-24_12-34-56_A1B2C3D4",
            isDirectory: true
        )
        let originalDirectory = root.appendingPathComponent("Original", isDirectory: true)
        try FileManager.default.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: originalDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let trashedURL = trashDirectory.appendingPathComponent("Example.txt")
        let originalURL = originalDirectory.appendingPathComponent("Example.txt")
        try Data("older trashed copy".utf8).write(to: trashedURL)
        try Data("new replacement".utf8).write(to: originalURL)

        let restored = FileManagerUndo.shared.restoreFiles(filePairs: [
            (trashURL: trashedURL, originalURL: originalURL)
        ], trashRoot: trashRoot)

        XCTAssertFalse(restored)
        XCTAssertEqual(try String(contentsOf: originalURL, encoding: .utf8), "new replacement")
        XCTAssertEqual(try String(contentsOf: trashedURL, encoding: .utf8), "older trashed copy")
    }

    func testRestoreRollsBackEarlierMovesWhenLaterMoveFails() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PearcleanerRestoreRollback-\(UUID().uuidString)", isDirectory: true)
        let trashRoot = root.appendingPathComponent(".Trash", isDirectory: true)
        let trashDirectory = trashRoot.appendingPathComponent(
            "Pearcleaner_2026-07-24_12-34-56_A1B2C3D4",
            isDirectory: true
        )
        let originalDirectory = root.appendingPathComponent("Original", isDirectory: true)
        try FileManager.default.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: originalDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let firstTrashURL = trashDirectory.appendingPathComponent("First.txt")
        let secondTrashURL = trashDirectory.appendingPathComponent("Second.txt")
        let firstOriginalURL = originalDirectory.appendingPathComponent("First.txt")
        let secondOriginalURL = originalDirectory
            .appendingPathComponent("MissingParent", isDirectory: true)
            .appendingPathComponent("Second.txt")
        try Data("first".utf8).write(to: firstTrashURL)
        try Data("second".utf8).write(to: secondTrashURL)

        let restored = FileManagerUndo.shared.restoreFiles(
            filePairs: [
                (trashURL: firstTrashURL, originalURL: firstOriginalURL),
                (trashURL: secondTrashURL, originalURL: secondOriginalURL)
            ],
            isCLI: true,
            trashRoot: trashRoot
        )

        XCTAssertFalse(restored)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstTrashURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondTrashURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstOriginalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondOriginalURL.path))
    }

    func testDeletionNormalizationDropsDescendantsInEitherSelectionOrder() {
        let parent = URL(fileURLWithPath: "/tmp/PearcleanerDelete/Parent", isDirectory: true)
        let child = parent.appendingPathComponent("Child.txt")
        let directoryPaths: Set<String> = [parent.path]
        let isDirectory: (URL) -> Bool = { directoryPaths.contains($0.path) }

        XCTAssertEqual(
            normalizedDeletionURLs([parent, child], isDirectory: isDirectory),
            [parent]
        )
        XCTAssertEqual(
            normalizedDeletionURLs([child, parent], isDirectory: isDirectory),
            [parent]
        )
    }

    func testTrashBundlePathIgnoresUntrustedDisplayName() {
        let trashRoot = URL(fileURLWithPath: "/tmp/PearcleanerSafeTrash/.Trash", isDirectory: true)
        let hostileNames = [
            "../Outside",
            "../../Library/Evil",
            "/Applications",
            "Nested/Folder",
            "Control\u{000A}Name"
        ]

        for displayName in hostileNames {
            let bundleURL = makeTrashBundleURL(
                trashRoot: trashRoot,
                displayName: displayName,
                timestamp: "2026-07-24_12-34-56",
                operationSuffix: "A1B2C3D4"
            )
            XCTAssertEqual(bundleURL?.deletingLastPathComponent(), trashRoot.standardizedFileURL)
            XCTAssertEqual(
                bundleURL?.lastPathComponent,
                "Pearcleaner_2026-07-24_12-34-56_A1B2C3D4"
            )
        }
    }

    func testTrashBundleCleanupValidationRequiresDirectGeneratedChild() {
        let trashRoot = URL(fileURLWithPath: "/tmp/PearcleanerSafeTrash/.Trash", isDirectory: true)
        let valid = trashRoot.appendingPathComponent(
            "Pearcleaner_2026-07-24_12-34-56_A1B2C3D4",
            isDirectory: true
        )
        let nested = trashRoot
            .appendingPathComponent("Nested", isDirectory: true)
            .appendingPathComponent(valid.lastPathComponent, isDirectory: true)
        let loose = trashRoot.appendingPathComponent("Some_folder", isDirectory: true)

        XCTAssertTrue(isGeneratedTrashBundleFolder(valid, trashRoot: trashRoot))
        XCTAssertFalse(isGeneratedTrashBundleFolder(nested, trashRoot: trashRoot))
        XCTAssertFalse(isGeneratedTrashBundleFolder(loose, trashRoot: trashRoot))
    }

    func testDuplicateTrashNamesRemainDistinctAndRestoreAllBytes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PearcleanerDuplicateTrash-\(UUID().uuidString)", isDirectory: true)
        let trashRoot = root.appendingPathComponent(".Trash", isDirectory: true)
        let trashDirectory = trashRoot.appendingPathComponent(
            "Pearcleaner_2026-07-24_12-34-56_A1B2C3D4",
            isDirectory: true
        )
        let originalRoot = root.appendingPathComponent("Original", isDirectory: true)
        try FileManager.default.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: originalRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let originals = [
            originalRoot.appendingPathComponent("A/foo"),
            originalRoot.appendingPathComponent("B/foo-1"),
            originalRoot.appendingPathComponent("C/foo")
        ]
        for original in originals {
            try FileManager.default.createDirectory(
                at: original.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }

        var reservedNames = Set<String>()
        let plannedNames = originals.map {
            reserveUniqueTrashLeafName(
                for: $0.lastPathComponent,
                reservedNames: &reservedNames,
                destinationExists: { _ in false }
            )
        }
        XCTAssertEqual(plannedNames, ["foo", "foo-1", "foo-2"])

        let expectedContents = ["first foo", "literal foo-1", "second foo"]
        var pairs: [(trashURL: URL, originalURL: URL)] = []
        for (original, planned) in zip(originals, zip(plannedNames, expectedContents)) {
            let trashURL = trashDirectory.appendingPathComponent(planned.0)
            try Data(planned.1.utf8).write(to: trashURL)
            pairs.append((trashURL: trashURL, originalURL: original))
        }

        XCTAssertTrue(
            FileManagerUndo.shared.restoreFiles(
                filePairs: pairs,
                isCLI: true,
                trashRoot: trashRoot
            )
        )
        for (original, expectedContent) in zip(originals, expectedContents) {
            XCTAssertEqual(
                try String(contentsOf: original, encoding: .utf8),
                expectedContent
            )
        }
    }

    func testFileSearchUndoMatchesCoalescedParentAndChildSelection() {
        let parent = "/tmp/PearcleanerFileSearch/Parent"
        let child = "\(parent)/Child.txt"
        let unrelated = "/tmp/PearcleanerFileSearch/Other.txt"

        XCTAssertEqual(
            matchingFileSearchUndoActionIndex(
                actionPaths: [[unrelated], [parent, child]],
                restoredPaths: [parent, child]
            ),
            1
        )
    }

    func testUndoHistoryDecodeRejectsMalformedFilePairs() throws {
        let malformedPairs = [
            "[]",
            "[\"only-one-path\"]",
            "[\"original\", \"trashed\", \"unexpected\"]"
        ]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for malformedPair in malformedPairs {
            let json = """
            {
              "id": "\(UUID().uuidString)",
              "timestamp": "2026-07-24T12:00:00Z",
              "appName": "Example",
              "bundleFolderPath": "/tmp/Trash/Example",
              "filePairs": [\(malformedPair)],
              "fileCount": 1
            }
            """

            XCTAssertThrowsError(
                try decoder.decode(UndoHistoryRecord.self, from: Data(json.utf8)),
                "Expected malformed pair \(malformedPair) to be rejected"
            )
        }
    }

    func testPersistedUndoHistoryRejectsTrashSourceOutsideRecordedBundle() {
        let trashRoot = URL(fileURLWithPath: "/tmp/PearcleanerHistory/.Trash", isDirectory: true)
        let bundle = trashRoot.appendingPathComponent(
            "Pearcleaner_2026-07-24_12-34-56_A1B2C3D4",
            isDirectory: true
        )
        let record = UndoHistoryRecord(
            timestamp: Date(),
            appName: "Forged",
            bundleFolderPath: bundle.path,
            filePairs: [
                ("/tmp/original", "/tmp/attacker-controlled-source")
            ],
            fileCount: 1
        )

        XCTAssertNil(
            validatedUndoHistoryRestorePairs(
                record,
                trashRoot: trashRoot,
                isDirectory: { $0 == trashRoot || $0 == bundle }
            )
        )
    }

    func testBackgroundDeletionRegistersUndoOnMainThread() async {
        let manager = FileManagerUndo.shared
        await MainActor.run {
            manager.undoManager.removeAllActions()
        }

        let pair = (
            trashURL: URL(
                fileURLWithPath:
                    "/tmp/.Trash/Pearcleaner_2026-07-24_12-34-56_A1B2C3D4/Example.txt"
            ),
            originalURL: URL(fileURLWithPath: "/tmp/Original/Example.txt")
        )
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                manager.registerDeletionUndo(
                    filePairs: [pair],
                    restoredRequestedURLs: [pair.originalURL]
                )
                continuation.resume()
            }
        }

        let canUndo = await MainActor.run {
            manager.undoManager.canUndo
        }
        XCTAssertTrue(canUndo)

        await MainActor.run {
            manager.undoManager.removeAllActions()
        }
    }

    func testRenameValidationRejectsTraversalAndSeparators() {
        let source = URL(fileURLWithPath: "/tmp/PearcleanerRename/Original.txt")

        for invalidName in ["", "   ", ".", "..", "../Outside.txt", "folder/file.txt", "bad\0name"] {
            let result = validatedFileSearchRenameDestination(
                sourceURL: source,
                newName: invalidName,
                destinationExists: { _ in false }
            )
            XCTAssertEqual(result, .failure(.invalidName), "Expected rejection for \(invalidName.debugDescription)")
        }
    }

    func testRenameValidationRejectsExistingDestination() {
        let source = URL(fileURLWithPath: "/tmp/PearcleanerRename/Original.txt")
        let result = validatedFileSearchRenameDestination(
            sourceURL: source,
            newName: "Existing.txt",
            destinationExists: { _ in true }
        )

        XCTAssertEqual(result, .failure(.destinationExists))
    }

    func testRenameValidationKeepsDestinationInParent() throws {
        let source = URL(fileURLWithPath: "/tmp/PearcleanerRename/Original.txt")
        let result = validatedFileSearchRenameDestination(
            sourceURL: source,
            newName: "Renamed.txt",
            destinationExists: { _ in false }
        )

        let destination = try result.get()
        XCTAssertEqual(destination.path, "/tmp/PearcleanerRename/Renamed.txt")
    }

    func testTranslationPruneRequiresWritableBundleTargetsAndParents() {
        let app = URL(
            fileURLWithPath: "/tmp/PearcleanerTranslationTest/Example.app",
            isDirectory: true
        )
        let french = app.appendingPathComponent(
            "Contents/Resources/fr.lproj",
            isDirectory: true
        )
        let german = app.appendingPathComponent(
            "Contents/PlugIns/Example.bundle/Contents/Resources/de.lproj",
            isDirectory: true
        )
        let requiredURLs = [
            app,
            french,
            french.deletingLastPathComponent(),
            german,
            german.deletingLastPathComponent()
        ]
        let allWritablePaths = Set(
            requiredURLs.map { $0.standardizedFileURL.path }
        )

        XCTAssertTrue(
            translationPruneTargetsAreUserWritable(
                [french, german],
                in: app,
                isWritable: {
                    allWritablePaths.contains($0.standardizedFileURL.path)
                }
            )
        )

        for blockedURL in requiredURLs {
            let blockedPath = blockedURL.standardizedFileURL.path
            XCTAssertFalse(
                translationPruneTargetsAreUserWritable(
                    [french, german],
                    in: app,
                    isWritable: {
                        let path = $0.standardizedFileURL.path
                        return path != blockedPath && allWritablePaths.contains(path)
                    }
                ),
                "Expected a non-writable path to block pruning: \(blockedPath)"
            )
        }
    }
}
