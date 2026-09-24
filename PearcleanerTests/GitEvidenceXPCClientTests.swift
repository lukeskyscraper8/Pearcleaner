import Foundation
import GitEvidenceShared
import ObjectiveC
import Security
import XCTest
@testable import Pearcleaner

final class GitEvidenceXPCClientTests: XCTestCase {
    func testServiceIdentityPinsBundleIDAndTeam() {
        XCTAssertEqual(
            GitEvidenceServiceIdentity.serviceBundleIdentifier,
            "com.lukerow.Pearcleaner.GitEvidenceService"
        )
        XCTAssertTrue(
            GitEvidenceServiceIdentity.serviceRequirement.contains(
                #"identifier "com.lukerow.Pearcleaner.GitEvidenceService""#
            )
        )
        XCTAssertTrue(GitEvidenceServiceIdentity.serviceRequirement.contains("68583N3MNF"))
        XCTAssertTrue(
            GitEvidenceServiceIdentity.acceptedClientRequirements.contains(
                GitEvidenceServiceIdentity.pearcleanerClientRequirement
            )
        )
    }

    func testCombinedClientRequirementParsesAndCoversEveryClient() {
        let combined = GitEvidenceServiceIdentity.acceptedClientRequirement
        for requirement in GitEvidenceServiceIdentity.acceptedClientRequirements {
            XCTAssertTrue(combined.contains("(\(requirement))"))
        }

        var parsed: SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString(combined as CFString, [], &parsed), errSecSuccess)
        XCTAssertNotNil(parsed)
    }

    func testGitLaunchPathFollowsAllowlistedSelection() throws {
        let link = FileManager.default.temporaryDirectory
            .appendingPathComponent("xcode_select_link-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: link) }
        try FileManager.default.createSymbolicLink(
            atPath: link,
            withDestinationPath: "/Applications/Xcode.app/Contents/Developer"
        )

        XCTAssertEqual(
            GitRunnerInvocation.resolvedGitLaunchPath(selectionLink: link, isExecutable: { _ in true }),
            "/Applications/Xcode.app/Contents/Developer/usr/bin/git"
        )
    }

    func testGitLaunchPathIgnoresUnlistedSelectionAndFallsBackInOrder() throws {
        let link = FileManager.default.temporaryDirectory
            .appendingPathComponent("xcode_select_link-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: link) }
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "/tmp/Evil.app/Contents/Developer")

        XCTAssertEqual(
            GitRunnerInvocation.resolvedGitLaunchPath(selectionLink: link, isExecutable: { _ in true }),
            "/Library/Developer/CommandLineTools/usr/bin/git"
        )
        XCTAssertNil(GitRunnerInvocation.resolvedGitLaunchPath(selectionLink: link, isExecutable: { _ in false }))
        XCTAssertFalse(GitRunnerInvocation.gitLaunchPathCandidates.contains("/usr/bin/git"))
    }

    func testXPCRequestRoundTripsWithoutPathMetadata() throws {
        let identity = GitEvidenceXPCFileIdentity(
            device: 1,
            inode: 2,
            size: 3,
            mode: 0o100644,
            modificationSeconds: 4,
            modificationNanoseconds: 5,
            statusChangeSeconds: 6,
            statusChangeNanoseconds: 7
        )

        let request = try GitEvidenceXPCRequest(
            operation: .listCachedPaths,
            headObjectID: GitEvidenceXPCObjectID(algorithm: .sha1, hex: "abc"),
            repositoryFormatVersion: 0,
            objectHashAlgorithm: .sha1,
            transferredDescriptors: []
        )

        let data = try NSKeyedArchiver.archivedData(
            withRootObject: request,
            requiringSecureCoding: true
        )
        let decoded = try NSKeyedUnarchiver.unarchivedObject(
            ofClass: GitEvidenceXPCRequest.self,
            from: data
        )
        let roundTripped = try XCTUnwrap(decoded)

        XCTAssertEqual(roundTripped.operation, GitEvidenceXPCOperation.listCachedPaths.rawValue)
        XCTAssertEqual(roundTripped.headObjectID?.hex, "abc")
        XCTAssertTrue(roundTripped.transferredDescriptors.isEmpty)

        let record = GitEvidenceXPCDescriptorRecord(role: .index, identity: identity)
        let recordData = try NSKeyedArchiver.archivedData(
            withRootObject: record,
            requiringSecureCoding: true
        )
        let decodedRecord = try XCTUnwrap(
            NSKeyedUnarchiver.unarchivedObject(ofClass: GitEvidenceXPCDescriptorRecord.self, from: recordData)
        )
        XCTAssertEqual(decodedRecord.role, GitEvidenceXPCDescriptorRole.index.rawValue)
        XCTAssertTrue(decodedRecord.identity.matches(identity))

        XCTAssertFalse(propertyNames(of: GitEvidenceXPCRequest.self).contains(where: containsForbiddenPathToken))
        XCTAssertFalse(propertyNames(of: GitEvidenceXPCDescriptorRecord.self).contains(where: containsForbiddenPathToken))
    }

    func testXPCRequestRejectsOversizedBatch() {
        let identity = GitEvidenceXPCFileIdentity(
            device: 1,
            inode: 2,
            size: 3,
            mode: 0o100644,
            modificationSeconds: 4,
            modificationNanoseconds: 5,
            statusChangeSeconds: 6,
            statusChangeNanoseconds: 7
        )
        let descriptors = (0..<(GitEvidenceXPCLimits.maxTransferBatchSize + 1)).map { index in
            GitEvidenceXPCTransferredDescriptor(
                record: GitEvidenceXPCDescriptorRecord(role: .index, identity: identity),
                fileHandle: FileHandle(fileDescriptor: Int32(index), closeOnDealloc: false)
            )
        }

        XCTAssertThrowsError(
            try GitEvidenceXPCRequest(
                operation: .listCachedPaths,
                headObjectID: nil,
                repositoryFormatVersion: 0,
                objectHashAlgorithm: .sha1,
                transferredDescriptors: descriptors
            )
        ) { error in
            XCTAssertEqual(error as? GitEvidenceXPCValidationError, .batchTooLarge)
        }
    }

    func testClientRejectsMissingEmbeddedService() {
        let bundle = Bundle(for: GitEvidenceXPCClientTests.self)
        let client = GitEvidenceXPCClient(bundle: bundle)

        XCTAssertThrowsError(try client.validateEmbeddedServiceSignature()) { error in
            XCTAssertEqual(error as? GitEvidenceXPCClientError, .embeddedServiceMissing)
        }
    }

    private func propertyNames(of type: AnyClass) -> [String] {
        var count: UInt32 = 0
        guard let properties = class_copyPropertyList(type, &count) else {
            return []
        }
        defer { free(properties) }

        return (0..<Int(count)).map { index in
            String(cString: property_getName(properties[index]))
        }
    }

    private func containsForbiddenPathToken(_ propertyName: String) -> Bool {
        let forbidden = ["path", "root", "worktree", "gitDir", "commonDir", "bookmark"]
        return forbidden.contains { token in
            propertyName.caseInsensitiveCompare(token) == .orderedSame
                || propertyName.localizedCaseInsensitiveContains(token)
        }
    }
}
