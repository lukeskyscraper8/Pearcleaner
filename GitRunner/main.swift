import Foundation

let gitArguments = Array(CommandLine.arguments.dropFirst())

#if GIT_FEASIBILITY_HARNESS
// Sandbox probes exist only in feasibility-harness builds. A recognised probe
// exits inside runIfRequested; anything else falls through to Git.
_ = GitRunnerHarnessProbe.runIfRequested(arguments: gitArguments)
#endif

do {
    try GitRunnerProcessProfile.executeGitTransition(arguments: gitArguments)
} catch let error as GitRunnerError {
    fputs("\(error.message)\n", stderr)
    exit(error.exitCode)
} catch {
    fputs("GitRunner failed: \(error.localizedDescription)\n", stderr)
    exit(78)
}
