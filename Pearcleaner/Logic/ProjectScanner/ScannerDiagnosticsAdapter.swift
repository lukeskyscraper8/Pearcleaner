import OSLog
import ProjectScannerCore

protocol ScannerLogWriting: Sendable {
    func write(_ event: ScannerDiagnosticEvent)
}

private struct OSLogScannerLogWriter: ScannerLogWriting {
    private let logger = Logger(
        subsystem: "com.lukerow.Pearcleaner",
        category: "project-scanner"
    )

    func write(_ event: ScannerDiagnosticEvent) {
        logger.log(
            "session=\(event.sessionID.rawValue.uuidString, privacy: .public) detector=\(event.detector?.rawValue ?? "", privacy: .public) code=\(event.code.rawValue, privacy: .public) reason=\(event.reason?.rawValue ?? "", privacy: .public) count_present=\(event.count == nil ? 0 : 1, privacy: .public) count=\(event.count ?? 0, privacy: .public) bytes_present=\(event.bytes == nil ? 0 : 1, privacy: .public) bytes=\(event.bytes ?? 0, privacy: .public) duration_present=\(event.durationMilliseconds == nil ? 0 : 1, privacy: .public) duration_ms=\(event.durationMilliseconds ?? 0, privacy: .public) system=\(event.systemCategory?.rawValue ?? "", privacy: .public)"
        )
    }
}

struct ScannerDiagnosticsAdapter: ScannerDiagnosticSinking, Sendable {
    private let writer: any ScannerLogWriting

    init(writer: any ScannerLogWriting = OSLogScannerLogWriter()) {
        self.writer = writer
    }

    func record(_ event: ScannerDiagnosticEvent) async {
        writer.write(event)
    }
}
