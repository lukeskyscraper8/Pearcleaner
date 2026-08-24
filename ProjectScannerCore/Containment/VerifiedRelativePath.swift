import Foundation

public struct VerifiedPathComponent: Sendable, Equatable, Hashable {
    let bytes: Data

    init(bytes: Data) throws {
        guard !bytes.isEmpty,
              bytes.count <= 255,
              !bytes.contains(0),
              !bytes.contains(0x2F),
              bytes != Data([0x2E]),
              bytes != Data([0x2E, 0x2E]) else {
            if bytes.count > 255 {
                throw ContainmentError.pathTooLong
            }
            throw ContainmentError.invalidSelection
        }
        self.bytes = bytes
    }
}

public struct VerifiedRelativePath: Sendable, Equatable, Hashable {
    let components: [VerifiedPathComponent]
    let rawByteCount: UInt64

    var identityComponents: [Data] {
        components.map(\.bytes)
    }

    init(components: [VerifiedPathComponent]) throws {
        guard !components.isEmpty else {
            throw ContainmentError.invalidSelection
        }
        guard components.count <= Int(ScanLimits.defaults.traversalDepth) else {
            throw ContainmentError.pathTooLong
        }

        var total: UInt64 = 0
        for (index, component) in components.enumerated() {
            let byteCount = UInt64(component.bytes.count)
            let (withComponent, componentOverflow) = total.addingReportingOverflow(byteCount)
            guard !componentOverflow else { throw ContainmentError.pathTooLong }
            total = withComponent

            if index > 0 {
                let (withSeparator, separatorOverflow) = total.addingReportingOverflow(1)
                guard !separatorOverflow else { throw ContainmentError.pathTooLong }
                total = withSeparator
            }
        }
        guard total <= ScanLimits.defaults.relativePathBytes else {
            throw ContainmentError.pathTooLong
        }

        self.components = components
        rawByteCount = total
    }

    public func escapedForDisplay() -> EscapedDisplayPath {
        EscapedDisplayPath(text: components.map { escapeForDisplay($0.bytes) }.joined(separator: "/"))
    }
}

private func escapeForDisplay(_ data: Data) -> String {
    let bytes = [UInt8](data)
    var result = ""
    var index = 0

    while index < bytes.count {
        guard let length = validUTF8SequenceLength(in: bytes, at: index) else {
            result += String(format: "\\x%02X", bytes[index])
            index += 1
            continue
        }

        let decoded = String(decoding: bytes[index..<(index + length)], as: UTF8.self)
        guard let scalar = decoded.unicodeScalars.first else {
            result += String(format: "\\x%02X", bytes[index])
            index += 1
            continue
        }

        if shouldEscape(scalar.value) {
            result += "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
        } else {
            result += decoded
        }
        index += length
    }

    return result
}

private func validUTF8SequenceLength(in bytes: [UInt8], at index: Int) -> Int? {
    let first = bytes[index]
    if first <= 0x7F {
        return 1
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

    guard index <= bytes.count - length else { return nil }
    let second = bytes[index + 1]
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

    if length >= 3, bytes[index + 2] & 0xC0 != 0x80 {
        return nil
    }
    if length == 4, bytes[index + 3] & 0xC0 != 0x80 {
        return nil
    }
    return length
}

private func shouldEscape(_ value: UInt32) -> Bool {
    value <= 0x1F
        || (0x7F...0x9F).contains(value)
        || (0x202A...0x202E).contains(value)
        || (0x2066...0x2069).contains(value)
}

public struct EscapedDisplayPath: Sendable, Equatable, Hashable {
    public let text: String

    init(text: String) {
        self.text = text
    }
}
