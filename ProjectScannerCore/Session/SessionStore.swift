import Foundation

public actor SessionStore {
    private let limits: ScanLimits
    private var findings: [SessionFinding] = []
    private var findingCount: UInt64 = 0
    private var retainedModelBytes: UInt64 = 0

    public init(limits: ScanLimits) {
        self.limits = limits
    }

    public func append(_ finding: SessionFinding) -> SessionAppendResult {
        guard let findingBytes = Self.estimatedModelBytes(for: finding) else {
            return .limitReached
        }
        let (nextCount, countOverflow) = findingCount.addingReportingOverflow(1)
        guard !countOverflow, nextCount <= limits.findingsPerSession else {
            return .limitReached
        }
        let (nextBytes, byteOverflow) = retainedModelBytes.addingReportingOverflow(findingBytes)
        guard !byteOverflow, nextBytes <= limits.findingModelBytes else {
            return .limitReached
        }

        findings.append(finding)
        findingCount = nextCount
        retainedModelBytes = nextBytes
        return .appended
    }

    public func snapshot() -> [SessionFinding] {
        findings
    }

    public func clear() {
        findings.removeAll(keepingCapacity: false)
        findingCount = 0
        retainedModelBytes = 0
    }

    static func estimatedModelBytes(for finding: SessionFinding) -> UInt64? {
        var total = UInt64(MemoryLayout<SessionFinding>.stride)
        guard addUTF8Bytes(of: finding.header.ruleID.rawValue, to: &total) else {
            return nil
        }

        if let location = finding.location {
            let componentCount = UInt64(location.components.count)
            let componentStride = UInt64(MemoryLayout<VerifiedPathComponent>.stride)
            let (componentStorage, multiplicationOverflow) = componentCount
                .multipliedReportingOverflow(by: componentStride)
            guard !multiplicationOverflow, add(componentStorage, to: &total) else {
                return nil
            }
            for component in location.components {
                guard add(UInt64(component.bytes.count), to: &total) else { return nil }
            }
        }

        if let displayPath = finding.displayPath,
           !addUTF8Bytes(of: displayPath.text, to: &total) {
            return nil
        }
        if let evidence = finding.evidence,
           !addUTF8Bytes(of: evidence.text, to: &total) {
            return nil
        }

        if case let .upstreamSeverity(severities) = finding.header.assessment {
            let severityCount = UInt64(severities.count)
            let severityStride = UInt64(MemoryLayout<UpstreamSeverity>.stride)
            let (severityStorage, multiplicationOverflow) = severityCount
                .multipliedReportingOverflow(by: severityStride)
            guard !multiplicationOverflow, add(severityStorage, to: &total) else {
                return nil
            }
            for severity in severities {
                guard addUTF8Bytes(of: severity.scheme, to: &total),
                      addUTF8Bytes(of: severity.value, to: &total) else {
                    return nil
                }
            }
        }
        return total
    }

    private static func addUTF8Bytes(of value: String, to total: inout UInt64) -> Bool {
        add(UInt64(value.utf8.count), to: &total)
    }

    private static func add(_ value: UInt64, to total: inout UInt64) -> Bool {
        let (next, overflow) = total.addingReportingOverflow(value)
        guard !overflow else { return false }
        total = next
        return true
    }
}
