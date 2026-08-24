import XCTest
@testable import ProjectScannerCore

final class SecretRulePackTests: XCTestCase {
    func testCurrentPackIsVersionedAndInspectable() {
        let pack = SecretRulePack.current
        XCTAssertEqual(pack.packVersion, SecretRulePack.packVersion)
        XCTAssertFalse(pack.rules.isEmpty)
        XCTAssertEqual(pack.ruleIDs.count, pack.rules.count)
    }

    func testAWSAccessKeyIDRequiresTwentyByteStructuralMatch() throws {
        let rule = try XCTUnwrap(rule(id: "secret.aws.access_key_id"))
        let valid = Data("prefix AKIA0123456789ABCDEF suffix".utf8)
        let invalidLength = Data("AKIA0123456789AB".utf8)
        let invalidCharset = Data("AKIA0123456789ABCDeF".utf8)

        XCTAssertNotNil(matchLength(rule, in: valid))
        XCTAssertNil(matchLength(rule, in: invalidLength))
        XCTAssertNil(matchLength(rule, in: invalidCharset))
    }

    func testGitHubPatRequiresPrefixAndThirtySixBodyCharacters() throws {
        let rule = try XCTUnwrap(rule(id: "secret.github.pat"))
        let valid = Data("token=ghp_abcdefghijklmnopqrstuvwxyz0123456789AB".utf8)
        let short = Data("token=ghp_short".utf8)

        XCTAssertNotNil(matchLength(rule, in: valid))
        XCTAssertNil(matchLength(rule, in: short))
    }

    func testSlackBotTokenRequiresSegmentStructure() throws {
        let rule = try XCTUnwrap(rule(id: "secret.slack.bot_token"))
        let valid = Data("xoxb-12345678901-12345678901-abcdefghijklmnopqrstuvwx".utf8)
        let missingSegment = Data("xoxb-12345678901-abcdef".utf8)

        XCTAssertNotNil(matchLength(rule, in: valid))
        XCTAssertNil(matchLength(rule, in: missingSegment))
    }

    func testStripeSecretKeyRequiresLivePrefixAndBody() throws {
        let rule = try XCTUnwrap(rule(id: "secret.stripe.secret_key"))
        let valid = Data("sk_live_abcdefghijklmnopqrstuvwx".utf8)
        let short = Data("sk_live_short".utf8)

        XCTAssertNotNil(matchLength(rule, in: valid))
        XCTAssertNil(matchLength(rule, in: short))
    }

    private func rule(id: String) -> SecretRuleDefinition? {
        SecretRulePack.current.rules.first { $0.id.rawValue == id }
    }

    private func matchLength(_ rule: SecretRuleDefinition, in data: Data) -> Int? {
        data.withUnsafeBytes { bytes in
            for index in 0..<bytes.count {
                guard index + rule.prefix.count <= bytes.count else { break }
                guard bytes[index..<(index + rule.prefix.count)].elementsEqual(rule.prefix) else {
                    continue
                }
                if let length = rule.matchLength(in: bytes, startingAt: index, upperBound: bytes.count) {
                    return length
                }
            }
            return nil
        }
    }
}
