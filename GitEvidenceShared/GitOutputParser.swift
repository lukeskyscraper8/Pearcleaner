import Foundation

public enum GitOutputParserError: Error, Equatable {
    case malformedRecord
    case invalidPath(String)
    case invalidPathComponent(String)
    case malformedOID(String)
    case outOfOrderCatFileResponse(expected: String, actual: String)
    case unexpectedTrailingData
    case incompleteCatFileResponses(expectedCount: Int, parsedCount: Int)
}

public struct GitLsTreeRecord: Equatable, Sendable {
    public let mode: String
    public let type: String
    public let oid: String
    public let path: String

    public init(mode: String, type: String, oid: String, path: String) {
        self.mode = mode
        self.type = type
        self.oid = oid
        self.path = path
    }
}

public struct GitCatFileBatchHeader: Equatable, Sendable {
    public let oid: String
    public let type: String
    public let size: Int64?

    public init(oid: String, type: String, size: Int64?) {
        self.oid = oid
        self.type = type
        self.size = size
    }
}

public enum GitOutputParser {
    public static func parseNulDelimitedPaths(from data: Data) throws -> [String] {
        guard !data.isEmpty else {
            return []
        }

        var paths: [String] = []
        var start = data.startIndex

        while start < data.endIndex {
            guard let nulIndex = data[start...].firstIndex(of: 0) else {
                throw GitOutputParserError.malformedRecord
            }

            let pathData = data[start..<nulIndex]
            guard let path = String(data: pathData, encoding: .utf8) else {
                throw GitOutputParserError.malformedRecord
            }

            try validateRelativePath(path)
            paths.append(path)
            start = data.index(after: nulIndex)
        }

        return paths
    }

    public static func parseLsTreeRecords(
        from data: Data,
        hashAlgorithm: GitEvidenceXPCObjectHashAlgorithm
    ) throws -> [GitLsTreeRecord] {
        guard !data.isEmpty else {
            return []
        }

        var records: [GitLsTreeRecord] = []
        var start = data.startIndex

        while start < data.endIndex {
            guard let nulIndex = data[start...].firstIndex(of: 0) else {
                throw GitOutputParserError.malformedRecord
            }

            let recordData = data[start..<nulIndex]
            guard let recordText = String(data: recordData, encoding: .utf8) else {
                throw GitOutputParserError.malformedRecord
            }

            records.append(try parseLsTreeRecord(recordText, hashAlgorithm: hashAlgorithm))
            start = data.index(after: nulIndex)
        }

        return records
    }

    public static func validateOID(
        _ oid: String,
        hashAlgorithm: GitEvidenceXPCObjectHashAlgorithm
    ) throws {
        let expectedLength = hashAlgorithm == .sha256 ? 64 : 40
        guard oid.count == expectedLength, oid.allSatisfy(\.isHexDigit) else {
            throw GitOutputParserError.malformedOID(oid)
        }
    }

    public static func validateRelativePath(_ path: String) throws {
        if path.isEmpty {
            throw GitOutputParserError.invalidPath(path)
        }
        if path.hasPrefix("/") || path.contains("\\") {
            throw GitOutputParserError.invalidPath(path)
        }

        for component in path.split(separator: "/", omittingEmptySubsequences: false) {
            let componentText = String(component)
            if componentText.isEmpty || componentText == "." || componentText == ".." {
                throw GitOutputParserError.invalidPathComponent(componentText)
            }
        }
    }

    private static func parseLsTreeRecord(
        _ recordText: String,
        hashAlgorithm: GitEvidenceXPCObjectHashAlgorithm
    ) throws -> GitLsTreeRecord {
        guard let tabIndex = recordText.firstIndex(of: "\t") else {
            throw GitOutputParserError.malformedRecord
        }

        let metadata = recordText[..<tabIndex]
        let path = String(recordText[recordText.index(after: tabIndex)...])

        let metadataParts = metadata.split(separator: " ", omittingEmptySubsequences: true)
        guard metadataParts.count == 3 else {
            throw GitOutputParserError.malformedRecord
        }

        let oid = String(metadataParts[2])
        try validateOID(oid, hashAlgorithm: hashAlgorithm)
        try validateRelativePath(path)

        return GitLsTreeRecord(
            mode: String(metadataParts[0]),
            type: String(metadataParts[1]),
            oid: oid,
            path: path
        )
    }
}

public struct GitCatFileBatchHeaderParser: Sendable {
    private let expectedOIDs: [String]
    private let hashAlgorithm: GitEvidenceXPCObjectHashAlgorithm
    private var buffer = Data()
    private var parsedCount = 0

    public init(expectedOIDs: [String], hashAlgorithm: GitEvidenceXPCObjectHashAlgorithm) throws {
        self.expectedOIDs = expectedOIDs
        self.hashAlgorithm = hashAlgorithm

        for oid in expectedOIDs {
            try GitOutputParser.validateOID(oid, hashAlgorithm: hashAlgorithm)
        }
    }

    public mutating func append(_ chunk: Data) throws -> [GitCatFileBatchHeader] {
        buffer.append(chunk)
        return try drainCompleteHeaders()
    }

    public mutating func finish() throws {
        guard buffer.isEmpty else {
            throw GitOutputParserError.unexpectedTrailingData
        }
        guard parsedCount == expectedOIDs.count else {
            throw GitOutputParserError.incompleteCatFileResponses(
                expectedCount: expectedOIDs.count,
                parsedCount: parsedCount
            )
        }
    }

    private mutating func drainCompleteHeaders() throws -> [GitCatFileBatchHeader] {
        var headers: [GitCatFileBatchHeader] = []

        while parsedCount < expectedOIDs.count {
            guard let lineEndIndex = buffer.firstIndex(of: 0x0A) else {
                break
            }

            let lineData = buffer[..<lineEndIndex]
            guard let line = String(data: lineData, encoding: .utf8) else {
                throw GitOutputParserError.malformedRecord
            }

            let header = try parseHeaderLine(line)
            let expectedOID = expectedOIDs[parsedCount]
            guard header.oid == expectedOID else {
                throw GitOutputParserError.outOfOrderCatFileResponse(
                    expected: expectedOID,
                    actual: header.oid
                )
            }

            let headerByteCount = buffer.distance(from: buffer.startIndex, to: lineEndIndex) + 1
            guard buffer.count >= headerByteCount else {
                break
            }

            if header.type == "missing" {
                buffer.removeSubrange(..<headerByteCount)
                headers.append(header)
                parsedCount += 1
                continue
            }

            guard let size = header.size, size >= 0 else {
                throw GitOutputParserError.malformedRecord
            }

            let payloadByteCount = Int(size) + 1
            let totalRecordByteCount = headerByteCount + payloadByteCount
            guard buffer.count >= totalRecordByteCount else {
                break
            }

            buffer.removeSubrange(..<totalRecordByteCount)
            headers.append(header)
            parsedCount += 1
        }

        return headers
    }

    private func parseHeaderLine(_ line: String) throws -> GitCatFileBatchHeader {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            throw GitOutputParserError.malformedRecord
        }

        let oid = String(parts[0])
        try GitOutputParser.validateOID(oid, hashAlgorithm: hashAlgorithm)

        let type = String(parts[1])
        if type == "missing" {
            guard parts.count == 2 else {
                throw GitOutputParserError.malformedRecord
            }
            return GitCatFileBatchHeader(oid: oid, type: type, size: nil)
        }

        guard parts.count == 3, let size = Int64(parts[2]) else {
            throw GitOutputParserError.malformedRecord
        }

        return GitCatFileBatchHeader(oid: oid, type: type, size: size)
    }
}
