import XCTest
@testable import ProjectScannerCore

final class PrivacyRedactorTests: XCTestCase {
    private let primaryRule = RuleID(rawValue: "secret.primary")!
    private let secondaryRule = RuleID(rawValue: "secret.secondary")!

    func testOneMatchBecomesTheFixedRedactedToken() throws {
        let source = Array("before \(PrivacyCanaries.secret) after".utf8)
        let secretRange = try XCTUnwrap(source.range(of: Array(PrivacyCanaries.secret.utf8)))

        let result = redact(source, spans: [secretRange])

        XCTAssertEqual(redactedText(result), "before [REDACTED] after")
    }

    func testEveryMatchInTheFieldIsMasked() throws {
        let source = Array("\(PrivacyCanaries.secret)|\(PrivacyCanaries.script)".utf8)
        let secretRange = try XCTUnwrap(source.range(of: Array(PrivacyCanaries.secret.utf8)))
        let scriptRange = try XCTUnwrap(source.range(of: Array(PrivacyCanaries.script.utf8)))

        let result = redact(
            source,
            ruleResults: [
                .complete(ruleID: primaryRule, spans: [RedactionSpan(utf8Range: secretRange)]),
                .complete(ruleID: secondaryRule, spans: [RedactionSpan(utf8Range: scriptRange)])
            ]
        )

        XCTAssertEqual(redactedText(result), "[REDACTED]|[REDACTED]")
        XCTAssertFalse(redactedText(result)?.contains(PrivacyCanaries.secret) == true)
        XCTAssertFalse(redactedText(result)?.contains(PrivacyCanaries.script) == true)
    }

    func testAdjacentAndOverlappingSpansMergeWithoutRevealingBytes() throws {
        let source = Array("prefix-1234567890-suffix".utf8)
        let results: [MaskingRuleResult] = [
            .complete(
                ruleID: primaryRule,
                spans: [
                    RedactionSpan(utf8Range: 7..<13),
                    RedactionSpan(utf8Range: 10..<16),
                    RedactionSpan(utf8Range: 16..<17)
                ]
            ),
            .complete(ruleID: secondaryRule, spans: [])
        ]

        let result = redact(source, ruleResults: results)

        XCTAssertEqual(redactedText(result), "prefix-[REDACTED]-suffix")
        XCTAssertFalse(redactedText(result)?.contains("1234567890") == true)
    }

    func testDifferentSecretLengthsProduceTheSameToken() throws {
        let short = Array("a-x-z".utf8)
        let long = Array("a-abcdefghijklmnop-z".utf8)

        XCTAssertEqual(redactedText(redact(short, spans: [2..<3])), "a-[REDACTED]-z")
        XCTAssertEqual(redactedText(redact(long, spans: [2..<18])), "a-[REDACTED]-z")
    }

    func testControlAndBidirectionalScalarsAreEscaped() throws {
        let unsafeScalars: [Unicode.Scalar] = [
            "\u{0}", "\u{85}", "\u{61C}", "\u{200E}", "\u{200F}",
            "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
            "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}"
        ]
        let prefix = String(String.UnicodeScalarView(unsafeScalars))
        let source = Array((prefix + PrivacyCanaries.secret).utf8)
        let secretRange = source.count - PrivacyCanaries.secret.utf8.count..<source.count

        let result = redact(source, spans: [secretRange])

        XCTAssertEqual(
            redactedText(result),
            "\\u{0}\\u{85}\\u{61C}\\u{200E}\\u{200F}"
                + "\\u{202A}\\u{202B}\\u{202C}\\u{202D}\\u{202E}"
                + "\\u{2066}\\u{2067}\\u{2068}\\u{2069}[REDACTED]"
        )

        let closingSource = Array(
            (
                String(repeating: "a", count: 235)
                    + "\u{202E}safe-suffix"
                    + PrivacyCanaries.secret
            ).utf8
        )
        let closingSecretRange = closingSource.count - PrivacyCanaries.secret.utf8.count..<closingSource.count
        XCTAssertEqual(
            redactedText(redact(closingSource, spans: [closingSecretRange])),
            String(repeating: "a", count: 235)
        )
    }

    func testOutputIsLimitedToTwoHundredFortyUnicodeScalars() throws {
        let source = Array((String(repeating: "a", count: 300) + PrivacyCanaries.secret).utf8)
        let secretRange = 300..<300 + PrivacyCanaries.secret.utf8.count

        let result = redact(source, spans: [secretRange])
        let text = try XCTUnwrap(redactedText(result))

        XCTAssertEqual(text.unicodeScalars.count, 240)
        XCTAssertEqual(text, String(repeating: "a", count: 240))
    }

    func testMalformedUTF8ReturnsMetadataOnly() throws {
        let malformedSequences: [(name: String, bytes: [UInt8])] = [
            ("stray continuation", [0x80]),
            ("C0 overlong", [0xC0, 0x80]),
            ("C1 overlong", [0xC1, 0xBF]),
            ("E0 overlong", [0xE0, 0x80, 0x80]),
            ("F0 overlong", [0xF0, 0x80, 0x80, 0x80]),
            ("surrogate", [0xED, 0xA0, 0x80]),
            ("above U+10FFFF", [0xF4, 0x90, 0x80, 0x80]),
            ("F5 lead", [0xF5, 0x80, 0x80, 0x80]),
            ("truncated two-byte", [0xC2]),
            ("truncated three-byte", [0xE2, 0x82]),
            ("truncated four-byte", [0xF0, 0x9F, 0x99]),
            ("invalid continuation", [0xE2, 0x28, 0xA1])
        ]
        let secret = Array(PrivacyCanaries.secret.utf8)

        for malformed in malformedSequences {
            let maskedSource = [UInt8(ascii: "a")] + malformed.bytes
            var maskedRedactor = makeRedactor()
            let maskedResult = maskedSource.withUnsafeBytes {
                maskedRedactor.redact(
                    utf8: $0,
                    ruleResults: [
                        .complete(
                            ruleID: primaryRule,
                            spans: [RedactionSpan(utf8Range: 0..<maskedSource.count)]
                        ),
                        .complete(ruleID: secondaryRule, spans: [])
                    ]
                )
            }
            XCTAssertEqual(maskedResult, .metadataOnly, malformed.name)
            XCTAssertEqual(maskedRedactor.metrics.peakRetainedOutputScalars, 10, malformed.name)

            var afterClosure = secret
            afterClosure.append(
                contentsOf: [UInt8](repeating: UInt8(ascii: "a"), count: 230)
            )
            afterClosure.append(UInt8(ascii: "z"))
            afterClosure.append(contentsOf: malformed.bytes)
            var closedRedactor = makeRedactor()
            let closedResult = afterClosure.withUnsafeBytes {
                closedRedactor.redact(
                    utf8: $0,
                    ruleResults: [
                        .complete(
                            ruleID: primaryRule,
                            spans: [
                                RedactionSpan(
                                    utf8Range: 0..<secret.count
                                )
                            ]
                        ),
                        .complete(ruleID: secondaryRule, spans: [])
                    ]
                )
            }
            XCTAssertEqual(closedResult, .metadataOnly, malformed.name)
            XCTAssertEqual(
                closedRedactor.metrics.peakRetainedOutputScalars,
                240,
                malformed.name
            )
        }

        var beforeOutput: [UInt8] = [0x80]
        let secretStart = beforeOutput.count
        beforeOutput.append(contentsOf: secret)
        var beforeOutputRedactor = makeRedactor()
        let beforeOutputResult = beforeOutput.withUnsafeBytes {
            beforeOutputRedactor.redact(
                utf8: $0,
                ruleResults: [
                    .complete(
                        ruleID: primaryRule,
                        spans: [
                            RedactionSpan(utf8Range: secretStart..<secretStart + secret.count)
                        ]
                    ),
                    .complete(ruleID: secondaryRule, spans: [])
                ]
            )
        }
        XCTAssertEqual(beforeOutputResult, .metadataOnly)
        XCTAssertEqual(beforeOutputRedactor.metrics.peakRetainedOutputScalars, 0)
    }

    func testSpanInsideAMultibyteScalarReturnsMetadataOnly() throws {
        let source = Array("A🙂B".utf8)
        let results: [MaskingRuleResult] = [
            .complete(
                ruleID: primaryRule,
                spans: [
                    RedactionSpan(utf8Range: 1..<3),
                    RedactionSpan(utf8Range: 3..<5)
                ]
            ),
            .complete(ruleID: secondaryRule, spans: [])
        ]

        let result = redact(source, ruleResults: results)

        XCTAssertEqual(result, .metadataOnly)
    }

    func testUncertainSecondaryMaskingReturnsMetadataOnly() throws {
        let source = Array("secret".utf8)

        let result = redact(
            source,
            ruleResults: [
                .complete(ruleID: primaryRule, spans: [RedactionSpan(utf8Range: 0..<6)]),
                .uncertain(ruleID: secondaryRule)
            ]
        )

        XCTAssertEqual(result, .metadataOnly)
    }

    func testZeroLengthSpanReturnsMetadataOnly() throws {
        let source = Array("secret".utf8)

        XCTAssertEqual(redact(source, spans: [2..<2]), .metadataOnly)
        XCTAssertEqual(redact(source, spans: [0..<7]), .metadataOnly)
    }

    func testMissingExpectedSecondaryRuleResultReturnsMetadataOnly() throws {
        let source = Array("secret".utf8)
        let validSpan = RedactionSpan(utf8Range: 0..<6)

        XCTAssertEqual(
            redact(source, ruleResults: [.complete(ruleID: primaryRule, spans: [validSpan])]),
            .metadataOnly
        )
        XCTAssertEqual(
            redact(
                source,
                ruleResults: [
                    .complete(ruleID: primaryRule, spans: [validSpan]),
                    .complete(ruleID: primaryRule, spans: [validSpan])
                ]
            ),
            .metadataOnly
        )
        let unexpected = try XCTUnwrap(RuleID(rawValue: "secret.unexpected"))
        XCTAssertEqual(
            redact(
                source,
                ruleResults: [
                    .complete(ruleID: primaryRule, spans: [validSpan]),
                    .complete(ruleID: secondaryRule, spans: []),
                    .complete(ruleID: unexpected, spans: [])
                ]
            ),
            .metadataOnly
        )
    }

    func testEmptySpanListReturnsMetadataOnlyInThisSlice() throws {
        let source = Array("ordinary text".utf8)

        let result = redact(source, spans: [])

        XCTAssertEqual(result, .metadataOnly)
    }

    func testMoreThanTwoThousandTotalSpansReturnsMetadataOnlyBeforeSorting() throws {
        let source = Array("secret".utf8)
        let spans = (0..<2_001).map { _ in RedactionSpan(utf8Range: 0..<1) }

        let result = redact(
            source,
            ruleResults: [
                .complete(ruleID: primaryRule, spans: spans),
                .complete(ruleID: secondaryRule, spans: [])
            ]
        )

        XCTAssertEqual(result, .metadataOnly)
    }

    func testScalarLimitNeverSplitsTheFixedRedactionToken() throws {
        let source = Array(
            (String(repeating: "a", count: 232) + PrivacyCanaries.secret + "must-not-appear").utf8
        )
        let secretRange = 232..<232 + PrivacyCanaries.secret.utf8.count

        let result = redact(source, spans: [secretRange])

        XCTAssertEqual(redactedText(result), String(repeating: "a", count: 232))
        XCTAssertFalse(redactedText(result)?.contains("[REDACT") == true)
    }

    func testLargeInputProducesOnlyBoundedStreamingOutput() throws {
        let byteCount = 5 * 1_024 * 1_024
        var source = [UInt8](repeating: UInt8(ascii: "a"), count: byteCount)
        let secret = Array(PrivacyCanaries.secret.utf8)
        let earlyRange = 20..<20 + secret.count
        let lateStart = 4 * 1_024 * 1_024
        let lateRange = lateStart..<lateStart + secret.count
        source.replaceSubrange(earlyRange, with: secret)
        source.replaceSubrange(lateRange, with: secret)
        var redactor = makeRedactor()

        let result = source.withUnsafeBytes {
            redactor.redact(
                utf8: $0,
                ruleResults: [
                    .complete(
                        ruleID: primaryRule,
                        spans: [
                            RedactionSpan(utf8Range: earlyRange),
                            RedactionSpan(utf8Range: lateRange)
                        ]
                    ),
                    .complete(ruleID: secondaryRule, spans: [])
                ]
            )
        }
        let text = try XCTUnwrap(redactedText(result))

        XCTAssertLessThanOrEqual(text.unicodeScalars.count, 240)
        XCTAssertEqual(redactor.metrics.peakRetainedOutputScalars, 240)
        XCTAssertFalse(text.contains(PrivacyCanaries.secret))
        XCTAssertFalse(text.contains("[REDACTED") && !text.contains("[REDACTED]"))
    }

    private func makeRedactor() -> PrivacyRedactor {
        PrivacyRedactor(expectedRuleIDs: [primaryRule, secondaryRule])!
    }

    private func redact(_ source: [UInt8], spans: [Range<Int>]) -> RedactionResult {
        redact(
            source,
            ruleResults: [
                .complete(
                    ruleID: primaryRule,
                    spans: spans.map(RedactionSpan.init(utf8Range:))
                ),
                .complete(ruleID: secondaryRule, spans: [])
            ]
        )
    }

    private func redact(
        _ source: [UInt8],
        ruleResults: [MaskingRuleResult]
    ) -> RedactionResult {
        var redactor = makeRedactor()
        return source.withUnsafeBytes {
            redactor.redact(utf8: $0, ruleResults: ruleResults)
        }
    }

    private func redactedText(_ result: RedactionResult) -> String? {
        guard case let .redacted(field) = result else { return nil }
        return field.text
    }
}

private extension Array where Element == UInt8 {
    func range(of needle: [UInt8]) -> Range<Int>? {
        guard !needle.isEmpty, needle.count <= count else { return nil }
        for start in 0...count - needle.count where self[start..<start + needle.count].elementsEqual(needle) {
            return start..<start + needle.count
        }
        return nil
    }
}
