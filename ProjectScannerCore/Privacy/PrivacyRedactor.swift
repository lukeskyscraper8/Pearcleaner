import Foundation

public struct RedactedSourceField: Sendable, Equatable {
    public let text: String

    fileprivate init(validatedText: String) {
        self.text = validatedText
    }
}

struct RedactionSpan: Sendable, Equatable {
    let utf8Range: Range<Int>

    init(utf8Range: Range<Int>) {
        self.utf8Range = utf8Range
    }
}

enum MaskingRuleResult: Sendable, Equatable {
    case complete(ruleID: RuleID, spans: [RedactionSpan])
    case uncertain(ruleID: RuleID)
}

enum RedactionResult: Sendable, Equatable {
    case redacted(RedactedSourceField)
    case metadataOnly
}

struct RedactionMetrics: Sendable, Equatable {
    let peakRetainedOutputScalars: Int
}

struct PrivacyRedactor: Sendable {
    private static let maximumSpanCount = 2_000
    private static let outputScalarLimit = 240

    private let expectedRuleIDs: Set<RuleID>
    private(set) var metrics = RedactionMetrics(peakRetainedOutputScalars: 0)

    init?(expectedRuleIDs: Set<RuleID>) {
        guard !expectedRuleIDs.isEmpty else { return nil }
        self.expectedRuleIDs = expectedRuleIDs
    }

    mutating func redact(
        utf8: UnsafeRawBufferPointer,
        ruleResults: [MaskingRuleResult]
    ) -> RedactionResult {
        metrics = RedactionMetrics(peakRetainedOutputScalars: 0)

        guard let ranges = validatedRanges(from: ruleResults, in: utf8),
              let mergedRanges = merge(ranges) else {
            return .metadataOnly
        }

        var outputSegments: [RedactedOutputSegment] = []
        var scalarCount = 0
        defer {
            metrics = RedactionMetrics(peakRetainedOutputScalars: scalarCount)
        }
        var presentationOpen = true
        guard streamValidatedUTF8(
            utf8,
            masking: mergedRanges,
            through: { event in
                appendBoundedEscaped(
                    event,
                    to: &outputSegments,
                    scalarCount: &scalarCount,
                    scalarLimit: Self.outputScalarLimit,
                    presentationOpen: &presentationOpen
                )
            }
        ) else {
            return .metadataOnly
        }

        guard let limited = joinValidatedSegments(
            &outputSegments,
            scalarLimit: Self.outputScalarLimit
        ) else {
            return .metadataOnly
        }
        return .redacted(RedactedSourceField(validatedText: limited))
    }

    private func validatedRanges(
        from ruleResults: [MaskingRuleResult],
        in utf8: UnsafeRawBufferPointer
    ) -> [Range<Int>]? {
        guard ruleResults.count == expectedRuleIDs.count else { return nil }

        var seenRuleIDs: Set<RuleID> = []
        var totalSpanCount = 0
        for result in ruleResults {
            let ruleID: RuleID
            let spans: [RedactionSpan]
            switch result {
            case let .complete(id, reportedSpans):
                ruleID = id
                spans = reportedSpans
            case .uncertain:
                return nil
            }
            guard expectedRuleIDs.contains(ruleID), seenRuleIDs.insert(ruleID).inserted else {
                return nil
            }
            let (newTotal, overflow) = totalSpanCount.addingReportingOverflow(spans.count)
            guard !overflow, newTotal <= Self.maximumSpanCount else { return nil }
            totalSpanCount = newTotal
        }
        guard seenRuleIDs == expectedRuleIDs, totalSpanCount > 0 else { return nil }

        var ranges: [Range<Int>] = []
        ranges.reserveCapacity(totalSpanCount)
        for result in ruleResults {
            guard case let .complete(_, spans) = result else { return nil }
            for span in spans {
                let range = span.utf8Range
                guard !range.isEmpty,
                      range.lowerBound >= 0,
                      range.upperBound <= utf8.count,
                      isScalarBoundary(range.lowerBound, in: utf8),
                      isScalarBoundary(range.upperBound, in: utf8) else {
                    return nil
                }
                ranges.append(range)
            }
        }
        return ranges
    }

    private func isScalarBoundary(_ index: Int, in utf8: UnsafeRawBufferPointer) -> Bool {
        guard index >= 0, index <= utf8.count else { return false }
        guard index != 0, index != utf8.count else { return true }
        return byte(in: utf8, at: index) & 0xC0 != 0x80
    }

    private func merge(_ ranges: [Range<Int>]) -> [Range<Int>]? {
        guard !ranges.isEmpty else { return nil }
        let sorted = ranges.sorted {
            if $0.lowerBound == $1.lowerBound {
                return $0.upperBound < $1.upperBound
            }
            return $0.lowerBound < $1.lowerBound
        }
        var merged: [Range<Int>] = []
        merged.reserveCapacity(sorted.count)
        for range in sorted {
            guard let last = merged.last else {
                merged.append(range)
                continue
            }
            if range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}

private enum RedactedOutputSegment: Sendable, Equatable {
    case text(String)
    case redactionToken
}

private enum RedactionStreamEvent {
    case scalar(Unicode.Scalar)
    case redactionToken
}

private func streamValidatedUTF8(
    _ utf8: UnsafeRawBufferPointer,
    masking ranges: [Range<Int>],
    through consume: (RedactionStreamEvent) -> Void
) -> Bool {
    var byteIndex = 0
    var rangeIndex = 0
    while byteIndex < utf8.count {
        if rangeIndex < ranges.count, byteIndex == ranges[rangeIndex].lowerBound {
            let range = ranges[rangeIndex]
            consume(.redactionToken)
            while byteIndex < range.upperBound {
                guard let decoded = decodeScalar(in: utf8, at: byteIndex),
                      byteIndex + decoded.length <= range.upperBound else {
                    return false
                }
                byteIndex += decoded.length
            }
            guard byteIndex == range.upperBound else { return false }
            rangeIndex += 1
            continue
        }

        guard let decoded = decodeScalar(in: utf8, at: byteIndex) else { return false }
        consume(.scalar(decoded.scalar))
        byteIndex += decoded.length
    }
    return rangeIndex == ranges.count
}

private func appendBoundedEscaped(
    _ event: RedactionStreamEvent,
    to segments: inout [RedactedOutputSegment],
    scalarCount: inout Int,
    scalarLimit: Int,
    presentationOpen: inout Bool
) {
    guard presentationOpen else { return }

    switch event {
    case .redactionToken:
        let tokenScalarCount = 10
        guard scalarCount <= scalarLimit - tokenScalarCount else {
            presentationOpen = false
            return
        }
        segments.append(.redactionToken)
        scalarCount += tokenScalarCount

    case let .scalar(scalar):
        let text: String
        if shouldEscape(scalar) {
            text = "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
        } else {
            text = String(scalar)
        }
        let addition = text.unicodeScalars.count
        guard scalarCount <= scalarLimit - addition else {
            presentationOpen = false
            return
        }
        if case let .text(existing)? = segments.last {
            segments[segments.count - 1] = .text(existing + text)
        } else {
            segments.append(.text(text))
        }
        scalarCount += addition
    }
}

private func joinValidatedSegments(
    _ segments: inout [RedactedOutputSegment],
    scalarLimit: Int
) -> String? {
    var result = ""
    var scalarCount = 0
    while !segments.isEmpty {
        let segment = segments.removeFirst()
        let text: String
        switch segment {
        case let .text(value):
            text = value
        case .redactionToken:
            text = "[REDACTED]"
        }
        let addition = text.unicodeScalars.count
        guard scalarCount <= scalarLimit - addition else { return nil }
        result += text
        scalarCount += addition
    }
    return result
}

private func shouldEscape(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069:
        return true
    default:
        return scalar.properties.generalCategory == .control
    }
}

private func decodeScalar(
    in utf8: UnsafeRawBufferPointer,
    at index: Int
) -> (scalar: Unicode.Scalar, length: Int)? {
    guard index >= 0, index < utf8.count else { return nil }
    let first = byte(in: utf8, at: index)
    if first <= 0x7F {
        return (Unicode.Scalar(UInt32(first))!, 1)
    }

    let length: Int
    switch first {
    case 0xC2...0xDF:
        length = 2
    case 0xE0...0xEF:
        length = 3
    case 0xF0...0xF4:
        length = 4
    default:
        return nil
    }
    guard index <= utf8.count - length else { return nil }

    let second = byte(in: utf8, at: index + 1)
    guard second & 0xC0 == 0x80 else { return nil }
    switch first {
    case 0xE0 where second < 0xA0:
        return nil
    case 0xED where second > 0x9F:
        return nil
    case 0xF0 where second < 0x90:
        return nil
    case 0xF4 where second > 0x8F:
        return nil
    default:
        break
    }

    if length >= 3, byte(in: utf8, at: index + 2) & 0xC0 != 0x80 {
        return nil
    }
    if length == 4, byte(in: utf8, at: index + 3) & 0xC0 != 0x80 {
        return nil
    }

    let value: UInt32
    switch length {
    case 2:
        value = UInt32(first & 0x1F) << 6
            | UInt32(second & 0x3F)
    case 3:
        value = UInt32(first & 0x0F) << 12
            | UInt32(second & 0x3F) << 6
            | UInt32(byte(in: utf8, at: index + 2) & 0x3F)
    case 4:
        value = UInt32(first & 0x07) << 18
            | UInt32(second & 0x3F) << 12
            | UInt32(byte(in: utf8, at: index + 2) & 0x3F) << 6
            | UInt32(byte(in: utf8, at: index + 3) & 0x3F)
    default:
        return nil
    }
    guard let scalar = Unicode.Scalar(value) else { return nil }
    return (scalar, length)
}

private func byte(in utf8: UnsafeRawBufferPointer, at index: Int) -> UInt8 {
    utf8.load(fromByteOffset: index, as: UInt8.self)
}
