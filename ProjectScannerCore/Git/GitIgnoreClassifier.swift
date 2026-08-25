import Foundation

public enum GitIgnoreClassifierBuildOutcome: Sendable, Equatable {
    case available(GitIgnoreClassifier)
    case unsupported
}

public struct GitIgnoreClassifier: Sendable, Equatable {
    private let rules: [GitIgnoreRule]

    fileprivate init(rules: [GitIgnoreRule]) {
        self.rules = rules
    }

    public func isIgnored(_ path: VerifiedRelativePath) -> Bool {
        let segments = path.identityComponents.map { String(decoding: $0, as: UTF8.self) }
        guard !segments.isEmpty else { return false }

        var ignored = false
        for rule in rules where rule.applies(toPathSegments: segments) {
            if rule.matches(segments: segments) {
                ignored = rule.negated ? false : true
            }
        }
        return ignored
    }

    public static func build(
        excludeFileContents: Data?,
        gitignoreFiles: [(directory: VerifiedRelativePath?, contents: Data)]
    ) -> GitIgnoreClassifierBuildOutcome {
        var totalBytes: UInt64 = 0
        var patternCount: UInt64 = 0
        var rules: [GitIgnoreRule] = []

        let sortedGitignoreFiles = gitignoreFiles.sorted { lhs, rhs in
            let lhsDepth = lhs.directory?.identityComponents.count ?? 0
            let rhsDepth = rhs.directory?.identityComponents.count ?? 0
            if lhsDepth == rhsDepth {
                let lhsName = lhs.directory?.identityComponents.map {
                    String(decoding: $0, as: UTF8.self)
                }.joined(separator: "/") ?? ""
                let rhsName = rhs.directory?.identityComponents.map {
                    String(decoding: $0, as: UTF8.self)
                }.joined(separator: "/") ?? ""
                return lhsName < rhsName
            }
            return lhsDepth < rhsDepth
        }

        func appendRules(
            from contents: Data,
            anchorDirectory: VerifiedRelativePath?
        ) -> Bool {
            guard totalBytes + UInt64(contents.count) <= GitIgnoreClassifierLimits.maxTotalBytes,
                  contents.count <= Int(GitIgnoreClassifierLimits.maxBytesPerFile) else {
                return false
            }
            totalBytes += UInt64(contents.count)

            guard let text = String(data: contents, encoding: .utf8) else {
                return false
            }

            for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
                let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty, !line.hasPrefix("#") else { continue }
                guard patternCount < GitIgnoreClassifierLimits.maxPatterns else {
                    return false
                }
                guard let rule = GitIgnoreRule.parse(
                    line: line,
                    anchorDirectory: anchorDirectory
                ) else {
                    return false
                }
                patternCount += 1
                rules.append(rule)
            }
            return true
        }

        if let excludeFileContents {
            guard appendRules(from: excludeFileContents, anchorDirectory: nil) else {
                return .unsupported
            }
        }

        for gitignore in sortedGitignoreFiles {
            guard appendRules(from: gitignore.contents, anchorDirectory: gitignore.directory) else {
                return .unsupported
            }
        }

        return .available(GitIgnoreClassifier(rules: rules))
    }
}

private struct GitIgnoreRule: Equatable, Sendable {
    let pattern: String
    let anchorDirectory: VerifiedRelativePath?
    let directoryOnly: Bool
    let negated: Bool
    let anchoredToRoot: Bool
    let hasSlash: Bool

    static func parse(
        line: String,
        anchorDirectory: VerifiedRelativePath?
    ) -> GitIgnoreRule? {
        var text = line
        var negated = false
        if text.hasPrefix("!") {
            negated = true
            text.removeFirst()
            guard !text.isEmpty else { return nil }
        }

        var directoryOnly = false
        if text.hasSuffix("/") {
            directoryOnly = true
            text.removeLast()
            guard !text.isEmpty else { return nil }
        }

        let anchoredToRoot = text.hasPrefix("/")
        if anchoredToRoot {
            text.removeFirst()
            guard !text.isEmpty else { return nil }
        }

        guard GitIgnorePatternSyntax.isSupported(text) else { return nil }

        return GitIgnoreRule(
            pattern: text,
            anchorDirectory: anchorDirectory,
            directoryOnly: directoryOnly,
            negated: negated,
            anchoredToRoot: anchoredToRoot,
            hasSlash: text.contains("/")
        )
    }

    func applies(toPathSegments segments: [String]) -> Bool {
        guard let anchorDirectory else { return true }
        let anchorSegments = anchorDirectory.identityComponents.map {
            String(decoding: $0, as: UTF8.self)
        }
        guard segments.count >= anchorSegments.count else { return false }
        return zip(anchorSegments, segments).allSatisfy { $0 == $1 }
    }

    func matches(segments: [String]) -> Bool {
        let anchorSegments = anchorDirectory?.identityComponents.map {
            String(decoding: $0, as: UTF8.self)
        } ?? []

        if anchoredToRoot || hasSlash {
            let relativeSegments = anchorSegments + segments
            return GitIgnorePatternMatcher.matches(
                pattern: pattern,
                pathSegments: relativeSegments,
                directoryOnly: directoryOnly,
                matchBasename: false
            )
        }

        if GitIgnorePatternMatcher.matches(
            pattern: pattern,
            pathSegments: anchorSegments + segments,
            directoryOnly: directoryOnly,
            matchBasename: false
        ) {
            return true
        }

        return GitIgnorePatternMatcher.matches(
            pattern: pattern,
            pathSegments: segments,
            directoryOnly: directoryOnly,
            matchBasename: true
        )
    }
}

private enum GitIgnorePatternSyntax {
    static func isSupported(_ pattern: String) -> Bool {
        guard !pattern.isEmpty else { return false }
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let character = pattern[index]
            switch character {
            case "[":
                guard let closing = pattern[index...].firstIndex(of: "]"),
                      closing > pattern.index(after: index) else {
                    return false
                }
                index = pattern.index(after: closing)
            case "\\":
                index = pattern.index(after: index)
                guard index < pattern.endIndex else { return false }
                index = pattern.index(after: index)
            case "*", "?", "/":
                index = pattern.index(after: index)
            default:
                guard character.isASCII else { return false }
                index = pattern.index(after: index)
            }
        }
        return true
    }
}

private enum GitIgnorePatternMatcher {
    static func matches(
        pattern: String,
        pathSegments: [String],
        directoryOnly: Bool,
        matchBasename: Bool
    ) -> Bool {
        if matchBasename {
            guard let last = pathSegments.last else { return false }
            return matchesPattern(
                pattern,
                against: last,
                directoryOnly: directoryOnly,
                isDirectoryPath: true
            )
        }

        if directoryOnly {
            guard !pathSegments.isEmpty else { return false }
            for endIndex in 1...pathSegments.count {
                let prefix = pathSegments.prefix(endIndex)
                let candidate = prefix.joined(separator: "/")
                let isDirectory = endIndex < pathSegments.count || pathSegments.count > 0
                if matchesPattern(
                    pattern,
                    against: candidate,
                    directoryOnly: true,
                    isDirectoryPath: isDirectory
                ) {
                    return true
                }
            }
            return false
        }

        let candidate = pathSegments.joined(separator: "/")
        return matchesPattern(
            pattern,
            against: candidate,
            directoryOnly: false,
            isDirectoryPath: false
        )
    }

    private static func matchesPattern(
        _ pattern: String,
        against candidate: String,
        directoryOnly: Bool,
        isDirectoryPath: Bool
    ) -> Bool {
        if directoryOnly && !isDirectoryPath {
            return false
        }
        return fnmatchGit(pattern: pattern, candidate: candidate)
    }

    private static func fnmatchGit(pattern: String, candidate: String) -> Bool {
        let patternChars = Array(pattern)
        let candidateChars = Array(candidate)
        return match(
            pattern: patternChars,
            patternIndex: 0,
            candidate: candidateChars,
            candidateIndex: 0
        )
    }

    private static func match(
        pattern: [Character],
        patternIndex: Int,
        candidate: [Character],
        candidateIndex: Int
    ) -> Bool {
        var patternIndex = patternIndex
        var candidateIndex = candidateIndex

        while patternIndex < pattern.count {
            let token = pattern[patternIndex]
            switch token {
            case "\\":
                patternIndex += 1
                guard patternIndex < pattern.count, candidateIndex < candidate.count else {
                    return false
                }
                guard pattern[patternIndex] == candidate[candidateIndex] else { return false }
                patternIndex += 1
                candidateIndex += 1
            case "*":
                if patternIndex + 1 < pattern.count, pattern[patternIndex + 1] == "*" {
                    patternIndex += 2
                    if patternIndex < pattern.count, pattern[patternIndex] == "/" {
                        patternIndex += 1
                        while candidateIndex < candidate.count {
                            if candidate[candidateIndex] == "/" {
                                if match(
                                    pattern: pattern,
                                    patternIndex: patternIndex,
                                    candidate: candidate,
                                    candidateIndex: candidateIndex
                                ) {
                                    return true
                                }
                            }
                            candidateIndex += 1
                        }
                        return match(
                            pattern: pattern,
                            patternIndex: patternIndex,
                            candidate: candidate,
                            candidateIndex: candidateIndex
                        )
                    }
                    for start in candidateIndex...candidate.count {
                        if match(
                            pattern: pattern,
                            patternIndex: patternIndex,
                            candidate: candidate,
                            candidateIndex: start
                        ) {
                            return true
                        }
                    }
                    return false
                }
                for start in candidateIndex...candidate.count {
                    if match(
                        pattern: pattern,
                        patternIndex: patternIndex + 1,
                        candidate: candidate,
                        candidateIndex: start
                    ) {
                        return true
                    }
                }
                return false
            case "?":
                guard candidateIndex < candidate.count, candidate[candidateIndex] != "/" else {
                    return false
                }
                patternIndex += 1
                candidateIndex += 1
            case "[":
                guard let closing = pattern[patternIndex...].firstIndex(of: "]"),
                      closing > pattern.index(after: patternIndex),
                      candidateIndex < candidate.count else {
                    return false
                }
                let classPattern = String(pattern[patternIndex...closing])
                guard matchesCharacterClass(classPattern, character: candidate[candidateIndex]) else {
                    return false
                }
                patternIndex = pattern.index(after: closing)
                candidateIndex += 1
            default:
                guard candidateIndex < candidate.count, token == candidate[candidateIndex] else {
                    return false
                }
                patternIndex += 1
                candidateIndex += 1
            }
        }
        return candidateIndex == candidate.count
    }

    private static func matchesCharacterClass(_ pattern: String, character: Character) -> Bool {
        guard pattern.first == "[", pattern.last == "]" else { return false }
        let body = String(pattern.dropFirst().dropLast())
        guard !body.isEmpty else { return false }

        var index = body.startIndex
        var negated = false
        if body[index] == "!" || body[index] == "^" {
            negated = true
            index = body.index(after: index)
        }

        var matched = false
        let scalar = character.unicodeScalars.first?.value ?? 0
        while index < body.endIndex {
            let start = body[index]
            let end: Character
            if index < body.index(before: body.endIndex),
               body.index(after: index) < body.endIndex,
               body[body.index(after: index)] == "-" {
                end = body[body.index(index, offsetBy: 2)]
                index = body.index(index, offsetBy: 3)
            } else {
                end = start
                index = body.index(after: index)
            }
            let startScalar = start.unicodeScalars.first?.value ?? 0
            let endScalar = end.unicodeScalars.first?.value ?? 0
            if scalar >= startScalar && scalar <= endScalar {
                matched = true
            }
        }
        return negated ? !matched : matched
    }
}
