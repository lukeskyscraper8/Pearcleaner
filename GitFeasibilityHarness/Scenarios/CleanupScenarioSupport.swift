import Darwin
import Foundation
import GitEvidenceShared

enum CleanupScenarioSupport {
    static func embeddedServiceURL(bundle: Bundle = .main) throws -> URL {
        try GitOperationsScenarioSupport.embeddedServiceURL(bundle: bundle)
    }

    static func countMatchingProcesses(matching pattern: String) -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", pattern]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return 0
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 || process.terminationStatus == 1 else {
            return 0
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return output.split(whereSeparator: \.isNewline).filter { !$0.isEmpty }.count
    }

    static func runSuccessfulOperationCleanupCheck() throws -> (passed: Bool, detail: String) {
        let before = countMatchingProcesses(matching: "GitRunner|/usr/bin/git")
        do {
            let repository = try GitOperationsScenarioSupport.prepareRepository()
            defer {
                GitOperationsScenarioSupport.closeDescriptors(repository.openDescriptors)
                try? FileManager.default.removeItem(at: repository.rootURL)
            }

            let serviceURL = try embeddedServiceURL()
            let request = try GitEvidenceXPCRequest(
                operation: .listCachedPaths,
                headObjectID: nil,
                repositoryFormatVersion: 0,
                objectHashAlgorithm: .sha1,
                transferredDescriptors: repository.transferredDescriptors
            )
            let result = try GitOperationsScenarioSupport.perform(request: request, serviceURL: serviceURL)
            let accepted = GitEvidenceXPCOperationStatus(rawValue: result.status) == .accepted
            let after = countMatchingProcesses(matching: "GitRunner|/usr/bin/git")
            let passed = accepted && after <= before
            let detail = "accepted=\(accepted) before=\(before) after=\(after)"
            return (passed, detail)
        } catch {
            return (false, "xpc_unavailable=\(error.localizedDescription)")
        }
    }

    static func runFailureOperationCleanupCheck() throws -> (passed: Bool, detail: String) {
        let before = countMatchingProcesses(matching: "GitRunner|/usr/bin/git")
        do {
            let serviceURL = try embeddedServiceURL()
            let request = try GitEvidenceXPCRequest(
                operation: .catFileBatch,
                headObjectID: nil,
                catFileObjectIDs: [],
                repositoryFormatVersion: 0,
                objectHashAlgorithm: .sha1,
                transferredDescriptors: []
            )
            let result = try GitOperationsScenarioSupport.perform(request: request, serviceURL: serviceURL)
            let rejected = GitEvidenceXPCOperationStatus(rawValue: result.status) == .invalidRequest
            let after = countMatchingProcesses(matching: "GitRunner|/usr/bin/git")
            let passed = rejected && after <= before
            let detail = "invalid_request=\(rejected) before=\(before) after=\(after)"
            return (passed, detail)
        } catch {
            return (false, "xpc_unavailable=\(error.localizedDescription)")
        }
    }

    /// Asks the service to run the hang probe, which never exits, and checks
    /// that the service's timeout kills the runner's whole process group.
    static func runForcedKillCleanupCheck() -> (passed: Bool, detail: String) {
        let pattern = "git-runner-probe-hang"
        let before = countMatchingProcesses(matching: pattern)

        let observedWhileRunning = ObservedCount()
        let observer = DispatchWorkItem {
            observedWhileRunning.value = countMatchingProcesses(matching: pattern)
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2, execute: observer)

        let result: ServiceProbeResult
        do {
            result = try ServiceProbeSupport.runProbe([GitRunnerInvocation.hangProbeArgument])
        } catch {
            observer.cancel()
            return (false, "hang_probe_failed=\(FeasibilityScenarioFailure.reason(for: error))")
        }
        observer.wait()

        usleep(200_000)
        let afterKill = countMatchingProcesses(matching: pattern)
        let timedOut = GitEvidenceXPCOperationStatus(rawValue: result.status) == .timedOut
        let started = observedWhileRunning.value > before
        let passed = timedOut && started && afterKill <= before
        let detail = "status=\(result.status) before=\(before) while_running=\(observedWhileRunning.value) after_kill=\(afterKill)"
        return (passed, detail)
    }
}

private final class ObservedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}
