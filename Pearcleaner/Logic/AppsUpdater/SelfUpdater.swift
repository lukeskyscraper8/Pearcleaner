//
//  SelfUpdater.swift
//  Pearcleaner
//
//  Modified for the independently maintained Pearcleaner fork.
//

import AppKit
import CryptoKit
import Foundation
import Security
import SwiftUI
import AlinFoundation

struct SelfUpdateAsset: Decodable, Identifiable, Sendable {
    let id: Int
    let name: String
    let contentType: String
    let size: Int
    let digest: String?
    let browserDownloadURL: URL

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case contentType = "content_type"
        case size
        case digest
        case browserDownloadURL = "browser_download_url"
    }
}

struct SelfUpdateRelease: Decodable, Identifiable, Sendable {
    let id: Int
    let tagName: String
    let name: String
    let body: String
    let draft: Bool
    let prerelease: Bool
    let assets: [SelfUpdateAsset]

    enum CodingKeys: String, CodingKey {
        case id
        case tagName = "tag_name"
        case name
        case body
        case draft
        case prerelease
        case assets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        tagName = try container.decode(String.self, forKey: .tagName)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
        draft = try container.decode(Bool.self, forKey: .draft)
        prerelease = try container.decode(Bool.self, forKey: .prerelease)
        assets = try container.decode([SelfUpdateAsset].self, forKey: .assets)
    }
}

private struct SelfUpdateAnnouncement: Decodable, Sendable {
    let features: [String]
    let caveats: [String]?
}

enum SelfUpdateValidation {
    private static let expectedArchiveRoot = "Pearcleaner.app"
    private static let maximumArchiveEntries = 100_000
    private static let maximumUncompressedBytes: UInt64 = 2 * 1_024 * 1_024 * 1_024

    struct ArchiveMetrics: Equatable {
        let entryCount: Int
        let uncompressedBytes: UInt64
    }

    static func normalizeVersion(_ version: String) -> String {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.first == "v" || trimmed.first == "V" {
            return String(trimmed.dropFirst())
        }
        return trimmed
    }

    static func isNewer(remote: String, than installed: String) -> Bool {
        let remoteVersion = Version(
            versionNumber: normalizeVersion(remote),
            buildNumber: nil
        )
        let installedVersion = Version(
            versionNumber: normalizeVersion(installed),
            buildNumber: nil
        )
        return !remoteVersion.isEmpty
            && !installedVersion.isEmpty
            && remoteVersion > installedVersion
    }

    static func normalizedSHA256Digest(_ digest: String?) -> String? {
        guard let digest else { return nil }
        let components = digest.lowercased().split(separator: ":", maxSplits: 1)
        guard components.count == 2,
              components[0] == "sha256",
              components[1].count == 64,
              components[1].allSatisfy({ $0.isHexDigit }) else {
            return nil
        }
        return String(components[1])
    }

    static func archiveContainsOnlyExpectedApp(_ entries: [String]) -> Bool {
        guard !entries.isEmpty else { return false }

        return entries.allSatisfy { entry in
            guard !entry.isEmpty,
                  !entry.unicodeScalars.contains(where: {
                      CharacterSet.controlCharacters.contains($0)
                  }),
                  !entry.hasPrefix("/"),
                  !entry.contains("\\"),
                  !entry.contains(":"),
                  !entry.contains("//"),
                  entry == expectedArchiveRoot
                    || entry == "\(expectedArchiveRoot)/"
                    || entry.hasPrefix("\(expectedArchiveRoot)/") else {
                return false
            }

            var components = entry.split(
                separator: "/",
                omittingEmptySubsequences: false
            )
            if components.last?.isEmpty == true {
                components.removeLast()
            }

            return !components.isEmpty
                && components.allSatisfy {
                    !$0.isEmpty && $0 != "." && $0 != ".."
                }
        }
    }

    static func archiveMetrics(
        fromZipInfoSummary summary: String
    ) -> ArchiveMetrics? {
        guard !summary.isEmpty,
              summary.rangeOfCharacter(from: .newlines) == nil,
              let expression = try? NSRegularExpression(
                  pattern: #"^([0-9]+) files?, ([0-9]+) bytes uncompressed, ([0-9]+) bytes compressed:  +(-?[0-9]+(?:\.[0-9]+)?|---)%$"#
              ) else {
            return nil
        }

        let fullRange = NSRange(summary.startIndex..<summary.endIndex, in: summary)
        guard let match = expression.firstMatch(
            in: summary,
            range: fullRange
        ),
              match.range == fullRange,
              let entryRange = Range(match.range(at: 1), in: summary),
              let byteRange = Range(match.range(at: 2), in: summary),
              let entryCount = Int(summary[entryRange]),
              let uncompressedBytes = UInt64(summary[byteRange]),
              entryCount > 0,
              entryCount <= maximumArchiveEntries,
              uncompressedBytes <= maximumUncompressedBytes else {
            return nil
        }

        return ArchiveMetrics(
            entryCount: entryCount,
            uncompressedBytes: uncompressedBytes
        )
    }

    static func archivePreflightIsSafe(
        entries: [String],
        zipInfoSummary: String
    ) -> Bool {
        guard let metrics = archiveMetrics(fromZipInfoSummary: zipInfoSummary),
              metrics.entryCount == entries.count else {
            return false
        }
        return archiveContainsOnlyExpectedApp(entries)
    }

    static func validatedAppURL(in extractionDirectory: URL) -> URL? {
        guard let topLevelEntries = try? FileManager.default.contentsOfDirectory(
            at: extractionDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ),
              topLevelEntries.count == 1,
              let candidate = topLevelEntries.first,
              candidate.lastPathComponent == expectedArchiveRoot,
              let values = try? candidate.resourceValues(
                  forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
              ),
              values.isDirectory == true,
              values.isSymbolicLink != true else {
            return nil
        }

        let resolvedExtraction = extractionDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let resolvedCandidate = candidate
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard resolvedCandidate.deletingLastPathComponent().path == resolvedExtraction.path else {
            return nil
        }

        return candidate
    }

    static func isTrustedGitHubHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "github.com"
            || host.hasSuffix(".github.com")
            || host == "githubusercontent.com"
            || host.hasSuffix(".githubusercontent.com")
    }

    static func bundleMetadata(
        at appURL: URL
    ) -> (identifier: String, version: String)? {
        let infoURL = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let propertyList = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil
              ),
              let dictionary = propertyList as? [String: Any],
              let identifier = dictionary["CFBundleIdentifier"] as? String,
              let version = dictionary["CFBundleShortVersionString"] as? String else {
            return nil
        }
        return (identifier, version)
    }
}

private enum SelfUpdateError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)
    case unexpectedHost
    case invalidContentType
    case responseTooLarge
    case noRelease
    case invalidVersion(String)
    case noSuitableAsset
    case missingDigest
    case invalidDigest
    case sizeMismatch(expected: Int, actual: Int)
    case digestMismatch
    case extractionFailed(String)
    case invalidArchive
    case invalidBundleIdentifier
    case versionMismatch(expected: String, actual: String)
    case signatureValidationFailed(String)
    case destinationNotWritable
    case replacementFailed(String)
    case rollbackFailed(update: String, rollback: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The update server returned an invalid response."
        case .httpStatus(let status):
            return "The update server returned HTTP \(status)."
        case .unexpectedHost:
            return "The update download redirected to an unexpected host."
        case .invalidContentType:
            return "The update server returned an unexpected content type."
        case .responseTooLarge:
            return "The update response was unexpectedly large."
        case .noRelease:
            return "No eligible release is available."
        case .invalidVersion(let version):
            return "The release has an invalid version: \(version)."
        case .noSuitableAsset:
            return "The release has no notarized Pearcleaner ZIP."
        case .missingDigest:
            return "The release asset is missing GitHub SHA-256 integrity metadata."
        case .invalidDigest:
            return "The release asset has invalid SHA-256 integrity metadata."
        case .sizeMismatch(let expected, let actual):
            return "The downloaded update size is \(actual) bytes; expected \(expected) bytes."
        case .digestMismatch:
            return "The downloaded update failed its SHA-256 integrity check."
        case .extractionFailed(let message):
            return "The update archive could not be extracted: \(message)"
        case .invalidArchive:
            return "The update archive does not contain exactly one Pearcleaner app."
        case .invalidBundleIdentifier:
            return "The downloaded app has the wrong bundle identifier."
        case .versionMismatch(let expected, let actual):
            return "The downloaded app is version \(actual); expected \(expected)."
        case .signatureValidationFailed(let message):
            return "The downloaded app failed signature validation: \(message)"
        case .destinationNotWritable:
            return "Pearcleaner cannot update in place from this location. Move it to a writable Applications folder or install the verified update manually."
        case .replacementFailed(let message):
            return "The update could not replace the current app: \(message)"
        case .rollbackFailed(let update, let rollback):
            return "The update failed (\(update)) and rollback also failed (\(rollback)). The backup was preserved beside the app."
        }
    }
}

private enum SelfUpdateInstaller {
    private static let expectedBundleIdentifier = "com.lukerow.Pearcleaner"
    private static let expectedTeamIdentifier = "68583N3MNF"
    private static let maximumArchiveSize = 500 * 1_024 * 1_024

    static func preflightReplacement() throws {
        let parent = Bundle.main.bundleURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw SelfUpdateError.destinationNotWritable
        }
    }

    static func selectAsset(from release: SelfUpdateRelease) throws -> SelfUpdateAsset {
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Pearcleaner"
        let prefix = "\(appName.lowercased())-"

        let candidates = release.assets.filter {
            let name = $0.name.lowercased()
            return name.hasPrefix(prefix)
                && name.hasSuffix(".zip")
                && name.contains("notarized")
                && ["application/zip", "application/octet-stream"].contains(
                    $0.contentType.lowercased()
                )
                && $0.size > 0
                && $0.size <= maximumArchiveSize
                && $0.browserDownloadURL.host?.lowercased() == "github.com"
        }
        guard candidates.count == 1, let asset = candidates.first else {
            throw SelfUpdateError.noSuitableAsset
        }

        return asset
    }

    static func download(
        asset: SelfUpdateAsset,
        session: URLSession = .shared
    ) async throws -> URL {
        guard let expectedDigest = SelfUpdateValidation.normalizedSHA256Digest(
            asset.digest
        ) else {
            throw asset.digest == nil ? SelfUpdateError.missingDigest : SelfUpdateError.invalidDigest
        }

        var request = URLRequest(url: asset.browserDownloadURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 120
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")

        let (downloadedURL, response) = try await session.download(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SelfUpdateError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw SelfUpdateError.httpStatus(httpResponse.statusCode)
        }
        guard SelfUpdateValidation.isTrustedGitHubHost(httpResponse.url?.host) else {
            throw SelfUpdateError.unexpectedHost
        }
        guard let contentType = httpResponse.value(
            forHTTPHeaderField: "Content-Type"
        )?.lowercased(),
              contentType.contains("application/octet-stream")
                || contentType.contains("application/zip") else {
            throw SelfUpdateError.invalidContentType
        }

        let values = try downloadedURL.resourceValues(forKeys: [.fileSizeKey])
        let actualSize = values.fileSize ?? 0
        guard actualSize == asset.size else {
            throw SelfUpdateError.sizeMismatch(expected: asset.size, actual: actualSize)
        }

        guard try sha256(of: downloadedURL) == expectedDigest else {
            throw SelfUpdateError.digestMismatch
        }

        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Pearcleaner-SelfUpdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workDirectory,
            withIntermediateDirectories: true
        )
        let archiveURL = workDirectory.appendingPathComponent(asset.name)

        do {
            try FileManager.default.moveItem(at: downloadedURL, to: archiveURL)
            return archiveURL
        } catch {
            try? FileManager.default.removeItem(at: workDirectory)
            throw error
        }
    }

    static func extractAndValidate(
        archiveURL: URL,
        release: SelfUpdateRelease
    ) throws -> URL {
        let workDirectory = archiveURL.deletingLastPathComponent()
        let extractionDirectory = workDirectory.appendingPathComponent("Extracted", isDirectory: true)

        let summaryResult = runProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/zipinfo"),
            arguments: ["-t", archiveURL.path],
            forceCLocale: true
        )
        let listingResult = runProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/zipinfo"),
            arguments: ["-1", archiveURL.path],
            forceCLocale: true
        )
        let archiveEntries = listingResult.output.components(separatedBy: .newlines)
        guard summaryResult.status == 0,
              listingResult.status == 0,
              SelfUpdateValidation.archivePreflightIsSafe(
                  entries: archiveEntries,
                  zipInfoSummary: summaryResult.output
              ) else {
            throw SelfUpdateError.invalidArchive
        }

        try FileManager.default.createDirectory(
            at: extractionDirectory,
            withIntermediateDirectories: true
        )

        let extractionResult = runProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-xk", archiveURL.path, extractionDirectory.path]
        )
        guard extractionResult.status == 0 else {
            throw SelfUpdateError.extractionFailed(extractionResult.output)
        }

        guard let candidate = SelfUpdateValidation.validatedAppURL(
            in: extractionDirectory
        ) else {
            throw SelfUpdateError.invalidArchive
        }

        let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
        let resolvedExtraction = extractionDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedCandidate.path.hasPrefix(resolvedExtraction.path + "/") else {
            throw SelfUpdateError.invalidArchive
        }

        try validateBundle(candidate, release: release)
        return candidate
    }

    static func replaceCurrentApplication(
        with candidate: URL,
        release: SelfUpdateRelease
    ) throws {
        try preflightReplacement()

        let fileManager = FileManager.default
        let currentApp = Bundle.main.bundleURL.standardizedFileURL
        let parent = currentApp.deletingLastPathComponent()
        let updateName = ".\(currentApp.lastPathComponent).update-\(UUID().uuidString)"
        let backupName = ".\(currentApp.lastPathComponent).backup-\(UUID().uuidString)"
        let preparedApp = parent.appendingPathComponent(updateName, isDirectory: true)
        let backupApp = parent.appendingPathComponent(backupName, isDirectory: true)

        do {
            try fileManager.copyItem(at: candidate, to: preparedApp)
            try validateBundle(preparedApp, release: release)

            _ = try fileManager.replaceItemAt(
                currentApp,
                withItemAt: preparedApp,
                backupItemName: backupName,
                options: [.withoutDeletingBackupItem]
            )

            guard fileManager.fileExists(atPath: currentApp.path) else {
                throw SelfUpdateError.replacementFailed("The replacement app is missing.")
            }
            try validateBundle(currentApp, release: release)
        } catch {
            let updateDescription = error.localizedDescription

            do {
                if fileManager.fileExists(atPath: backupApp.path) {
                    if fileManager.fileExists(atPath: currentApp.path) {
                        try fileManager.removeItem(at: currentApp)
                    }
                    try fileManager.moveItem(at: backupApp, to: currentApp)
                }
                if fileManager.fileExists(atPath: preparedApp.path) {
                    try fileManager.removeItem(at: preparedApp)
                }
            } catch {
                throw SelfUpdateError.rollbackFailed(
                    update: updateDescription,
                    rollback: error.localizedDescription
                )
            }

            throw SelfUpdateError.replacementFailed(updateDescription)
        }

        if fileManager.fileExists(atPath: backupApp.path) {
            try? fileManager.removeItem(at: backupApp)
        }
    }

    static func cleanup(archiveURL: URL) {
        try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent())
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_024 * 1_024), !data.isEmpty {
            hasher.update(data: data)
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func validateBundle(
        _ appURL: URL,
        release: SelfUpdateRelease
    ) throws {
        // Read the plist directly. Foundation caches Bundle instances by URL,
        // so Bundle(url:) can return the old version after an in-place update.
        guard let metadata = SelfUpdateValidation.bundleMetadata(at: appURL),
              metadata.identifier == expectedBundleIdentifier else {
            throw SelfUpdateError.invalidBundleIdentifier
        }

        let actualVersion = metadata.version
        let expectedVersion = SelfUpdateValidation.normalizeVersion(release.tagName)
        let actual = Version(
            versionNumber: SelfUpdateValidation.normalizeVersion(actualVersion),
            buildNumber: nil
        )
        let expected = Version(versionNumber: expectedVersion, buildNumber: nil)
        guard !actual.isEmpty, !expected.isEmpty, actual == expected else {
            throw SelfUpdateError.versionMismatch(
                expected: expectedVersion,
                actual: actualVersion
            )
        }

        var requirement: SecRequirement?
        let requirementText = """
        identifier "\(expectedBundleIdentifier)" and anchor apple generic and certificate leaf[subject.OU] = "\(expectedTeamIdentifier)"
        """
        guard SecRequirementCreateWithString(
            requirementText as CFString,
            [],
            &requirement
        ) == errSecSuccess, let requirement else {
            throw SelfUpdateError.signatureValidationFailed(
                "Could not create the expected signing requirement."
            )
        }

        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else {
            throw SelfUpdateError.signatureValidationFailed(
                "Could not inspect the application signature."
            )
        }

        let validationFlags = SecCSFlags(
            rawValue: kSecCSCheckAllArchitectures
                | kSecCSCheckNestedCode
                | kSecCSStrictValidate
        )
        let signatureStatus = SecStaticCodeCheckValidity(
            staticCode,
            validationFlags,
            requirement
        )
        guard signatureStatus == errSecSuccess else {
            let message = SecCopyErrorMessageString(signatureStatus, nil) as String?
            throw SelfUpdateError.signatureValidationFailed(
                message ?? "Security framework returned \(signatureStatus)."
            )
        }

        let gatekeeperResult = runProcess(
            executableURL: URL(fileURLWithPath: "/usr/sbin/spctl"),
            arguments: ["--assess", "--type", "execute", "--verbose=2", appURL.path]
        )
        guard gatekeeperResult.status == 0 else {
            throw SelfUpdateError.signatureValidationFailed(
                gatekeeperResult.output.isEmpty
                    ? "Gatekeeper rejected the application."
                    : gatekeeperResult.output
            )
        }
    }

    private static func runProcess(
        executableURL: URL,
        arguments: [String],
        forceCLocale: Bool = false
    ) -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        if forceCLocale {
            var environment = ProcessInfo.processInfo.environment
            environment["LC_ALL"] = "C"
            environment["LANG"] = "C"
            process.environment = environment
        }
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (
                process.terminationStatus,
                String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            )
        } catch {
            return (-1, error.localizedDescription)
        }
    }
}

@MainActor
final class Updater: ObservableObject {
    @Published var updateAvailable = false
    @Published var sheet = false
    @Published var releases: [SelfUpdateRelease] = []
    @Published var announcementAvailable = false
    @Published var showAnnouncementSheet = false
    @Published var progressBar: (String, Double) = ("", 0)
    @Published var updateError: String?
    @Published var isInstalling = false
    @Published var nextUpdateDate: Date {
        didSet {
            defaults.set(
                nextUpdateDate.timeIntervalSinceReferenceDate,
                forKey: Self.defaultsNextUpdateDateKey
            )
        }
    }
    @Published var updateFrequency: UpdateFrequency {
        didSet {
            defaults.set(updateFrequency.rawValue, forKey: Self.defaultsFrequencyKey)
            setNextUpdateDate()
        }
    }

    let owner: String
    let repo: String

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.0.0"
    }

    private static let defaultsNextUpdateDateKey = "alinfoundation.updater.nextUpdateDate"
    private static let defaultsFrequencyKey = "alinfoundation.updater.updateFrequency"
    private static let defaultsLastViewedVersionKey = "alinfoundation.updater.lastViewedVersion"

    private let defaults = UserDefaults.standard
    private var announcement: SelfUpdateAnnouncement?
    private var forceRedownload = false

    init(owner: String, repo: String) {
        self.owner = owner
        self.repo = repo

        if let rawFrequency = UserDefaults.standard.string(
            forKey: Self.defaultsFrequencyKey
        ), let frequency = UpdateFrequency(rawValue: rawFrequency) {
            updateFrequency = frequency
        } else {
            updateFrequency = .daily
        }

        let storedDate = UserDefaults.standard.double(
            forKey: Self.defaultsNextUpdateDateKey
        )
        nextUpdateDate = storedDate == 0
            ? Date()
            : Date(timeIntervalSinceReferenceDate: storedDate)

        Task { [weak self] in
            await self?.performInitialChecks()
        }
    }

    func checkForUpdates(
        sheet shouldShowSheet: Bool = false,
        force: Bool = false,
        forceUpdate: Bool = false
    ) {
        guard updateFrequency != .none || force || forceUpdate else { return }
        self.forceRedownload = forceUpdate
        updateError = nil

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.loadReleases(updateAvailability: true)
            } catch {
                self.updateError = error.localizedDescription
                self.updateAvailable = false
                self.forceRedownload = false
            }
            if shouldShowSheet {
                self.sheet = true
            }
        }
    }

    func checkReleaseNotes() {
        Task { [weak self] in
            do {
                try await self?.loadReleases(updateAvailability: false)
            } catch {
                self?.updateError = error.localizedDescription
            }
        }
    }

    func downloadUpdate() {
        guard !isInstalling else { return }
        guard let release = releases.first else {
            updateError = SelfUpdateError.noRelease.localizedDescription
            return
        }
        do {
            try SelfUpdateInstaller.preflightReplacement()
        } catch {
            updateError = error.localizedDescription
            return
        }

        isInstalling = true
        updateError = nil
        progressBar = ("Selecting verified release asset", 0.05)

        Task { [weak self] in
            guard let self else { return }
            var archiveURL: URL?

            do {
                let asset = try SelfUpdateInstaller.selectAsset(from: release)
                self.progressBar = ("Downloading update", 0.15)
                let downloadedArchive = try await SelfUpdateInstaller.download(asset: asset)
                archiveURL = downloadedArchive

                self.progressBar = ("Verifying archive and application signature", 0.45)
                let candidate = try await Task.detached {
                    try SelfUpdateInstaller.extractAndValidate(
                        archiveURL: downloadedArchive,
                        release: release
                    )
                }.value

                self.progressBar = ("Installing with rollback protection", 0.8)
                try await Task.detached {
                    try SelfUpdateInstaller.replaceCurrentApplication(
                        with: candidate,
                        release: release
                    )
                }.value

                SelfUpdateInstaller.cleanup(archiveURL: downloadedArchive)
                archiveURL = nil
                self.progressBar = ("Update completed", 1)
                self.updateAvailable = false
                self.forceRedownload = false
                self.setNextUpdateDate()
            } catch {
                if let archiveURL {
                    SelfUpdateInstaller.cleanup(archiveURL: archiveURL)
                }
                self.progressBar = ("Update failed", 0)
                self.updateError = error.localizedDescription
            }

            self.isInstalling = false
        }
    }

    @ViewBuilder
    func getUpdateView() -> some View {
        SelfUpdateView(updater: self)
    }

    @ViewBuilder
    func getAnnouncementView() -> some View {
        SelfUpdateAnnouncementView(updater: self)
    }

    func checkAndUpdateIfNeeded() {
        guard updateFrequency != .none else { return }
        if Date() >= nextUpdateDate {
            checkForUpdates()
        } else {
            checkReleaseNotes()
        }
    }

    func setNextUpdateDate() {
        let calendar = Calendar.current
        switch updateFrequency {
        case .daily:
            nextUpdateDate = calendar.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        case .weekly:
            nextUpdateDate = calendar.date(byAdding: .day, value: 7, to: Date()) ?? Date()
        case .monthly:
            nextUpdateDate = calendar.date(byAdding: .month, value: 1, to: Date()) ?? Date()
        case .none:
            nextUpdateDate = .distantFuture
        }
    }

    func resetAnnouncementAlert() {
        checkForAnnouncement(force: true)
    }

    func markAnnouncementAsViewed() {
        defaults.set(currentVersion, forKey: Self.defaultsLastViewedVersionKey)
        announcementAvailable = false
    }

    fileprivate var announcementFeatures: [String] {
        announcement?.features ?? ["No announcement available for this version."]
    }

    fileprivate var announcementCaveats: [String] {
        announcement?.caveats ?? []
    }

    private func performInitialChecks() async {
        checkAndUpdateIfNeeded()
        checkForAnnouncement()
    }

    private func loadReleases(updateAvailability: Bool) async throws {
        guard let url = URL(
            string: "https://api.github.com/repos/\(owner)/\(repo)/releases"
        ) else {
            throw SelfUpdateError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateAPIResponse(response, dataCount: data.count)

        let decoded = try JSONDecoder().decode([SelfUpdateRelease].self, from: data)
        let eligible = decoded
            .filter { !$0.draft && !$0.prerelease }
            .filter {
                let version = Version(
                    versionNumber: SelfUpdateValidation.normalizeVersion($0.tagName),
                    buildNumber: nil
                )
                return !version.isEmpty
            }
            .sorted {
                Version(
                    versionNumber: SelfUpdateValidation.normalizeVersion($0.tagName),
                    buildNumber: nil
                ) > Version(
                    versionNumber: SelfUpdateValidation.normalizeVersion($1.tagName),
                    buildNumber: nil
                )
            }

        guard let latest = eligible.first else {
            throw SelfUpdateError.noRelease
        }

        releases = Array(eligible.prefix(3))
        guard updateAvailability else {
            return
        }

        let installed = Version(
            versionNumber: SelfUpdateValidation.normalizeVersion(currentVersion),
            buildNumber: nil
        )
        let available = Version(
            versionNumber: SelfUpdateValidation.normalizeVersion(latest.tagName),
            buildNumber: nil
        )
        guard !installed.isEmpty, !available.isEmpty else {
            throw SelfUpdateError.invalidVersion(latest.tagName)
        }

        updateAvailable = forceRedownload || available > installed
        setNextUpdateDate()
    }

    private func checkForAnnouncement(force: Bool = false) {
        guard updateFrequency != .none || force else { return }
        guard let url = URL(
            string: "https://api.github.com/repos/\(owner)/\(repo)/contents/announcements.json"
        ) else {
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 30
                request.setValue(
                    "application/vnd.github.raw+json",
                    forHTTPHeaderField: "Accept"
                )
                request.setValue(
                    "2022-11-28",
                    forHTTPHeaderField: "X-GitHub-Api-Version"
                )

                let (data, response) = try await URLSession.shared.data(for: request)
                try self.validateAPIResponse(response, dataCount: data.count)
                let entries = try JSONDecoder().decode(
                    [String: SelfUpdateAnnouncement].self,
                    from: data
                )
                self.announcement = entries[self.currentVersion]
                let lastViewed = self.defaults.string(
                    forKey: Self.defaultsLastViewedVersionKey
                )
                self.announcementAvailable = force
                    || (self.announcement != nil && lastViewed != self.currentVersion)
                if force {
                    self.showAnnouncementSheet = true
                }
            } catch {
                printOS(
                    "Updater announcement check failed: \(error.localizedDescription)",
                    category: LogCategory.updater
                )
            }
        }
    }

    private func validateAPIResponse(
        _ response: URLResponse,
        dataCount: Int
    ) throws {
        guard dataCount <= 10 * 1_024 * 1_024 else {
            throw SelfUpdateError.responseTooLarge
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SelfUpdateError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw SelfUpdateError.httpStatus(httpResponse.statusCode)
        }
        guard httpResponse.url?.host?.lowercased() == "api.github.com" else {
            throw SelfUpdateError.unexpectedHost
        }
        guard let contentType = httpResponse.value(
            forHTTPHeaderField: "Content-Type"
        )?.lowercased(),
              contentType.contains("application/json")
                || contentType.contains("application/vnd.github.raw+json") else {
            throw SelfUpdateError.invalidContentType
        }
    }

}

private struct SelfUpdateView: View {
    @ObservedObject var updater: Updater
    @Environment(\.dismiss) private var dismiss

    private var latestRelease: SelfUpdateRelease? {
        updater.releases.first
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Installed: v\(updater.currentVersion)")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(updater.updateAvailable ? "Update Available" : "Pearcleaner Update")
                    .font(.title2.bold())
                Spacer()
                Text("GitHub: v\(latestRelease?.tagName ?? "—")")
                    .foregroundStyle(.secondary)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let release = latestRelease {
                        Text(release.name.isEmpty ? "Version \(release.tagName)" : release.name)
                            .font(.headline)
                        Text(.init(release.body))
                            .textSelection(.enabled)
                    } else if updater.updateError == nil {
                        ProgressView("Checking GitHub releases…")
                    }

                    if let error = updater.updateError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }

            if updater.isInstalling || updater.progressBar.1 > 0 {
                ProgressView(
                    value: updater.progressBar.1,
                    total: 1,
                    label: { Text(updater.progressBar.0) },
                    currentValueLabel: {
                        Text("\(Int(updater.progressBar.1 * 100))%")
                    }
                )
                .padding(.horizontal)
            }

            Divider()

            HStack {
                if updater.progressBar.1 == 1 {
                    Button("Restart") {
                        relaunchApp(afterDelay: 1)
                    }
                } else if updater.updateAvailable {
                    Button("Update") {
                        updater.downloadUpdate()
                    }
                    .disabled(updater.isInstalling)
                }

                Spacer()

                Button("Close") {
                    dismiss()
                }
            }
            .padding()
        }
        .frame(width: 620, height: 420)
    }
}

struct UpdaterFrequencyView: View {
    @ObservedObject var updater: Updater

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text("\(Bundle.main.name) will check for updates")
                    .font(.callout)
                if updater.updateFrequency != .none {
                    Text("Next update check: \(formattedDate(updater.nextUpdateDate))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Picker("", selection: $updater.updateFrequency) {
                ForEach(UpdateFrequency.allCases) { frequency in
                    Text(frequency.rawValue.localized()).tag(frequency)
                }
            }
            .buttonStyle(.borderless)
        }
    }
}

struct UpdaterRecentReleasesView: View {
    @ObservedObject var updater: Updater

    var body: some View {
        Group {
            if updater.releases.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No Releases to Display")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(updater.releases) { release in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(release.tagName)
                                    .font(.headline)
                                Text(.init(release.body))
                                    .textSelection(.enabled)
                                Divider()
                            }
                        }
                    }
                    .padding()
                }
            }
        }
    }
}

private struct SelfUpdateAnnouncementView: View {
    @ObservedObject var updater: Updater
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("What’s New in Pearcleaner \(updater.currentVersion)")
                .font(.title2.bold())

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(updater.announcementFeatures, id: \.self) { feature in
                        Label(feature, systemImage: "sparkles")
                    }
                    ForEach(updater.announcementCaveats, id: \.self) { caveat in
                        Label(caveat, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                Button("Done") {
                    updater.markAnnouncementAsViewed()
                    dismiss()
                }
            }
        }
        .padding()
        .frame(width: 520, height: 360)
        .onDisappear {
            updater.markAnnouncementAsViewed()
        }
    }
}
