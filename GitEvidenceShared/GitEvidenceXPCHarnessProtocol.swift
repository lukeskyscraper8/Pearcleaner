#if GIT_FEASIBILITY_HARNESS
import Foundation

/// Harness-only XPC surface, compiled in only when
/// script/git_evidence_feasibility_run.sh builds with GIT_FEASIBILITY_HARNESS.
/// It lets the feasibility harness run GitRunner's sandbox probes as children
/// of the sandboxed service, so they inherit the service's sandbox exactly as
/// Git does. A runner started by the unsandboxed harness itself is killed by
/// macOS instead. Shipping builds never export this protocol.
@objc(GitEvidenceXPCHarnessProtocol)
public protocol GitEvidenceXPCHarnessProtocol: GitEvidenceXPCProtocol {
    /// Runs GitRunner with `arguments`, which must start with one of the
    /// GitRunnerInvocation probe arguments. Replies with a
    /// GitEvidenceXPCOperationStatus raw value, the runner's exit code, and
    /// its stderr.
    func runHarnessProbe(
        _ arguments: [String],
        reply: @escaping (String, Int32, Data) -> Void
    )
}

public enum GitEvidenceXPCHarnessInterface {
    public static let probeArguments: Set<String> = [
        GitRunnerInvocation.openProbeArgument,
        GitRunnerInvocation.writeProbeArgument,
        GitRunnerInvocation.execProbeArgument,
        GitRunnerInvocation.connectProbeArgument,
        GitRunnerInvocation.hangProbeArgument,
    ]

    public static func make() -> NSXPCInterface {
        let interface = NSXPCInterface(with: GitEvidenceXPCHarnessProtocol.self)
        GitEvidenceXPCInterfaceConfigurator.apply(to: interface, isRemote: false)
        interface.setClasses(
            NSSet(array: [NSArray.self, NSString.self]) as! Set<AnyHashable>,
            for: #selector(GitEvidenceXPCHarnessProtocol.runHarnessProbe(_:reply:)),
            argumentIndex: 0,
            ofReply: false
        )
        return interface
    }
}
#endif
