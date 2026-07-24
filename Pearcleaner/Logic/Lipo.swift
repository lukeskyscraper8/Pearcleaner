//
//  Lipo.swift
//  Pearcleaner
//
//  Created by Alin Lupascu on 4/10/25.
//
//  Modified for the independently maintained Pearcleaner fork.

import Foundation
import Security


// Helper structs for Mach-O parsing
public struct FatHeader {
    public let magic: UInt32
    public let numArchitectures: UInt32
    
    public init(magic: UInt32, numArchitectures: UInt32) {
        self.magic = magic
        self.numArchitectures = numArchitectures
    }
}

public struct FatArch {
    public let cpuType: UInt32
    public let cpuSubtype: UInt32
    public let offset: UInt32
    public let size: UInt32
    public let align: UInt32
    
    public init(cpuType: UInt32, cpuSubtype: UInt32, offset: UInt32, size: UInt32, align: UInt32) {
        self.cpuType = cpuType
        self.cpuSubtype = cpuSubtype
        self.offset = offset
        self.size = size
        self.align = align
    }
}

enum AppBundleMutationEligibility: Equatable {
    case unsigned
    case signed
    case uninspectable

    var allowsMutation: Bool {
        self == .unsigned
    }

    var userFacingReason: String {
        switch self {
        case .unsigned:
            return ""
        case .signed:
            return "Pearcleaner skipped this app because modifying it would invalidate its code signature."
        case .uninspectable:
            return "Pearcleaner skipped this app because its code-signing state could not be inspected safely."
        }
    }
}

struct AppBundleMutationBlockedError: LocalizedError {
    let eligibility: AppBundleMutationEligibility

    var errorDescription: String? {
        eligibility.userFacingReason
    }
}

enum AppBundleMutationSafety {
    private static let codeBundleExtensions: Set<String> = [
        "app", "appex", "bundle", "framework", "plugin", "xpc"
    ]

    static func classify(
        hasCodeResources: Bool,
        staticCodeStatus: OSStatus,
        signingInformationStatus: OSStatus?,
        hasSignatureInformation: Bool? = nil
    ) -> AppBundleMutationEligibility {
        if hasCodeResources {
            return .signed
        }
        guard staticCodeStatus == errSecSuccess else {
            return .uninspectable
        }
        guard let signingInformationStatus else {
            return .uninspectable
        }
        if signingInformationStatus == errSecSuccess {
            guard let hasSignatureInformation else {
                return .uninspectable
            }
            return hasSignatureInformation ? .signed : .unsigned
        }
        if signingInformationStatus == errSecCSUnsigned {
            return .unsigned
        }
        return .uninspectable
    }

    static func inspect(_ appBundleURL: URL) -> AppBundleMutationEligibility {
        let fileManager = FileManager.default
        let standardizedURL = appBundleURL.standardizedFileURL

        guard standardizedURL.pathExtension.lowercased() == "app",
              let bundleValues = try? standardizedURL.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
              ),
              bundleValues.isDirectory == true,
              bundleValues.isSymbolicLink != true else {
            return .uninspectable
        }

        let infoPlistURL = standardizedURL.appendingPathComponent("Contents/Info.plist")
        guard let plistData = try? Data(contentsOf: infoPlistURL),
              let plist = try? PropertyListSerialization.propertyList(
                from: plistData,
                options: [],
                format: nil
              ) as? [String: Any],
              let executableName = plist["CFBundleExecutable"] as? String,
              !executableName.isEmpty else {
            return .uninspectable
        }

        let executableURL = standardizedURL
            .appendingPathComponent("Contents/MacOS")
            .appendingPathComponent(executableName)
        guard let executableValues = try? executableURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ),
              executableValues.isRegularFile == true,
              executableValues.isSymbolicLink != true,
              contains(executableURL, in: standardizedURL) else {
            return .uninspectable
        }

        let codeResourcesURL = standardizedURL
            .appendingPathComponent("Contents/_CodeSignature/CodeResources")
        let hasCodeResources = fileManager.fileExists(atPath: codeResourcesURL.path)
        if hasCodeResources {
            return .signed
        }

        var staticCode: SecStaticCode?
        let staticCodeStatus = SecStaticCodeCreateWithPath(
            standardizedURL as CFURL,
            [],
            &staticCode
        )
        guard staticCodeStatus == errSecSuccess, let staticCode else {
            return classify(
                hasCodeResources: false,
                staticCodeStatus: staticCodeStatus,
                signingInformationStatus: nil,
                hasSignatureInformation: nil
            )
        }

        var signingInformation: CFDictionary?
        let signingInformationStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInformation
        )
        let signingDictionary = signingInformation as? [String: Any]
        let hasSignatureInformation = signingDictionary.map {
            $0[kSecCodeInfoUnique as String] != nil ||
            $0[kSecCodeInfoIdentifier as String] != nil
        }
        return classify(
            hasCodeResources: false,
            staticCodeStatus: staticCodeStatus,
            signingInformationStatus: signingInformationStatus,
            hasSignatureInformation: hasSignatureInformation
        )
    }

    static func requireUnsigned(_ appBundleURL: URL) throws {
        let eligibility = inspect(appBundleURL)
        guard eligibility.allowsMutation else {
            throw AppBundleMutationBlockedError(eligibility: eligibility)
        }
    }

    static func inspectCodeObject(_ codeObjectURL: URL) -> AppBundleMutationEligibility {
        let standardizedURL = codeObjectURL.standardizedFileURL
        guard let values = try? standardizedURL.resourceValues(
            forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ]
        ),
              values.isSymbolicLink != true,
              values.isDirectory == true || values.isRegularFile == true else {
            return .uninspectable
        }

        var staticCode: SecStaticCode?
        let staticCodeStatus = SecStaticCodeCreateWithPath(
            standardizedURL as CFURL,
            [],
            &staticCode
        )
        guard staticCodeStatus == errSecSuccess, let staticCode else {
            return classify(
                hasCodeResources: false,
                staticCodeStatus: staticCodeStatus,
                signingInformationStatus: nil,
                hasSignatureInformation: nil
            )
        }

        var signingInformation: CFDictionary?
        let signingInformationStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInformation
        )
        let signingDictionary = signingInformation as? [String: Any]
        let hasSignatureInformation = signingDictionary.map {
            $0[kSecCodeInfoUnique as String] != nil ||
            $0[kSecCodeInfoIdentifier as String] != nil
        }
        return classify(
            hasCodeResources: false,
            staticCodeStatus: staticCodeStatus,
            signingInformationStatus: signingInformationStatus,
            hasSignatureInformation: hasSignatureInformation
        )
    }

    static func inspectMutationTargets(
        _ targetURLs: [URL],
        in appBundleURL: URL,
        inspectTargetsAsCode: Bool = true
    ) -> AppBundleMutationEligibility {
        let rootURL = appBundleURL.resolvingSymlinksInPath().standardizedFileURL
        let rootEligibility = inspect(rootURL)
        guard rootEligibility.allowsMutation else {
            return rootEligibility
        }

        var inspectedCodeObjectPaths = Set<String>()
        for targetURL in targetURLs {
            let standardizedTarget = targetURL.standardizedFileURL
            guard contains(standardizedTarget, in: rootURL) else {
                return .uninspectable
            }

            if inspectTargetsAsCode {
                let targetEligibility = inspectCodeObject(standardizedTarget)
                guard targetEligibility.allowsMutation else {
                    return targetEligibility
                }
            }

            var ancestor = standardizedTarget.deletingLastPathComponent()
            while ancestor.path != rootURL.path,
                  contains(ancestor, in: rootURL) {
                if codeBundleExtensions.contains(
                    ancestor.pathExtension.lowercased()
                ),
                   inspectedCodeObjectPaths.insert(ancestor.path).inserted {
                    let eligibility = inspectCodeObject(ancestor)
                    guard eligibility.allowsMutation else {
                        return eligibility
                    }
                }
                ancestor.deleteLastPathComponent()
            }
        }
        return .unsigned
    }

    static func requireUnsignedMutationTargets(
        _ targetURLs: [URL],
        in appBundleURL: URL,
        inspectTargetsAsCode: Bool = true
    ) throws {
        let eligibility = inspectMutationTargets(
            targetURLs,
            in: appBundleURL,
            inspectTargetsAsCode: inspectTargetsAsCode
        )
        guard eligibility.allowsMutation else {
            throw AppBundleMutationBlockedError(eligibility: eligibility)
        }
    }

    static func contains(_ candidateURL: URL, in rootURL: URL) -> Bool {
        let root = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        let candidate = candidateURL.resolvingSymlinksInPath().standardizedFileURL.path
        return candidate == root || candidate.hasPrefix(root + "/")
    }
}

enum MachOInspectionError: LocalizedError {
    case cannotOpen
    case invalidHeader
    case unsupportedFormat
    case invalidArchitectureCount
    case invalidArchitectureTable
    case invalidSliceRange
    case invalidSliceContents
    case overlappingSlices
    case fileTooLarge

    var errorDescription: String? {
        switch self {
        case .cannotOpen:
            return "Could not open the Mach-O file."
        case .invalidHeader:
            return "The Mach-O header is incomplete."
        case .unsupportedFormat:
            return "The file is not a supported Mach-O binary."
        case .invalidArchitectureCount:
            return "The universal binary has an invalid architecture count."
        case .invalidArchitectureTable:
            return "The universal binary architecture table is invalid."
        case .invalidSliceRange:
            return "A universal binary architecture slice is outside the file."
        case .invalidSliceContents:
            return "A universal binary architecture slice has an invalid Mach-O header."
        case .overlappingSlices:
            return "Universal binary architecture slices overlap."
        case .fileTooLarge:
            return "The Mach-O file is too large to inspect safely."
        }
    }
}

enum MachOLayout {
    case fat(architectures: [FatArch], fileSize: UInt64)
    case thin(cpuType: UInt32, fileSize: UInt64)
}

struct MachOThinningPlan {
    let fileURL: URL
    let architecture: FatArch
    let fileSize: UInt64
}

enum BundleThinningStatus {
    case succeeded
    case partiallySucceeded
    case blocked(AppBundleMutationEligibility)
    case failed
}

struct BundleThinningResult {
    let status: BundleThinningStatus
    let sizes: [String: UInt64]?
    let message: String
}

enum MachOSafety {
    static let fatMagic: UInt32 = 0xcafebabe
    static let fatMagicSwapped: UInt32 = 0xbebafeca
    static let fatMagic64: UInt32 = 0xcafebabf
    static let fatMagic64Swapped: UInt32 = 0xbfbafeca
    static let arm64CPUType: UInt32 = 0x0100000c
    static let x86_64CPUType: UInt32 = 0x01000007

#if arch(arm64)
    static let currentCPUType = arm64CPUType
#else
    static let currentCPUType = x86_64CPUType
#endif

    private enum ByteOrder {
        case big
        case little
    }

    static func validatedSliceRange(
        offset: UInt64,
        size: UInt64,
        fileSize: UInt64
    ) -> Range<Int>? {
        guard size > 0 else { return nil }
        let (end, overflow) = offset.addingReportingOverflow(size)
        guard !overflow,
              offset <= fileSize,
              end <= fileSize,
              offset <= UInt64(Int.max),
              end <= UInt64(Int.max) else {
            return nil
        }
        return Int(offset)..<Int(end)
    }

    static func inspect(_ fileURL: URL) throws -> MachOLayout {
        guard let fileHandle = try? FileHandle(forReadingFrom: fileURL) else {
            throw MachOInspectionError.cannotOpen
        }
        defer { try? fileHandle.close() }

        let fileSize = fileHandle.seekToEndOfFile()
        try fileHandle.seek(toOffset: 0)
        guard let headerData = try fileHandle.read(upToCount: 8),
              headerData.count == 8,
              let magic = readUInt32(from: headerData, at: 0, order: .big) else {
            throw MachOInspectionError.invalidHeader
        }

        if magic == fatMagic64 || magic == fatMagic64Swapped {
            throw MachOInspectionError.unsupportedFormat
        }

        if magic == fatMagic || magic == fatMagicSwapped {
            let order: ByteOrder = magic == fatMagic ? .big : .little
            guard let count = readUInt32(from: headerData, at: 4, order: order),
                  count > 0,
                  count < 100 else {
                throw MachOInspectionError.invalidArchitectureCount
            }

            let (architectureBytes, architectureBytesOverflow) = UInt64(count)
                .multipliedReportingOverflow(by: 20)
            let (tableSize, tableSizeOverflow) = UInt64(8)
                .addingReportingOverflow(architectureBytes)
            guard !architectureBytesOverflow,
                  !tableSizeOverflow,
                  tableSize <= fileSize,
                  tableSize <= UInt64(Int.max) else {
                throw MachOInspectionError.invalidArchitectureTable
            }

            try fileHandle.seek(toOffset: 8)
            guard let architectureData = try fileHandle.read(
                upToCount: Int(architectureBytes)
            ),
                  architectureData.count == Int(architectureBytes) else {
                throw MachOInspectionError.invalidArchitectureTable
            }

            var architectures: [FatArch] = []
            var ranges: [Range<Int>] = []
            architectures.reserveCapacity(Int(count))
            ranges.reserveCapacity(Int(count))

            for index in 0..<Int(count) {
                let base = index * 20
                guard let cpuType = readUInt32(
                    from: architectureData,
                    at: base,
                    order: order
                ),
                      let cpuSubtype = readUInt32(
                        from: architectureData,
                        at: base + 4,
                        order: order
                      ),
                      let offset = readUInt32(
                        from: architectureData,
                        at: base + 8,
                        order: order
                      ),
                      let size = readUInt32(
                        from: architectureData,
                        at: base + 12,
                        order: order
                      ),
                      let align = readUInt32(
                        from: architectureData,
                        at: base + 16,
                        order: order
                      ),
                      let range = validatedSliceRange(
                        offset: UInt64(offset),
                        size: UInt64(size),
                        fileSize: fileSize
                      ),
                      UInt64(range.lowerBound) >= tableSize else {
                    throw MachOInspectionError.invalidSliceRange
                }

                guard !ranges.contains(where: { $0.overlaps(range) }) else {
                    throw MachOInspectionError.overlappingSlices
                }

                try fileHandle.seek(toOffset: UInt64(offset))
                guard let sliceHeader = try fileHandle.read(upToCount: 8),
                      isValidThinSliceHeader(sliceHeader, cpuType: cpuType) else {
                    throw MachOInspectionError.invalidSliceContents
                }

                architectures.append(
                    FatArch(
                        cpuType: cpuType,
                        cpuSubtype: cpuSubtype,
                        offset: offset,
                        size: size,
                        align: align
                    )
                )
                ranges.append(range)
            }

            return .fat(architectures: architectures, fileSize: fileSize)
        }

        let fieldOrder: ByteOrder
        switch magic {
        case 0xfeedface, 0xfeedfacf:
            fieldOrder = .big
        case 0xcefaedfe, 0xcffaedfe:
            fieldOrder = .little
        default:
            throw MachOInspectionError.unsupportedFormat
        }

        guard let cpuType = readUInt32(from: headerData, at: 4, order: fieldOrder) else {
            throw MachOInspectionError.invalidHeader
        }
        return .thin(cpuType: cpuType, fileSize: fileSize)
    }

    struct PreparedReplacement {
        fileprivate let destinationURL: URL
        fileprivate let temporaryURL: URL
        fileprivate let sourceIdentity: FileIdentity
    }

    fileprivate struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let size: UInt64
        let modificationDate: Date
    }

    static func atomicallyReplaceContents(at destinationURL: URL, with data: Data) throws {
        let prepared = try prepareReplacement(
            at: destinationURL,
            writeContents: { temporaryHandle in
                try temporaryHandle.write(contentsOf: data)
            }
        )
        do {
            try commit(prepared)
        } catch {
            discard(prepared)
            throw error
        }
    }

    static func prepareSliceReplacement(
        at destinationURL: URL,
        architecture: FatArch,
        expectedFileSize: UInt64
    ) throws -> PreparedReplacement {
        try prepareReplacement(
            at: destinationURL,
            expectedFileSize: expectedFileSize
        ) { temporaryHandle in
            let sourceHandle = try FileHandle(forReadingFrom: destinationURL)
            defer { try? sourceHandle.close() }

            let currentSize = sourceHandle.seekToEndOfFile()
            guard currentSize == expectedFileSize,
                  let range = validatedSliceRange(
                    offset: UInt64(architecture.offset),
                    size: UInt64(architecture.size),
                    fileSize: currentSize
                  ) else {
                throw MachOInspectionError.invalidSliceRange
            }

            try sourceHandle.seek(toOffset: UInt64(range.lowerBound))
            guard let header = try sourceHandle.read(upToCount: 8),
                  isValidThinSliceHeader(
                    header,
                    cpuType: architecture.cpuType
                  ) else {
                throw MachOInspectionError.invalidSliceContents
            }
            try sourceHandle.seek(toOffset: UInt64(range.lowerBound))

            var remaining = UInt64(range.count)
            let chunkSize: UInt64 = 1_048_576
            while remaining > 0 {
                let requested = Int(min(remaining, chunkSize))
                guard let chunk = try sourceHandle.read(upToCount: requested),
                      chunk.count == requested else {
                    throw MachOInspectionError.invalidSliceRange
                }
                try temporaryHandle.write(contentsOf: chunk)
                remaining -= UInt64(chunk.count)
            }
        }
    }

    static func commit(_ prepared: PreparedReplacement) throws {
        let fileManager = FileManager.default
        guard try fileIdentity(at: prepared.destinationURL)
            == prepared.sourceIdentity else {
            throw CocoaError(.fileWriteFileExists)
        }

        // Default replacement semantics preserve the destination's metadata.
        // usingNewMetadataOnly would silently drop its owner, ACLs and xattrs.
        _ = try fileManager.replaceItemAt(
            prepared.destinationURL,
            withItemAt: prepared.temporaryURL,
            backupItemName: nil,
            options: []
        )
    }

    static func discard(_ prepared: PreparedReplacement) {
        try? FileManager.default.removeItem(at: prepared.temporaryURL)
    }

    static func isValidThinSlice(_ data: Data, cpuType: UInt32) -> Bool {
        guard data.count >= 8 else { return false }
        return isValidThinSliceHeader(Data(data.prefix(8)), cpuType: cpuType)
    }

    private static func isValidThinSliceHeader(
        _ data: Data,
        cpuType: UInt32
    ) -> Bool {
        guard let magic = readUInt32(from: data, at: 0, order: .big) else {
            return false
        }

        let order: ByteOrder
        switch magic {
        case 0xfeedface, 0xfeedfacf:
            order = .big
        case 0xcefaedfe, 0xcffaedfe:
            order = .little
        default:
            return false
        }

        return readUInt32(from: data, at: 4, order: order) == cpuType
    }

    private static func readUInt32(
        from data: Data,
        at offset: Int,
        order: ByteOrder
    ) -> UInt32? {
        guard offset >= 0, offset <= data.count, data.count - offset >= 4 else {
            return nil
        }
        var rawValue: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &rawValue) { destination in
            data.copyBytes(to: destination, from: offset..<(offset + 4))
        }
        switch order {
        case .big:
            return UInt32(bigEndian: rawValue)
        case .little:
            return UInt32(littleEndian: rawValue)
        }
    }

    private static func prepareReplacement(
        at destinationURL: URL,
        expectedFileSize: UInt64? = nil,
        writeContents: (FileHandle) throws -> Void
    ) throws -> PreparedReplacement {
        let fileManager = FileManager.default
        let sourceIdentity = try fileIdentity(at: destinationURL)
        if let expectedFileSize,
           sourceIdentity.size != expectedFileSize {
            throw MachOInspectionError.invalidSliceRange
        }

        let attributes = try fileManager.attributesOfItem(
            atPath: destinationURL.path
        )
        let temporaryURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(destinationURL.lastPathComponent).pearcleaner-\(UUID().uuidString)"
            )

        do {
            try Data().write(to: temporaryURL, options: .withoutOverwriting)
            if let permissions = attributes[.posixPermissions] {
                try fileManager.setAttributes(
                    [.posixPermissions: permissions],
                    ofItemAtPath: temporaryURL.path
                )
            }

            let temporaryHandle = try FileHandle(forWritingTo: temporaryURL)
            do {
                try writeContents(temporaryHandle)
                try temporaryHandle.synchronize()
                try temporaryHandle.close()
            } catch {
                try? temporaryHandle.close()
                throw error
            }

            if let modificationDate = attributes[.modificationDate] {
                try fileManager.setAttributes(
                    [.modificationDate: modificationDate],
                    ofItemAtPath: temporaryURL.path
                )
            }

            guard try fileIdentity(at: destinationURL) == sourceIdentity else {
                throw CocoaError(.fileWriteFileExists)
            }
            return PreparedReplacement(
                destinationURL: destinationURL,
                temporaryURL: temporaryURL,
                sourceIdentity: sourceIdentity
            )
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    private static func fileIdentity(at url: URL) throws -> FileIdentity {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path
        )
        guard let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let modificationDate = attributes[.modificationDate] as? Date else {
            throw MachOInspectionError.cannotOpen
        }
        return FileIdentity(
            device: device,
            inode: inode,
            size: size,
            modificationDate: modificationDate
        )
    }
}

// Compatibility entry point retained for the privileged helper protocol.
public func thinAppBundle(
    at bundlePath: URL,
    dryRun: Bool = false
) -> (Bool, [String: UInt64]?) {
    let result = thinAppBundleDetailed(at: bundlePath, dryRun: dryRun)
    guard case .succeeded = result.status else {
        return (false, result.sizes)
    }
    return (true, result.sizes)
}

func thinAppBundleDetailed(
    at bundlePath: URL,
    dryRun: Bool = false
) -> BundleThinningResult {
    let preTotalSize = UInt64(max(0, totalSizeOnDisk(for: bundlePath)))
    let result = recursivelyThinBundle(at: bundlePath, dryRun: dryRun)

    switch result.status {
    case .succeeded, .partiallySucceeded:
        let sizes: [String: UInt64]
        if dryRun {
            let binarySavings = result.sizes?["binarySavings"] ?? 0
            let estimatedPostSize = preTotalSize > binarySavings
                ? preTotalSize - binarySavings
                : preTotalSize
            sizes = ["pre": preTotalSize, "post": estimatedPostSize]
        } else {
            let postTotalSize = UInt64(max(0, totalSizeOnDisk(for: bundlePath)))
            sizes = ["pre": preTotalSize, "post": postTotalSize]
        }
        return BundleThinningResult(
            status: result.status,
            sizes: sizes,
            message: result.message
        )

    case .blocked, .failed:
        return result
    }
}

// Build and validate the complete mutation plan before writing the first file.
// This prevents a malformed or signed nested binary from producing a partially
// thinned bundle.
func recursivelyThinBundle(
    at path: URL,
    dryRun: Bool = false
) -> BundleThinningResult {
    let fileManager = FileManager.default

    if !dryRun {
        let eligibility = AppBundleMutationSafety.inspect(path)
        guard eligibility.allowsMutation else {
            print("Bundle thinning skipped: \(eligibility.userFacingReason)")
            return BundleThinningResult(
                status: .blocked(eligibility),
                sizes: nil,
                message: eligibility.userFacingReason
            )
        }
    }

    guard let enumerator = fileManager.enumerator(at: path,
                                                  includingPropertiesForKeys: [
                                                    .isDirectoryKey,
                                                    .isRegularFileKey,
                                                    .isSymbolicLinkKey
                                                  ],
                                                  options: [.skipsHiddenFiles]) else {
        print("Bundle Error: Could not enumerate bundle contents")
        return BundleThinningResult(
            status: .failed,
            sizes: nil,
            message: "The app bundle could not be enumerated safely."
        )
    }

    // Collect all file URLs first to avoid keeping enumerator handles open
    var candidateFiles: [URL] = []
    autoreleasepool {
        for case let fileURL as URL in enumerator {
            autoreleasepool {
                // Skip directories early
                let resourceValues = try? fileURL.resourceValues(
                    forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
                )
                if resourceValues?.isDirectory == true
                    || resourceValues?.isRegularFile != true
                    || resourceValues?.isSymbolicLink == true
                    || !AppBundleMutationSafety.contains(fileURL, in: path) {
                    return
                }
                candidateFiles.append(fileURL)
            }
        }
    }

    var plans: [MachOThinningPlan] = []
    for fileURL in candidateFiles where shouldThinFile(fileURL) {
        do {
            guard case .fat(let architectures, let fileSize) =
                    try MachOSafety.inspect(fileURL) else {
                continue
            }
            guard architectures.count > 1 else {
                continue
            }
            let targetArchitectures = architectures.filter {
                $0.cpuType == MachOSafety.currentCPUType
            }
            guard targetArchitectures.count == 1,
                  let targetArchitecture = targetArchitectures.first,
                  UInt64(targetArchitecture.size) < fileSize else {
                throw MachOInspectionError.invalidSliceContents
            }
            plans.append(
                MachOThinningPlan(
                    fileURL: fileURL,
                    architecture: targetArchitecture,
                    fileSize: fileSize
                )
            )
        } catch {
            return BundleThinningResult(
                status: .failed,
                sizes: nil,
                message:
                    "Mach-O inspection failed for \(fileURL.lastPathComponent): \(error.localizedDescription)"
            )
        }
    }

    guard !plans.isEmpty else {
        return BundleThinningResult(
            status: .failed,
            sizes: nil,
            message: "No eligible universal binaries were found."
        )
    }

    let totalPreSize = plans.reduce(UInt64(0)) { $0 + $1.fileSize }
    let estimatedPostSize = plans.reduce(UInt64(0)) {
        $0 + UInt64($1.architecture.size)
    }
    let estimatedSizes = [
        "pre": totalPreSize,
        "post": estimatedPostSize,
        "binarySavings": totalPreSize > estimatedPostSize
            ? totalPreSize - estimatedPostSize
            : 0
    ]

    if dryRun {
        return BundleThinningResult(
            status: .succeeded,
            sizes: estimatedSizes,
            message: "Bundle thinning estimate completed."
        )
    }

    let eligibility = AppBundleMutationSafety.inspectMutationTargets(
        plans.map(\.fileURL),
        in: path
    )
    guard eligibility.allowsMutation else {
        return BundleThinningResult(
            status: .blocked(eligibility),
            sizes: nil,
            message: eligibility.userFacingReason
        )
    }

    // Stage every replacement first. Permission, disk-space and slice-read
    // failures therefore happen before any destination is replaced.
    var preparedReplacements: [MachOSafety.PreparedReplacement] = []
    do {
        for plan in plans {
            preparedReplacements.append(
                try MachOSafety.prepareSliceReplacement(
                    at: plan.fileURL,
                    architecture: plan.architecture,
                    expectedFileSize: plan.fileSize
                )
            )
        }
    } catch {
        preparedReplacements.forEach(MachOSafety.discard)
        return BundleThinningResult(
            status: .failed,
            sizes: nil,
            message: "Bundle thinning could not be staged: \(error.localizedDescription)"
        )
    }

    var committedCount = 0
    for (index, replacement) in preparedReplacements.enumerated() {
        do {
            // Re-check signing immediately before each mutation.
            try AppBundleMutationSafety.requireUnsignedMutationTargets(
                [plans[index].fileURL],
                in: path
            )
            try MachOSafety.commit(replacement)
            committedCount += 1
        } catch {
            preparedReplacements[index...].forEach(MachOSafety.discard)
            let status: BundleThinningStatus = committedCount > 0
                ? .partiallySucceeded
                : .failed
            let committedPlans = plans.prefix(committedCount)
            let committedPreSize = committedPlans.reduce(UInt64(0)) {
                $0 + $1.fileSize
            }
            let committedPostSize = committedPlans.reduce(UInt64(0)) {
                $0 + UInt64($1.architecture.size)
            }
            return BundleThinningResult(
                status: status,
                sizes: committedCount > 0
                    ? ["pre": committedPreSize, "post": committedPostSize]
                    : nil,
                message:
                    "Bundle thinning stopped after \(committedCount) of \(plans.count) binaries: \(error.localizedDescription)"
            )
        }
    }

    if !path.path.isEmpty, path.path != "/" {
        try? fileManager.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: path.path
        )
    }

    return BundleThinningResult(
        status: .succeeded,
        sizes: estimatedSizes,
        message: "Bundle thinning completed successfully."
    )
}

// Determine if a file should be thinned
func shouldThinFile(_ url: URL) -> Bool {
    // Check if it's an executable binary
    return isExecutableBinary(url)
}

// Find the app bundle path by traversing up the directory tree
func findAppBundlePath(from url: URL) -> URL {
    var currentURL = url
    
    // Keep going up until we find a .app bundle or reach the root
    while currentURL.path != "/" {
        if currentURL.pathExtension == "app" {
            return currentURL
        }
        currentURL = currentURL.deletingLastPathComponent()
    }
    
    // Fallback: assume it's a traditional app bundle structure
    var fallbackURL = url
    while fallbackURL.path != "/" && !fallbackURL.path.hasSuffix(".app") {
        fallbackURL = fallbackURL.deletingLastPathComponent()
    }
    
    return fallbackURL
}

// Check if a file is an executable binary
public func isExecutableBinary(_ url: URL) -> Bool {
    // First check file extension for known binary types
    let pathExtension = url.pathExtension.lowercased()
    let knownBinaryExtensions = ["dylib", "so", "bundle"]

    // If it's a known binary extension, assume it's a binary (faster than reading file)
    if knownBinaryExtensions.contains(pathExtension) {
        return true
    }

    // Special handling for bundle structures that might contain binaries
    // (.appex, .xpc, .framework are bundles, but we want to check their executables inside)
    let bundleExtensions = ["appex", "xpc", "framework"]
    if bundleExtensions.contains(pathExtension) {
        // These are bundles - the enumerator will traverse into them
        // and find the actual executable inside
        return false
    }

    // For other files, check magic numbers - use FileHandle to read only 4 bytes
    guard let fileHandle = try? FileHandle(forReadingFrom: url) else {
        return false
    }

    defer {
        try? fileHandle.close()
    }

    guard let magicData = try? fileHandle.read(upToCount: 4), magicData.count == 4 else {
        return false
    }

    let bytes = [UInt8](magicData)
    let magic = bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }

    return magic == MachOSafety.fatMagic
        || magic == MachOSafety.fatMagicSwapped
        || magic == MachOSafety.fatMagic64
        || magic == MachOSafety.fatMagic64Swapped
        || magic == 0xfeedfacf
        || magic == 0xcffaedfe
        || magic == 0xfeedface
        || magic == 0xcefaedfe
}

// Helper function to thin a binary using Mach-O APIs
public func thinBinaryUsingMachO(executablePath: String) -> Bool {
    // Find the app bundle path by searching up the directory tree
    let executableURL = URL(fileURLWithPath: executablePath).standardizedFileURL
    let appBundlePath = findAppBundlePath(from: executableURL)

    guard AppBundleMutationSafety.inspect(appBundlePath).allowsMutation,
          AppBundleMutationSafety.contains(executableURL, in: appBundlePath),
          let values = try? executableURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
          ),
          values.isRegularFile == true,
          values.isSymbolicLink != true else {
        return false
    }

    return thinMachOBinary(
        at: executableURL,
        targetCPUType: MachOSafety.currentCPUType,
        appBundlePath: appBundlePath
    )
}

func thinMachOBinary(
    at executableURL: URL,
    targetCPUType: UInt32,
    appBundlePath: URL? = nil
) -> Bool {
    autoreleasepool {
        do {
            let layout = try MachOSafety.inspect(executableURL)
            guard case .fat(let architectures, let fileSize) = layout,
                  architectures.count > 1 else {
                return false
            }
            let targetArchitectures = architectures.filter {
                $0.cpuType == targetCPUType
            }
            guard targetArchitectures.count == 1,
                  let targetArchitecture = targetArchitectures.first,
                  UInt64(targetArchitecture.size) < fileSize else {
                return false
            }

            if let appBundlePath {
                try AppBundleMutationSafety.requireUnsignedMutationTargets(
                    [executableURL],
                    in: appBundlePath
                )
            }

            let prepared = try MachOSafety.prepareSliceReplacement(
                at: executableURL,
                architecture: targetArchitecture,
                expectedFileSize: fileSize
            )
            do {
                if let appBundlePath {
                    try AppBundleMutationSafety.requireUnsignedMutationTargets(
                        [executableURL],
                        in: appBundlePath
                    )
                }
                try MachOSafety.commit(prepared)
            } catch {
                MachOSafety.discard(prepared)
                throw error
            }

            if let appBundlePath,
               !appBundlePath.path.isEmpty,
               appBundlePath.path != "/" {
                try? FileManager.default.setAttributes(
                    [.modificationDate: Date()],
                    ofItemAtPath: appBundlePath.path
                )
            }

            return true
        } catch {
            print("Mach-O Error: \(error.localizedDescription)")
            return false
        }
    }
}

// Get the size of different architecture slices in a Mach-O binary
public func getArchitectureSliceSizes(from executablePath: String) throws -> (arm: UInt32, intel: UInt32, full: UInt32)? {
    guard !executablePath.isEmpty else {
        throw NSError(domain: "LipoError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Empty executable path"])
    }

    return try autoreleasepool {
        let layout = try MachOSafety.inspect(URL(fileURLWithPath: executablePath))

        switch layout {
        case .fat(let architectures, let fileSize):
            guard fileSize <= UInt64(UInt32.max) else {
                throw MachOInspectionError.fileTooLarge
            }
            let armSize = architectures.first(where: {
                $0.cpuType == MachOSafety.arm64CPUType
            })?.size ?? 0
            let intelSize = architectures.first(where: {
                $0.cpuType == MachOSafety.x86_64CPUType
            })?.size ?? 0
            return (arm: armSize, intel: intelSize, full: UInt32(fileSize))

        case .thin(let cpuType, let fileSize):
            guard fileSize <= UInt64(UInt32.max) else {
                throw MachOInspectionError.fileTooLarge
            }
            let fullSize = UInt32(fileSize)
            if cpuType == MachOSafety.arm64CPUType {
                return (arm: fullSize, intel: 0, full: fullSize)
            }
            if cpuType == MachOSafety.x86_64CPUType {
                return (arm: 0, intel: fullSize, full: fullSize)
            }
            return (arm: 0, intel: 0, full: fullSize)
        }
    }
}



// Get size of files (logical size - matches Finder)
public func totalSizeOnDisk(for paths: [URL]) -> Int64 {
    let fileManager = FileManager.default
    var totalFileSize: Int64 = 0

    for url in paths {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            let keys: [URLResourceKey] = [.fileSizeKey]
            if isDirectory.boolValue {

                //MARK: Directory Size
                if let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: keys, errorHandler: nil) {
                    for case let fileURL as URL in enumerator {
                        do {
                            if let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                                totalFileSize += Int64(size)
                            }
                        }
                    }
                }
            } else {
                //MARK: File Size
                do {
                    if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                        totalFileSize += Int64(size)
                    }
                }
            }
        }
    }

    return totalFileSize
}



public func totalSizeOnDisk(for path: URL) -> Int64 {
    return totalSizeOnDisk(for: [path])
}
