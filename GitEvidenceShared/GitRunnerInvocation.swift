import Foundation

public enum GitRunnerInvocation {
    public static let version: String = "1.0.0"
    /// `/usr/bin/git` is an xcrun shim that refuses to run inside an App
    /// Sandbox, so the runner starts Apple's real Git from one of these fixed
    /// developer-tools locations instead. Order is the fallback order when the
    /// system's developer-directory selection can't be read.
    public static let gitLaunchPathCandidates: [String] = [
        "/Library/Developer/CommandLineTools/usr/bin/git",
        "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
    ]
    /// Symlink `xcode-select` maintains to the selected developer directory.
    public static let developerDirectorySelectionLink = "/var/db/xcode_select_link"

    /// Returns the allowlisted Git that the developer-directory selection
    /// points at, or the first allowlisted Git present, or nil if none is.
    public static func resolvedGitLaunchPath(
        selectionLink: String = developerDirectorySelectionLink,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        if let selected = try? FileManager.default.destinationOfSymbolicLink(atPath: selectionLink) {
            let trimmed = selected.hasSuffix("/") ? String(selected.dropLast()) : selected
            let selectedGit = trimmed + "/usr/bin/git"
            if gitLaunchPathCandidates.contains(selectedGit), isExecutable(selectedGit) {
                return selectedGit
            }
        }
        return gitLaunchPathCandidates.first(where: isExecutable)
    }
    public static let metadataFileDescriptorsEnvironmentKey = "GIT_RUNNER_METADATA_FDS"
    public static let pipeFileDescriptorsEnvironmentKey = "GIT_RUNNER_PIPE_FDS"
    public static let openProbeArgument = "--git-runner-probe-open"
    public static let writeProbeArgument = "--git-runner-probe-write"
    public static let execProbeArgument = "--git-runner-probe-exec"
    public static let connectProbeArgument = "--git-runner-probe-connect"
    public static let hangProbeArgument = "--git-runner-probe-hang"
}
