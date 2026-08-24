import Foundation

public enum GitRunnerInvocation {
    public static let version: String = "1.0.0"
    public static let gitLaunchPath: String = "/usr/bin/git"
    public static let metadataFileDescriptorsEnvironmentKey = "GIT_RUNNER_METADATA_FDS"
    public static let pipeFileDescriptorsEnvironmentKey = "GIT_RUNNER_PIPE_FDS"
    public static let openProbeArgument = "--git-runner-probe-open"
}
