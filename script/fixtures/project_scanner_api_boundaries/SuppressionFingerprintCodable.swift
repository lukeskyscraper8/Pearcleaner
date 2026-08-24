import ProjectScannerCore

func requiresCodable<T: Codable>(_ type: T.Type) {}
func misuse() { requiresCodable(SuppressionFingerprint.self) }
