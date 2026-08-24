import ProjectScannerCore

func requiresStringConvertible<T: CustomStringConvertible>(_ type: T.Type) {}
func misuse() { requiresStringConvertible(ProjectKeyMaterial.self) }
