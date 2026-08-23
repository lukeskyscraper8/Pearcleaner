public protocol ScannerDiagnosticSinking: Sendable {
    func record(_ event: ScannerDiagnosticEvent) async
}
