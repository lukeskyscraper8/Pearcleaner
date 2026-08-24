import Foundation
import ProjectScannerCore

func misuse(_ bytes: Data) {
    _ = try? SuppressionFingerprint(validatedBytes: bytes)
}
