import Foundation

public enum GitEvidenceGitCommand {
    /// Fixed Git prelude and configuration overrides required by spec §10.3.
    public static let fixedConfigurationPrelude: [String] = [
        "--no-pager",
        "--no-optional-locks",
        "--no-replace-objects",
        "-c", "core.fsmonitor=false",
        "-c", "core.untrackedCache=false",
        "-c", "core.hooksPath=/dev/null",
        "-c", "submodule.recurse=false",
        "-c", "maintenance.auto=false",
        "-c", "core.attributesFile=/dev/null",
        "-c", "core.excludesFile=/dev/null",
        "-c", "color.ui=false",
        "-c", "credential.helper=",
        "-c", "protocol.allow=never",
        "-c", "diff.external=",
    ]
}
