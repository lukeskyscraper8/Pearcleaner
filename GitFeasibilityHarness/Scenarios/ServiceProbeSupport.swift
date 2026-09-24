import Foundation
import GitEvidenceShared

struct ServiceProbeResult: Sendable {
    let status: String
    let exitCode: Int32
    let stderr: String

    var completed: Bool {
        GitEvidenceXPCOperationStatus(rawValue: status) == .accepted
    }
}

/// Runs GitRunner sandbox probes as children of the sandboxed GitEvidenceService,
/// so each probe inherits the service's sandbox the way Git does.
enum ServiceProbeSupport {
    static let requiresHarnessBuildReason =
        "sandbox probes need a harness build compiled with GIT_FEASIBILITY_HARNESS (script/git_evidence_feasibility_run.sh)"

    /// The runner the service launches, which is what the probes exercise.
    static func serviceRunnerURL(bundle: Bundle = .main) throws -> URL {
        try GitOperationsScenarioSupport.embeddedServiceURL(bundle: bundle)
            .appendingPathComponent("Contents/MacOS/GitRunner")
    }

    static func runProbe(_ arguments: [String], bundle: Bundle = .main) throws -> ServiceProbeResult {
        #if GIT_FEASIBILITY_HARNESS
        let serviceURL = try GitOperationsScenarioSupport.embeddedServiceURL(bundle: bundle)
        guard try GitEvidenceCodesignValidation.serviceAtURLMatchesRequirement(serviceURL) else {
            throw FeasibilityScenarioFailure.scenarioFailed(
                .sandboxDenial,
                reason: "embedded GitEvidenceService signature rejected"
            )
        }

        let connection = GitEvidenceXPCConnectionFactory.makeClientConnection(serviceURL: serviceURL)
        connection.remoteObjectInterface = GitEvidenceXPCHarnessInterface.make()
        connection.resume()
        defer { connection.invalidate() }

        let semaphore = DispatchSemaphore(value: 0)
        var captured: ServiceProbeResult?
        var capturedError: NSError?

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            capturedError = error as NSError
            semaphore.signal()
        }) as? GitEvidenceXPCHarnessProtocol else {
            throw FeasibilityScenarioFailure.scenarioFailed(
                .sandboxDenial,
                reason: "unable to create GitEvidenceService harness proxy"
            )
        }

        proxy.runHarnessProbe(arguments) { status, exitCode, stderr in
            captured = ServiceProbeResult(
                status: status,
                exitCode: exitCode,
                stderr: String(data: stderr, encoding: .utf8) ?? ""
            )
            semaphore.signal()
        }
        semaphore.wait()

        if let capturedError {
            throw FeasibilityScenarioFailure.scenarioFailed(
                .sandboxDenial,
                reason: "\(capturedError.domain) \(capturedError.code): \(capturedError.localizedDescription)"
            )
        }
        guard let captured else {
            throw FeasibilityScenarioFailure.scenarioFailed(
                .sandboxDenial,
                reason: "GitEvidenceService returned no probe result"
            )
        }
        return captured
        #else
        _ = arguments
        _ = bundle
        throw FeasibilityScenarioFailure.scenarioFailed(.sandboxDenial, reason: requiresHarnessBuildReason)
        #endif
    }

    /// True when a probe ran to completion and reported a denied syscall.
    static func probeWasDenied(_ result: ServiceProbeResult, marker: String) -> Bool {
        result.completed
            && result.exitCode == 0
            && result.stderr.contains("\(marker)=")
            && !result.stderr.contains("\(marker)=0")
    }
}
