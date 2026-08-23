import Foundation

public enum ProjectBookmarkError: Error, CaseIterable, Sendable, Equatable {
    case invalidBookmark
    case creationFailed
    case resolutionFailed
    case staleBookmark
    case accessDenied
    case rootUnavailable
    case identityChanged
}

public struct ProjectBookmark: Sendable, Equatable {
    fileprivate let storage: Data

    fileprivate init(validatedStorage: Data) throws {
        _ = try parseEnvelope(validatedStorage)
        storage = validatedStorage
    }
}

enum ProjectBookmarkPersistence {
    static func encode(_ bookmark: ProjectBookmark) -> Data {
        bookmark.storage
    }

    static func decode(_ storage: Data) throws -> ProjectBookmark {
        try ProjectBookmark(validatedStorage: storage)
    }
}

protocol BookmarkClient: Sendable {
    func createBookmark(
        for url: URL,
        options: URL.BookmarkCreationOptions,
        resourceValuesForKeys keys: Set<URLResourceKey>?,
        relativeTo relativeURL: URL?
    ) throws -> Data

    func resolveBookmark(
        _ data: Data,
        options: URL.BookmarkResolutionOptions,
        relativeTo relativeURL: URL?,
        isStale: inout Bool
    ) throws -> URL

    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
}

private struct FoundationBookmarkClient: BookmarkClient {
    func createBookmark(
        for url: URL,
        options: URL.BookmarkCreationOptions,
        resourceValuesForKeys keys: Set<URLResourceKey>?,
        relativeTo relativeURL: URL?
    ) throws -> Data {
        try url.bookmarkData(
            options: options,
            includingResourceValuesForKeys: keys,
            relativeTo: relativeURL
        )
    }

    func resolveBookmark(
        _ data: Data,
        options: URL.BookmarkResolutionOptions,
        relativeTo relativeURL: URL?,
        isStale: inout Bool
    ) throws -> URL {
        try URL(
            resolvingBookmarkData: data,
            options: options,
            relativeTo: relativeURL,
            bookmarkDataIsStale: &isStale
        )
    }

    func startAccessing(_ url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    func stopAccessing(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}

public final class ProjectBookmarkAccess: @unchecked Sendable {
    private let client: any BookmarkClient

    public init() {
        client = FoundationBookmarkClient()
    }

    init(client: any BookmarkClient) {
        self.client = client
    }

    public func create(selectedURL: URL) throws -> ProjectBookmark {
        let selectedRoot: RootCapability
        do {
            selectedRoot = try RootCapability.open(selectedURL: selectedURL)
        } catch {
            throw ProjectBookmarkError.rootUnavailable
        }
        defer { selectedRoot.close() }

        let bookmarkData: Data
        do {
            bookmarkData = try client.createBookmark(
                for: selectedURL,
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                resourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            throw ProjectBookmarkError.creationFailed
        }

        var isStale = false
        let resolvedURL: URL
        do {
            resolvedURL = try client.resolveBookmark(
                bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                isStale: &isStale
            )
        } catch {
            throw ProjectBookmarkError.resolutionFailed
        }
        guard !isStale else { throw ProjectBookmarkError.staleBookmark }
        guard client.startAccessing(resolvedURL) else {
            throw ProjectBookmarkError.accessDenied
        }
        var scopeOwned = true
        defer {
            if scopeOwned {
                client.stopAccessing(resolvedURL)
            }
        }

        let resolvedRoot: RootCapability
        do {
            resolvedRoot = try RootCapability.open(selectedURL: resolvedURL)
        } catch {
            throw ProjectBookmarkError.rootUnavailable
        }
        defer { resolvedRoot.close() }
        guard stableIdentity(selectedRoot.identity) == stableIdentity(resolvedRoot.identity) else {
            throw ProjectBookmarkError.identityChanged
        }

        client.stopAccessing(resolvedURL)
        scopeOwned = false

        return try ProjectBookmark(
            validatedStorage: makeEnvelope(
                identity: stableIdentity(selectedRoot.identity),
                bookmarkData: bookmarkData
            )
        )
    }

    public func resolve(_ bookmark: ProjectBookmark) throws -> ResolvedProjectBookmarkLease {
        let envelope = try parseEnvelope(bookmark.storage)
        var isStale = false
        let resolvedURL: URL
        do {
            resolvedURL = try client.resolveBookmark(
                envelope.bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                isStale: &isStale
            )
        } catch {
            throw ProjectBookmarkError.resolutionFailed
        }
        guard !isStale else { throw ProjectBookmarkError.staleBookmark }
        guard client.startAccessing(resolvedURL) else {
            throw ProjectBookmarkError.accessDenied
        }

        var scopeOwned = true
        defer {
            if scopeOwned {
                client.stopAccessing(resolvedURL)
            }
        }
        let root: RootCapability
        do {
            root = try RootCapability.open(selectedURL: resolvedURL)
        } catch {
            throw ProjectBookmarkError.rootUnavailable
        }
        guard stableIdentity(root.identity) == envelope.identity else {
            root.close()
            throw ProjectBookmarkError.identityChanged
        }

        let lease = ResolvedProjectBookmarkLease(
            rootCapability: root,
            resolvedURL: resolvedURL,
            client: client
        )
        scopeOwned = false
        return lease
    }
}

public final class ResolvedProjectBookmarkLease: @unchecked Sendable {
    // The lease must outlive all descriptor-backed scan and broker work derived from this root.
    // Task 9 cannot mechanically bind an already-extracted broker back to this lifetime.
    public let rootCapability: RootCapability
    private let lock = NSLock()
    private var ownedRootCapability: RootCapability?
    private var resolvedURL: URL?
    private var client: (any BookmarkClient)?

    init(
        rootCapability: RootCapability,
        resolvedURL: URL,
        client: any BookmarkClient
    ) {
        self.rootCapability = rootCapability
        ownedRootCapability = rootCapability
        self.resolvedURL = resolvedURL
        self.client = client
    }

    public func close() {
        let owned = lock.withLock { () -> (RootCapability, URL, any BookmarkClient)? in
            guard let root = ownedRootCapability,
                  let url = resolvedURL,
                  let client else {
                return nil
            }
            ownedRootCapability = nil
            resolvedURL = nil
            self.client = nil
            return (root, url, client)
        }
        guard let owned else { return }
        owned.0.close()
        owned.2.stopAccessing(owned.1)
    }

    deinit {
        close()
    }
}

private struct StableBookmarkIdentity: Sendable, Equatable {
    let device: UInt64
    let inode: UInt64
    let type: UInt16
}

private struct BookmarkEnvelope: Sendable {
    let identity: StableBookmarkIdentity
    let bookmarkData: Data
}

private let bookmarkEnvelopeMagic = Data([0x50, 0x53, 0x42, 0x4D])
private let bookmarkEnvelopeVersion: UInt8 = 0x01
private let bookmarkEnvelopeHeaderSize = 27
private let bookmarkEnvelopeMaximumSize = 1_048_576

private func stableIdentity(_ identity: FileIdentity) -> StableBookmarkIdentity {
    StableBookmarkIdentity(
        device: identity.device,
        inode: identity.inode,
        type: identity.mode & UInt16(S_IFMT)
    )
}

private func makeEnvelope(
    identity: StableBookmarkIdentity,
    bookmarkData: Data
) throws -> Data {
    guard identity.type == UInt16(S_IFDIR),
          !bookmarkData.isEmpty,
          let bookmarkLength = UInt32(exactly: bookmarkData.count),
          bookmarkEnvelopeHeaderSize + bookmarkData.count <= bookmarkEnvelopeMaximumSize else {
        throw ProjectBookmarkError.invalidBookmark
    }

    var storage = Data()
    storage.reserveCapacity(bookmarkEnvelopeHeaderSize + bookmarkData.count)
    storage.append(bookmarkEnvelopeMagic)
    storage.append(bookmarkEnvelopeVersion)
    appendBigEndian(identity.device, to: &storage)
    appendBigEndian(identity.inode, to: &storage)
    appendBigEndian(identity.type, to: &storage)
    appendBigEndian(bookmarkLength, to: &storage)
    storage.append(bookmarkData)
    return storage
}

private func parseEnvelope(_ storage: Data) throws -> BookmarkEnvelope {
    guard storage.count <= bookmarkEnvelopeMaximumSize,
          storage.count >= bookmarkEnvelopeHeaderSize + 1 else {
        throw ProjectBookmarkError.invalidBookmark
    }
    let bytes = [UInt8](storage)
    guard Data(bytes[0..<4]) == bookmarkEnvelopeMagic,
          bytes[4] == bookmarkEnvelopeVersion else {
        throw ProjectBookmarkError.invalidBookmark
    }

    let device = decodeUInt64(bytes, at: 5)
    let inode = decodeUInt64(bytes, at: 13)
    let type = decodeUInt16(bytes, at: 21)
    let length = decodeUInt32(bytes, at: 23)
    guard type == UInt16(S_IFDIR), length > 0,
          let dataLength = Int(exactly: length),
          dataLength == storage.count - bookmarkEnvelopeHeaderSize else {
        throw ProjectBookmarkError.invalidBookmark
    }
    let bookmarkData = Data(bytes[bookmarkEnvelopeHeaderSize..<storage.count])
    guard !bookmarkData.isEmpty else { throw ProjectBookmarkError.invalidBookmark }
    return BookmarkEnvelope(
        identity: StableBookmarkIdentity(device: device, inode: inode, type: type),
        bookmarkData: bookmarkData
    )
}

private func appendBigEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    for shift in stride(from: T.bitWidth - 8, through: 0, by: -8) {
        data.append(UInt8(truncatingIfNeeded: value >> T(shift)))
    }
}

private func decodeUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
    (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
}

private func decodeUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
    var value: UInt32 = 0
    for index in offset..<(offset + 4) {
        value = (value << 8) | UInt32(bytes[index])
    }
    return value
}

private func decodeUInt64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
    var value: UInt64 = 0
    for index in offset..<(offset + 8) {
        value = (value << 8) | UInt64(bytes[index])
    }
    return value
}
