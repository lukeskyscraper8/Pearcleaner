import Foundation

enum PrivacyCanaries {
    static let secret = "secret-" + String(repeating: "S", count: 41)
    static let path = "path-" + String(repeating: "P", count: 43)
    static let package = "package-" + String(repeating: "G", count: 40)
    static let advisory = "advisory-" + String(repeating: "A", count: 39)
    static let script = "script-" + String(repeating: "C", count: 41)
    static let version = "version-" + String(repeating: "V", count: 40)
    static let label = "label-" + String(repeating: "L", count: 42)

    static let all = [secret, path, package, advisory, script, version]
}
