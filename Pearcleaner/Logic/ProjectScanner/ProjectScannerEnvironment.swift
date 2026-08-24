import Foundation
import ProjectScannerCore

enum ScannerEnvironmentError: Error, CaseIterable, Sendable, Equatable {
    case locationUnavailable
    case privateStateUnavailable
}

protocol ApplicationSupportLocating: Sendable {
    func url(
        for directory: FileManager.SearchPathDirectory,
        in domain: FileManager.SearchPathDomainMask,
        appropriateFor url: URL?,
        create: Bool
    ) throws -> URL
}

private struct SystemApplicationSupportLocator: ApplicationSupportLocating {
    func url(
        for directory: FileManager.SearchPathDirectory,
        in domain: FileManager.SearchPathDomainMask,
        appropriateFor url: URL?,
        create: Bool
    ) throws -> URL {
        try FileManager.default.url(
            for: directory,
            in: domain,
            appropriateFor: url,
            create: create
        )
    }
}

struct ProjectScannerEnvironment: ScannerEnvironmentProviding, Sendable {
    private let locator: any ApplicationSupportLocating

    init(locator: any ApplicationSupportLocating = SystemApplicationSupportLocator()) {
        self.locator = locator
    }

    func privateStateParent() throws -> PrivateStateParentCapability {
        let url: URL
        do {
            url = try locator.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            )
        } catch {
            throw ScannerEnvironmentError.locationUnavailable
        }
        do {
            return try PrivateStateParentCapability.open(applicationSupportURL: url)
        } catch {
            throw ScannerEnvironmentError.privateStateUnavailable
        }
    }
}
