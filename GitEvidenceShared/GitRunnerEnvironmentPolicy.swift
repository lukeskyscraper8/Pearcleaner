import Foundation

public enum GitRunnerEnvironmentPolicy {
    public static let permittedGitEnvironmentKeys: Set<String> = [
        "HOME",
        "TMPDIR",
        "PATH",
        "LANG",
        "LC_ALL",
        "GIT_DIR",
        "GIT_WORK_TREE",
        "GIT_INDEX_FILE",
        "GIT_OBJECT_DIRECTORY",
        "GIT_CONFIG_NOSYSTEM",
        "GIT_CONFIG_SYSTEM",
        "GIT_CONFIG_GLOBAL",
        "GIT_OPTIONAL_LOCKS",
        "GIT_NO_LAZY_FETCH",
        "GIT_NO_REPLACE_OBJECTS",
        "GIT_LITERAL_PATHSPECS",
        "GIT_TERMINAL_PROMPT",
    ]

    public static let requiredGitEnvironmentKeys: Set<String> = [
        "HOME",
        "TMPDIR",
    ]

    public static let fixedGitEnvironmentValues: [String: String] = [
        "PATH": "/usr/bin:/bin",
        "LANG": "C",
        "LC_ALL": "C",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_SYSTEM": "/dev/null",
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_OPTIONAL_LOCKS": "0",
        "GIT_NO_LAZY_FETCH": "1",
        "GIT_NO_REPLACE_OBJECTS": "1",
        "GIT_LITERAL_PATHSPECS": "1",
        "GIT_TERMINAL_PROMPT": "0",
    ]

    public static func parseFileDescriptorList(_ rawValue: String?) throws -> [Int32] {
        guard let rawValue, !rawValue.isEmpty else {
            return []
        }

        var descriptors: [Int32] = []
        for part in rawValue.split(separator: ",") {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let value = Int32(trimmed), value >= 0 else {
                throw GitRunnerPolicyError.invalidFileDescriptorList
            }
            descriptors.append(value)
        }
        return descriptors
    }

    public static func sanitizedGitEnvironment(from inherited: [String: String]) throws -> [String: String] {
        for key in inherited.keys {
            if key.hasPrefix("GIT_RUNNER_") {
                continue
            }
            if key.hasPrefix("DYLD_") {
                throw GitRunnerPolicyError.disallowedEnvironmentKey(key)
            }
            if key.hasPrefix("GIT_"), !permittedGitEnvironmentKeys.contains(key) {
                throw GitRunnerPolicyError.disallowedEnvironmentKey(key)
            }
        }

        var sanitized: [String: String] = [:]
        for key in permittedGitEnvironmentKeys {
            if let value = inherited[key] {
                sanitized[key] = value
            }
        }

        for key in requiredGitEnvironmentKeys where sanitized[key] == nil {
            throw GitRunnerPolicyError.missingRequiredEnvironment(key)
        }

        for (key, value) in fixedGitEnvironmentValues {
            sanitized[key] = value
        }

        return sanitized
    }
}

public enum GitRunnerPolicyError: Error, Sendable, Equatable {
    case invalidFileDescriptorList
    case missingRequiredEnvironment(String)
    case disallowedEnvironmentKey(String)
}
