import Foundation

public enum SecretConfidenceClass: Sendable, Equatable {
    case high
    case reviewSuggested
}

public struct SecretRuleDefinition: Sendable, Equatable {
    public let id: RuleID
    public let version: UInt32
    public let confidence: SecretConfidenceClass
    public let maxMatchLength: Int

    internal let prefix: [UInt8]
    internal let validator: SecretRuleValidator

    fileprivate init(
        id: RuleID,
        version: UInt32,
        confidence: SecretConfidenceClass,
        maxMatchLength: Int,
        prefix: [UInt8],
        validator: SecretRuleValidator
    ) {
        self.id = id
        self.version = version
        self.confidence = confidence
        self.maxMatchLength = maxMatchLength
        self.prefix = prefix
        self.validator = validator
    }

    internal func matchLength(
        in bytes: UnsafeRawBufferPointer,
        startingAt index: Int,
        upperBound: Int
    ) -> Int? {
        guard index >= 0, upperBound <= bytes.count, index < upperBound else { return nil }
        guard index + prefix.count <= upperBound else { return nil }
        for offset in prefix.indices where bytes[index + offset] != prefix[offset] {
            return nil
        }
        let start = index
        let end = validator.validate(bytes: bytes, start: start, upperBound: upperBound)
        guard let end, end > start, end - start <= maxMatchLength else { return nil }
        return end - start
    }
}

public struct SecretRulePack: Sendable, Equatable {
    public static let packVersion: UInt32 = 1

    public let packVersion: UInt32
    public let rules: [SecretRuleDefinition]
    public let ruleIDs: Set<RuleID>

    fileprivate let maximumMatchLength: Int

    public init(rules: [SecretRuleDefinition]) {
        precondition(!rules.isEmpty)
        self.packVersion = Self.packVersion
        self.rules = rules
        ruleIDs = Set(rules.map(\.id))
        maximumMatchLength = rules.map(\.maxMatchLength).max() ?? 0
    }

    public static let current: SecretRulePack = {
        let rules: [SecretRuleDefinition] = [
            SecretRuleDefinition(
                id: RuleID(rawValue: "secret.aws.access_key_id")!,
                version: 1,
                confidence: .high,
                maxMatchLength: 20,
                prefix: Array("AKIA".utf8),
                validator: .awsAccessKeyID
            ),
            SecretRuleDefinition(
                id: RuleID(rawValue: "secret.aws.session_access_key_id")!,
                version: 1,
                confidence: .high,
                maxMatchLength: 20,
                prefix: Array("ASIA".utf8),
                validator: .awsAccessKeyID
            ),
            SecretRuleDefinition(
                id: RuleID(rawValue: "secret.github.pat")!,
                version: 1,
                confidence: .high,
                maxMatchLength: 255,
                prefix: Array("ghp_".utf8),
                validator: .githubPersonalAccessToken
            ),
            SecretRuleDefinition(
                id: RuleID(rawValue: "secret.github.oauth")!,
                version: 1,
                confidence: .high,
                maxMatchLength: 255,
                prefix: Array("gho_".utf8),
                validator: .githubPersonalAccessToken
            ),
            SecretRuleDefinition(
                id: RuleID(rawValue: "secret.github.user_to_server")!,
                version: 1,
                confidence: .high,
                maxMatchLength: 255,
                prefix: Array("ghu_".utf8),
                validator: .githubPersonalAccessToken
            ),
            SecretRuleDefinition(
                id: RuleID(rawValue: "secret.github.server_to_server")!,
                version: 1,
                confidence: .high,
                maxMatchLength: 255,
                prefix: Array("ghs_".utf8),
                validator: .githubPersonalAccessToken
            ),
            SecretRuleDefinition(
                id: RuleID(rawValue: "secret.github.refresh")!,
                version: 1,
                confidence: .high,
                maxMatchLength: 255,
                prefix: Array("ghr_".utf8),
                validator: .githubPersonalAccessToken
            ),
            SecretRuleDefinition(
                id: RuleID(rawValue: "secret.github.fine_grained_pat")!,
                version: 1,
                confidence: .high,
                maxMatchLength: 255,
                prefix: Array("github_pat_".utf8),
                validator: .githubFineGrainedPat
            ),
            SecretRuleDefinition(
                id: RuleID(rawValue: "secret.slack.bot_token")!,
                version: 1,
                confidence: .high,
                maxMatchLength: 128,
                prefix: Array("xoxb-".utf8),
                validator: .slackToken
            ),
            SecretRuleDefinition(
                id: RuleID(rawValue: "secret.slack.app_token")!,
                version: 1,
                confidence: .high,
                maxMatchLength: 128,
                prefix: Array("xapp-".utf8),
                validator: .slackToken
            ),
            SecretRuleDefinition(
                id: RuleID(rawValue: "secret.slack.user_token")!,
                version: 1,
                confidence: .high,
                maxMatchLength: 128,
                prefix: Array("xoxp-".utf8),
                validator: .slackToken
            ),
            SecretRuleDefinition(
                id: RuleID(rawValue: "secret.stripe.secret_key")!,
                version: 1,
                confidence: .high,
                maxMatchLength: 128,
                prefix: Array("sk_live_".utf8),
                validator: .stripeSecretKey
            ),
            SecretRuleDefinition(
                id: RuleID(rawValue: "secret.stripe.test_secret_key")!,
                version: 1,
                confidence: .high,
                maxMatchLength: 128,
                prefix: Array("sk_test_".utf8),
                validator: .stripeSecretKey
            ),
            SecretRuleDefinition(
                id: RuleID(rawValue: "secret.stripe.restricted_key")!,
                version: 1,
                confidence: .high,
                maxMatchLength: 128,
                prefix: Array("rk_live_".utf8),
                validator: .stripeSecretKey
            ),
            SecretRuleDefinition(
                id: RuleID(rawValue: "secret.stripe.test_restricted_key")!,
                version: 1,
                confidence: .high,
                maxMatchLength: 128,
                prefix: Array("rk_test_".utf8),
                validator: .stripeSecretKey
            ),
        ]
        return SecretRulePack(rules: rules)
    }()

    internal var maximumMatchBytes: Int {
        maximumMatchLength
    }

    internal func findPrefix(
        _ prefix: [UInt8],
        in bytes: UnsafeRawBufferPointer,
        startingAt: Int,
        upperBound: Int
    ) -> Int? {
        guard !prefix.isEmpty, startingAt < upperBound else { return nil }
        let limit = upperBound - prefix.count
        guard limit >= startingAt else { return nil }
        var index = startingAt
        while index <= limit {
            var matched = true
            for offset in prefix.indices where bytes[index + offset] != prefix[offset] {
                matched = false
                break
            }
            if matched {
                return index
            }
            index += 1
        }
        return nil
    }
}

enum SecretRuleValidator: Equatable, Sendable {
    case awsAccessKeyID
    case githubPersonalAccessToken
    case githubFineGrainedPat
    case slackToken
    case stripeSecretKey

    func validate(
        bytes: UnsafeRawBufferPointer,
        start: Int,
        upperBound: Int
    ) -> Int? {
        switch self {
        case .awsAccessKeyID:
            return validateAWSAccessKeyID(bytes: bytes, start: start, upperBound: upperBound)
        case .githubPersonalAccessToken:
            return validateGitHubPersonalAccessToken(
                bytes: bytes,
                start: start,
                upperBound: upperBound,
                minimumBodyLength: 36
            )
        case .githubFineGrainedPat:
            return validateGitHubPersonalAccessToken(
                bytes: bytes,
                start: start,
                upperBound: upperBound,
                minimumBodyLength: 82
            )
        case .slackToken:
            return validateSlackToken(bytes: bytes, start: start, upperBound: upperBound)
        case .stripeSecretKey:
            return validateStripeSecretKey(bytes: bytes, start: start, upperBound: upperBound)
        }
    }

    private func validateAWSAccessKeyID(
        bytes: UnsafeRawBufferPointer,
        start: Int,
        upperBound: Int
    ) -> Int? {
        let length = 20
        guard start + length <= upperBound else { return nil }
        for index in (start + 4)..<(start + length) {
            guard isAWSAccessKeyCharacter(bytes[index]) else { return nil }
        }
        return start + length
    }

    private func validateGitHubPersonalAccessToken(
        bytes: UnsafeRawBufferPointer,
        start: Int,
        upperBound: Int,
        minimumBodyLength: Int
    ) -> Int? {
        var index = start
        while index < upperBound, isGitHubTokenBodyCharacter(bytes[index]) {
            index += 1
        }
        guard index - start >= 4 + minimumBodyLength else { return nil }
        return index
    }

    private func validateSlackToken(
        bytes: UnsafeRawBufferPointer,
        start: Int,
        upperBound: Int
    ) -> Int? {
        var index = start
        while index < upperBound, bytes[index] != 0x2D {
            index += 1
        }
        guard index > start, index < upperBound else { return nil }
        index += 1

        guard let firstSegmentEnd = readDigitSegment(bytes: bytes, start: index, upperBound: upperBound) else {
            return nil
        }
        guard firstSegmentEnd - index >= 10, firstSegmentEnd - index <= 13 else { return nil }
        index = firstSegmentEnd
        guard index < upperBound, bytes[index] == 0x2D else { return nil }
        index += 1

        guard let secondSegmentEnd = readDigitSegment(bytes: bytes, start: index, upperBound: upperBound) else {
            return nil
        }
        guard secondSegmentEnd - index >= 10, secondSegmentEnd - index <= 13 else { return nil }
        index = secondSegmentEnd
        guard index < upperBound, bytes[index] == 0x2D else { return nil }
        index += 1

        var bodyLength = 0
        while index < upperBound, isSlackTokenBodyCharacter(bytes[index]) {
            index += 1
            bodyLength += 1
        }
        guard bodyLength >= 24 else { return nil }
        return index
    }

    private func validateStripeSecretKey(
        bytes: UnsafeRawBufferPointer,
        start: Int,
        upperBound: Int
    ) -> Int? {
        let prefixes = [
            Array("sk_live_".utf8),
            Array("sk_test_".utf8),
            Array("rk_live_".utf8),
            Array("rk_test_".utf8),
        ]
        guard let prefix = prefixes.first(where: { prefix in
            guard start + prefix.count <= upperBound else { return false }
            return bytes[start..<(start + prefix.count)].elementsEqual(prefix)
        }) else {
            return nil
        }

        var index = start + prefix.count
        var bodyLength = 0
        while index < upperBound, isStripeKeyBodyCharacter(bytes[index]) {
            index += 1
            bodyLength += 1
        }
        guard bodyLength >= 24 else { return nil }
        return index
    }

    private func readDigitSegment(
        bytes: UnsafeRawBufferPointer,
        start: Int,
        upperBound: Int
    ) -> Int? {
        guard start < upperBound, bytes[start] >= 0x30, bytes[start] <= 0x39 else { return nil }
        var index = start
        while index < upperBound, bytes[index] >= 0x30, bytes[index] <= 0x39 {
            index += 1
        }
        return index
    }
}

private func isAWSAccessKeyCharacter(_ byte: UInt8) -> Bool {
    switch byte {
    case 0x30...0x39, 0x41...0x5A:
        return true
    default:
        return false
    }
}

private func isGitHubTokenBodyCharacter(_ byte: UInt8) -> Bool {
    switch byte {
    case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x5F:
        return true
    default:
        return false
    }
}

private func isSlackTokenBodyCharacter(_ byte: UInt8) -> Bool {
    switch byte {
    case 0x30...0x39, 0x41...0x5A, 0x61...0x7A:
        return true
    default:
        return false
    }
}

private func isStripeKeyBodyCharacter(_ byte: UInt8) -> Bool {
    switch byte {
    case 0x30...0x39, 0x41...0x5A, 0x61...0x7A:
        return true
    default:
        return false
    }
}
