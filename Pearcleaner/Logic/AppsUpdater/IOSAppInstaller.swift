//
//  IOSAppInstaller.swift
//  Pearcleaner
//
//  Created by Alin Lupascu on 11/12/25.
//  Modified for the independently maintained Pearcleaner fork.
//

import Foundation

enum IOSAppInstallerError: Error, LocalizedError {
    case updatesUnavailable

    var errorDescription: String? {
        switch self {
        case .updatesUnavailable:
            return "iPhone and iPad app updates must be installed using the App Store."
        }
    }
}

/// Pearcleaner previously attempted to reconstruct and replace iOS app
/// wrappers from an IPA. The App Store currently supplies an incompatible
/// variant, and the reconstruction path could not preserve Apple's protected
/// metadata safely. Keep this API as a fail-closed boundary for older callers.
enum IOSAppInstaller {
    static let isInstallationSupported = false

    static func installIOSApp(
        ipaPath _: String,
        adamID _: UInt64,
        existingAppPath _: URL,
        progress: @escaping (Double, String) -> Void
    ) async throws {
        progress(0.0, "Update in App Store")
        throw IOSAppInstallerError.updatesUnavailable
    }
}
