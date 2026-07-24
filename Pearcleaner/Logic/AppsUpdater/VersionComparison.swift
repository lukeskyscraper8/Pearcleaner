//
//  VersionComparison.swift
//  Pearcleaner
//
//  Created by Alin Lupascu on 10/22/25.
//
//  Based on Sparkle Framework's version comparison algorithm
//  License: MIT
//
//  Modified for the independently maintained Pearcleaner fork.

import Foundation

/// A version struct that supports arbitrary-length version numbers (2, 3, 4+ components)
/// Designed specifically for Sparkle update feeds which use wildly inconsistent formats
struct Version: Comparable {

    /// The user-facing version number (e.g., "1.2025.288.13", "1.0.0-beta")
    let versionNumber: String?

    /// The internal build number (e.g., "20251021184832000", "1234")
    let buildNumber: String?

    /// Flag indicating whether both version and build numbers are unavailable
    var isEmpty: Bool {
        let versionNumberComponents = versionNumber?.components().compactMap({ $0.plainComponent }).joined()
        let buildNumberComponents = buildNumber?.components().compactMap({ $0.plainComponent }).joined()

        return (versionNumberComponents?.isEmpty ?? true && buildNumberComponents?.isEmpty ?? true)
    }


    // MARK: - Comparisons

    static func ==(lhs: Version, rhs: Version) -> Bool {
        compare(lhs, rhs) == .equal
    }

    static func <(lhs: Version, rhs: Version) -> Bool {
        compare(lhs, rhs) == .older
    }

    static func >(lhs: Version, rhs: Version) -> Bool {
        compare(lhs, rhs) == .newer
    }

    // MARK: - Private

    /// An enum describing the result of a comparison
    private enum CheckingResult {
        case older, newer, equal, undefined
    }

    /// Performs the actual version comparison
    /// This algorithm is adopted from Sparkle Framework and slightly adapted
    private static func compare(_ lhs: Version, _ rhs: Version) -> CheckingResult {
        func compareValues(_ value1: String?, _ value2: String?) -> CheckingResult {
            switch (value1, value2) {
            case (nil, nil):
                return .equal
            case (nil, _):
                return .older
            case (_, nil):
                return .newer
            case (.some(let value1), .some(let value2)):
                return compareComponents(value1.components(), value2.components())
            }
        }

        // Use the display version as the stable primary key and the build as
        // a tie-breaker. This is symmetric, keeps mixed/missing build metadata
        // from comparing a build on one side with a version on the other, and
        // gives Comparable a transitive lexicographic ordering.
        let primaryResult = compareValues(
            lhs.versionNumber ?? lhs.buildNumber,
            rhs.versionNumber ?? rhs.buildNumber
        )
        guard case .equal = primaryResult else {
            return primaryResult
        }

        switch (lhs.buildNumber, rhs.buildNumber) {
        case (nil, nil):
            return .equal
        case (nil, .some):
            return .older
        case (.some, nil):
            return .newer
        case (.some(let lhsBuild), .some(let rhsBuild)):
            return compareValues(lhsBuild, rhsBuild)
        }
    }

    private static func compareComponents(
        _ c1: [Segment],
        _ c2: [Segment]
    ) -> CheckingResult {
        let count1 = c1.count
        let count2 = c2.count
        for i in 0..<min(count1, count2) {
            guard case .component(let component1) = c1[i], case .component(let component2) = c2[i] else { continue }

            let atomsCount1 = component1.count
            let atomsCount2 = component2.count
            for i in 0..<min(atomsCount1, atomsCount2) {
                let component1 = component1[i]
                let component2 = component2[i]

                // Compare numbers
                if case .number(let value1) = component1, case .number(let value2) = component2 {
                    if value1 > value2 {
                        return .newer // Think "1.3" vs "1.2"
                    } else if value2 > value1 {
                        return .older // Think "1.2" vs "1.3"
                    }
                }

                // Compare letters
                else if case .string(let value1) = component1, case .string(let value2) = component2 {
                    switch value1.compare(value2) {
                    case .orderedAscending:
                        return .older // Think "1.2A" vs "1.2B"
                    case .orderedDescending:
                        return .newer // Think "1.2B" vs "1.2A"
                    default: ()
                    }
                }

                // Not the same type? Now we have to do some validity checking
                else if case .string(_) = component1 {
                    return .older // Think "1.2A" vs "1.2.2"
                }

                else if case .string(_) = component2 {
                    return .newer // Think "1.2.3" vs "1.2A"
                }

                // One is a number and the other is a period. The period is invalid
                else if case .number(_) = component1 {
                    return .older // Think "1.2.." vs "1.2.0"
                }

                else if case .number(_) = component2 {
                    return .newer // Think "1.2.3" vs "1.2.."
                }
            }

            if atomsCount1 != atomsCount2 {
                let lhsIsLonger = atomsCount1 > atomsCount2
                let longerAtoms = (lhsIsLonger ? component1 : component2)
                    .dropFirst(lhsIsLonger ? atomsCount2 : atomsCount1)

                for atom in longerAtoms {
                    switch atom {
                    case .number(let number) where number != 0:
                        return lhsIsLonger ? .newer : .older
                    case .string:
                        return lhsIsLonger ? .older : .newer
                    default:
                        continue
                    }
                }
            }
        }

        // The versions are equal up to the point where they both still have parts
        // Let's check to see if one is larger than the other
        if count1 != count2 {
            let lhsIsLonger = count1 > count2
            let longerComponents = (lhsIsLonger ? c1 : c2)[(lhsIsLonger ? count2 : count1)...]

            // A zero component is insignificant only when every remaining
            // component is also zero. For example, 1.2 == 1.2.0, but
            // 1.2.0.1 must still compare newer than 1.2.
            for segment in longerComponents {
                guard case .component(let atoms) = segment else { continue }

                for atom in atoms {
                    switch atom {
                    case .number(let number) where number != 0:
                        return lhsIsLonger ? .newer : .older
                    case .string:
                        // A trailing qualifier is a pre-release marker:
                        // 1.2-beta is older than 1.2.
                        return lhsIsLonger ? .older : .newer
                    default:
                        continue
                    }
                }
            }

            return .equal // Think "1.2" vs "1.2.0.0"
        }

        return .equal // Think "1.2" vs "1.2"
    }

    // MARK: - Version Sanitization

    /// Sanitizes version discrepancies between app version and remote version
    func sanitize(with appVersion: Version) -> Version {
        // Case 1: The last component of the version number is actually the build number
        // This can only be detected for equal build numbers to avoid false positives
        // Example: App has 1.2 (40), Remote has 1.2.40
        // Action: Extract build number from version string → Version: 1.2, Build: 40
        if buildNumber == nil,
           var components = versionNumber?.components(),
           let lastRemoteComponent = components.last?.plainComponent,
           lastRemoteComponent == appVersion.buildNumber {
            // Remove build number segment from version number and store it separately
            let buildNumber = components.removeLast()

            // Remove separator as well
            if !components.isEmpty {
                components.removeLast()
            }

            return Version(versionNumber: components.joined(), buildNumber: buildNumber.plainComponent)
        }

        // Case 2: The entire version number equals the app version's build number
        // We assume version number by default, but that may not be the case
        // Example: App has 1.2 (123), Remote has 123
        // Action: Switch to build number comparison
        if let versionNumber, versionNumber == appVersion.buildNumber {
            return Version(versionNumber: nil, buildNumber: versionNumber)
        }

        // Case 3: Handle specific edge case with 7-component versions
        if appVersion.buildNumber == appVersion.versionNumber,
           var components = versionNumber?.components(),
           components.last?.plainComponent != nil,
           components.count == 7 {
            components.removeLast()
            components.removeLast()

            if components.joined() == appVersion.buildNumber {
                return Version(versionNumber: components.joined(), buildNumber: buildNumber)
            }
        }

        // Nothing changed - no sanitization needed
        return self
    }
}


// MARK: - Version Segment Parsing

/// An extension helping with version parsing
fileprivate extension String {

    /**
     Returns the components of a version number.
     Components are grouped by character type, so "12.3" returns [.component([.number(12)]), .separator("."), .component([.number(3)])]
     */
    func components() -> [Version.Segment] {
        let scanner = Scanner(string: self)

        var components = [Version.Segment]()
        var currentAtoms = [Version.Segment.Atom]()

        while !scanner.isAtEnd {
            var number: Int = 0

            // Try to scan number
            if scanner.scanInt(&number) {
                currentAtoms.append(.number(value: number))
            }

            // Try to scan separator
            else if let string = scanner.scanCharacters(from: .separators) {
                components.append(.component(atoms: currentAtoms))
                components.append(.separator(character: string as String))

                currentAtoms.removeAll()
            }

            // Try to scan anything else (letters)
            else if let string = scanner.scanCharacters(from: .letters) {
                currentAtoms.append(.string(value: string as String))
            }

            else {
                // Unable to parse - skip this character and continue
                scanner.currentIndex = scanner.string.index(after: scanner.currentIndex)
            }
        }

        if !currentAtoms.isEmpty {
            components.append(.component(atoms: currentAtoms))
        }

        return components
    }
}

fileprivate extension CharacterSet {

    /// Contains all delimiters used by a version string
    static let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)

    /// Contains any characters but separators and digits
    static let letters = CharacterSet.separators.union(.decimalDigits).inverted

}

/// Defining the type of version segments
fileprivate extension Version {
    enum Segment: Equatable {

        enum Atom: Equatable {
            case number(value: Int)      // 0..9
            case string(value: String)   // Everything else (letters, text)

            func isSameType(_ other: Atom) -> Bool {
                switch (self, other) {
                case (.number(_), .number(_)),
                     (.string(_), .string(_)):
                    return true
                default:
                    return false
                }
            }
        }

        case separator(character: String)  // Newlines, punctuation (., -, etc.)
        case component(atoms: [Atom])      // [123, A]

        var plainComponent: String? {
            guard case .component(let atoms) = self else {
                return nil
            }

            return atoms.map { atom in
                switch atom {
                case .number(let value):
                    return "\(value)"
                case .string(let value):
                    return value
                }
            }.joined()
        }

        func isSameType(_ other: Segment) -> Bool {
            switch (self, other) {
            case (.separator, .separator),
                 (.component(_), .component(_)):
                return true
            default:
                return false
            }
        }
    }
}

extension Array where Element == Version.Segment {
    func joined() -> String? {
        let string = self.map { segment in
            switch segment {
            case .separator(let character):
                character
            case .component(_):
                segment.plainComponent!
            }
        }.joined()

        return string.isEmpty ? nil : string
    }
}


// MARK: - Pre-Release Detection

/// Detects if a version string contains pre-release indicators
/// Checks for common patterns: beta, alpha, rc, pre, preview, dev, snapshot
/// - Parameter versionString: The version string to check (e.g., "1.0.0-beta", "2.0rc1")
/// - Returns: True if the version appears to be a pre-release
func isPreReleaseVersion(_ versionString: String) -> Bool {
    let lowercased = versionString.lowercased()

    // Define pre-release keywords once (used for both patterns)
    let preReleaseKeywords = ["beta", "alpha", "rc", "pre", "preview", "dev", "snapshot"]

    // Pattern 1: Dash-separated (SemVer style)
    // Examples: "1.0.0-beta", "2.0-rc1", "3.0-alpha.2"
    for keyword in preReleaseKeywords {
        if lowercased.contains("-\(keyword)") {
            return true
        }
    }

    // Pattern 2: Text-based indicators without dash (less common but exists)
    // Examples: "1.2beta", "3.0alpha", "2.5rc1"
    for keyword in preReleaseKeywords {
        // Check if keyword appears after numbers (not at the start)
        // Use regex to ensure it's part of the version, not just in app name
        if lowercased.range(of: "\\d+.*\(keyword)", options: .regularExpression) != nil {
            // Found keyword after digits
            return true
        }
    }

    return false
}
