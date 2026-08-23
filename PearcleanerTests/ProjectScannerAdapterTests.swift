import Foundation
import Security
import XCTest
@testable import Pearcleaner
@testable import ProjectScannerCore

final class ProjectScannerAdapterTests: XCTestCase {
    func testKeychainAddUsesWhenUnlockedThisDeviceOnlyAndDisablesSync() async throws {
        let client = RecordingSecItemClient(addStatus: errSecSuccess)
        let store = KeychainProjectKeyStore(client: client)
        let material = try makeMaterial()

        guard case .created = await store.createIfMissing(material) else {
            return XCTFail("Expected creation")
        }
        let query = try XCTUnwrap(client.addQueries.first)
        XCTAssertEqual(query[kSecAttrAccessible] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        XCTAssertEqual(query[kSecAttrSynchronizable] as? Bool, false)
        XCTAssertNil(query[kSecAttrAccessGroup])
        let retained = try XCTUnwrap(client.retainedAddedRecord)
        XCTAssertTrue(retained.bytes().allSatisfy { $0 == 0 })
    }

    func testKeychainQueryUsesFixedServiceAccountAndNoAccessGroup() async throws {
        let client = RecordingSecItemClient(copyStatus: errSecItemNotFound)
        let store = KeychainProjectKeyStore(client: client)

        guard case .missing = await store.read() else { return XCTFail("Expected missing") }
        let query = try XCTUnwrap(client.copyQueries.first)
        XCTAssertEqual(query[kSecClass] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(query[kSecAttrService] as? String, "com.lukerow.Pearcleaner.project-scanner.hmac")
        XCTAssertEqual(query[kSecAttrAccount] as? String, "suppression-v1")
        XCTAssertEqual(query[kSecAttrSynchronizable] as? Bool, false)
        XCTAssertEqual(query[kSecReturnData] as? Bool, true)
        XCTAssertEqual(query[kSecMatchLimit] as? String, kSecMatchLimitOne as String)
        XCTAssertNil(query[kSecAttrAccessGroup])
        XCTAssertEqual(client.copyQueries.count, 1)
    }

    func testKeychainNotFoundMapsToMissing() async throws {
        let store = KeychainProjectKeyStore(
            client: RecordingSecItemClient(copyStatus: errSecItemNotFound)
        )
        guard case .missing = await store.read() else { return XCTFail("Expected missing") }
    }

    func testKeychainInteractionNotAllowedMapsToUnavailable() async throws {
        let store = KeychainProjectKeyStore(
            client: RecordingSecItemClient(copyStatus: errSecInteractionNotAllowed)
        )
        guard case .unavailable(.interactionNotAllowed) = await store.read() else {
            return XCTFail("Expected sanitized unavailable result")
        }
    }

    func testKeychainMalformedRecordMapsToInvalidRecordWithoutOverwrite() async throws {
        let client = RecordingSecItemClient(
            addStatus: errSecDuplicateItem,
            copyStatus: errSecSuccess,
            copyValue: NSMutableData(data: Data([0x01, 0x02]))
        )
        let store = KeychainProjectKeyStore(client: client)

        guard case .invalidRecord = await store.createIfMissing(try makeMaterial()) else {
            return XCTFail("Expected invalid record")
        }
        XCTAssertEqual(client.addQueries.count, 1)
        XCTAssertEqual(client.copyQueries.count, 1)
        XCTAssertTrue(client.duplicateReadObservedZeroedAddRecord)
    }

    func testKeychainDuplicateNeverOverwritesExistingMaterial() async throws {
        let existing = try makeMaterial(generation: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)
        let client = RecordingSecItemClient(
            addStatus: errSecDuplicateItem,
            copyStatus: errSecSuccess,
            copyValue: existing.secureStorageRecord() as CFData
        )
        let store = KeychainProjectKeyStore(client: client)

        guard case let .existing(actual) = await store.createIfMissing(try makeMaterial()) else {
            return XCTFail("Expected existing material")
        }
        XCTAssertEqual(actual.secureStorageRecord(), existing.secureStorageRecord())
        XCTAssertEqual(client.addQueries.count, 1)
        XCTAssertEqual(client.copyQueries.count, 1)
    }

    func testKeychainDuplicateMissingMapsToSystemFailureWithoutRetry() async throws {
        let client = RecordingSecItemClient(
            addStatus: errSecDuplicateItem,
            copyStatus: errSecItemNotFound
        )
        let store = KeychainProjectKeyStore(client: client)

        guard case .unavailable(.systemFailure) = await store.createIfMissing(try makeMaterial()) else {
            return XCTFail("Expected fail-closed unavailable result")
        }
        XCTAssertEqual(client.copyQueries.count, 1)
    }

    func testEnvironmentPinsApplicationSupportNotAppGroupOrUserDefaults() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        _ = chmod(directory.path, 0o700)
        defer { try? FileManager.default.removeItem(at: directory) }
        let locator = RecordingApplicationSupportLocator(result: .success(directory))
        let environment = ProjectScannerEnvironment(locator: locator)

        let capability = try environment.privateStateParent()
        defer { capability.close() }

        XCTAssertEqual(locator.calls.count, 1)
        XCTAssertEqual(locator.calls.first?.directory, .applicationSupportDirectory)
        XCTAssertEqual(locator.calls.first?.domain, .userDomainMask)
        XCTAssertNil(locator.calls.first?.appropriateURL)
        XCTAssertEqual(locator.calls.first?.create, false)
    }

    func testEnvironmentSanitizesLocatorFailure() {
        let environment = ProjectScannerEnvironment(
            locator: RecordingApplicationSupportLocator(result: .failure(TestFailure.failed))
        )

        XCTAssertThrowsError(try environment.privateStateParent()) {
            XCTAssertEqual($0 as? ScannerEnvironmentError, .locationUnavailable)
        }
    }

    func testDiagnosticsAdapterForwardsOnlyTypedCodesAndNumbers() async throws {
        let writer = RecordingScannerLogWriter()
        let adapter = ScannerDiagnosticsAdapter(writer: writer)
        let events = [
            ScannerDiagnosticEvent(
                sessionID: ScanSessionID(rawValue: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!),
                detector: .secret,
                code: .detectorFinished,
                reason: .binary,
                count: 3,
                bytes: 4,
                durationMilliseconds: 5,
                systemCategory: nil
            ),
            ScannerDiagnosticEvent(
                sessionID: ScanSessionID(rawValue: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!),
                detector: nil,
                code: .keyUnavailable,
                reason: nil,
                count: nil,
                bytes: nil,
                durationMilliseconds: nil,
                systemCategory: .unavailable
            ),
        ]

        await withTaskGroup(of: Void.self) { group in
            for event in events {
                group.addTask { await adapter.record(event) }
            }
        }

        XCTAssertEqual(writer.events.count, events.count)
        for event in events {
            XCTAssertTrue(writer.events.contains(event))
        }
    }

    private func makeMaterial(
        generation: UUID = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
    ) throws -> ProjectKeyMaterial {
        try ProjectKeyMaterial(generation: generation, keyBytes: Data(0..<32))
    }
}

private final class RecordingSecItemClient: SecItemClient, @unchecked Sendable {
    private let lock = NSLock()
    private let addStatus: OSStatus
    private let copyStatus: OSStatus
    private let copyValue: CFTypeRef?
    private(set) var addQueries: [[CFString: Any]] = []
    private(set) var copyQueries: [[CFString: Any]] = []
    private(set) var retainedAddedRecord: NSMutableData?
    private(set) var duplicateReadObservedZeroedAddRecord = false

    init(
        addStatus: OSStatus = errSecSuccess,
        copyStatus: OSStatus = errSecItemNotFound,
        copyValue: CFTypeRef? = nil
    ) {
        self.addStatus = addStatus
        self.copyStatus = copyStatus
        self.copyValue = copyValue
    }

    func add(_ attributes: [CFString: Any]) -> OSStatus {
        lock.withLock {
            addQueries.append(attributes)
            retainedAddedRecord = attributes[kSecValueData] as? NSMutableData
        }
        return addStatus
    }

    func copyMatching(_ query: [CFString: Any]) -> (OSStatus, CFTypeRef?) {
        lock.withLock {
            copyQueries.append(query)
            if addStatus == errSecDuplicateItem, let record = retainedAddedRecord {
                duplicateReadObservedZeroedAddRecord = record.bytes().allSatisfy { $0 == 0 }
            }
        }
        return (copyStatus, copyValue)
    }
}

private extension NSMutableData {
    func bytes() -> [UInt8] {
        guard length > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: bytes.assumingMemoryBound(to: UInt8.self), count: length))
    }
}

private final class RecordingApplicationSupportLocator: ApplicationSupportLocating, @unchecked Sendable {
    struct Call {
        let directory: FileManager.SearchPathDirectory
        let domain: FileManager.SearchPathDomainMask
        let appropriateURL: URL?
        let create: Bool
    }

    let result: Result<URL, Error>
    private(set) var calls: [Call] = []

    init(result: Result<URL, Error>) {
        self.result = result
    }

    func url(
        for directory: FileManager.SearchPathDirectory,
        in domain: FileManager.SearchPathDomainMask,
        appropriateFor url: URL?,
        create: Bool
    ) throws -> URL {
        calls.append(Call(directory: directory, domain: domain, appropriateURL: url, create: create))
        return try result.get()
    }
}

private final class RecordingScannerLogWriter: ScannerLogWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ScannerDiagnosticEvent] = []

    var events: [ScannerDiagnosticEvent] { lock.withLock { recorded } }

    func write(_ event: ScannerDiagnosticEvent) {
        lock.withLock { recorded.append(event) }
    }
}

private enum TestFailure: Error {
    case failed
}
