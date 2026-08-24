import ProjectScannerCore

func misuse(_ root: RootCapability) throws {
    _ = try root.duplicateDescriptor()
}
