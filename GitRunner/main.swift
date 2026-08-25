import Foundation

let gitArguments = Array(CommandLine.arguments.dropFirst())

if GitRunnerHarnessProbe.runIfRequested(arguments: gitArguments) {
    // Probe mode exits internally.
} else {
    do {
        try GitRunnerProcessProfile.executeGitTransition(arguments: gitArguments)
    } catch let error as GitRunnerError {
        fputs("\(error.message)\n", stderr)
        exit(error.exitCode)
    } catch {
        fputs("GitRunner failed: \(error.localizedDescription)\n", stderr)
        exit(78)
    }
}
