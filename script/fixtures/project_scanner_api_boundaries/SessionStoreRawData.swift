import Foundation
import ProjectScannerCore

func misuse() {
    _ = SessionStore(limits: Data())
}
