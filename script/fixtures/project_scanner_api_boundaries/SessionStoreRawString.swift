import ProjectScannerCore

func misuse() {
    _ = SessionStore(limits: "raw")
}
