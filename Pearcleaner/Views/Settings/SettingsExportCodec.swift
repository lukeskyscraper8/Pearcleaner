//
//  SettingsExportCodec.swift
//  Pearcleaner
//
//  Pearcleaner fork modification: preserve non-JSON UserDefaults values when
//  exporting settings and validate imported keys before writing them.
//

import Foundation

enum SettingsExportCodec {
    private static let typeKey = "__pearcleaner_type"
    private static let valueKey = "value"

    enum CodecError: LocalizedError {
        case invalidRoot
        case invalidEncodedValue(String)
        case unsupportedValue(String)

        var errorDescription: String? {
            switch self {
            case .invalidRoot:
                return "The settings file does not contain a valid settings dictionary."
            case .invalidEncodedValue(let type):
                return "The settings file contains an invalid encoded \(type) value."
            case .unsupportedValue(let type):
                return "A setting uses the unsupported value type \(type)."
            }
        }
    }

    static func exportData(from settings: [String: Any]) throws -> Data {
        let filteredSettings = settings.filter { $0.key.hasPrefix("settings.") }
        let encoded = try filteredSettings.mapValues(encode)

        guard JSONSerialization.isValidJSONObject(encoded) else {
            throw CodecError.invalidRoot
        }

        return try JSONSerialization.data(
            withJSONObject: encoded,
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    static func importSettings(
        from data: Data,
        allowedKeys: Set<String> = SettingsKeyAllowlist.all
    ) throws -> [String: Any] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodecError.invalidRoot
        }

        var settings: [String: Any] = [:]
        for (key, value) in root where key.hasPrefix("settings.") {
            let decoded = try decode(value)
            guard allowedKeys.contains(key) else { continue }
            settings[key] = sanitizedImportValue(decoded, for: key)
        }
        return settings
    }

    private static func sanitizedImportValue(_ value: Any, for key: String) -> Any {
        guard SettingsKeyAllowlist.folderKeys.contains(key),
              let paths = value as? [String] else {
            return value
        }
        let allowKeywords = key == FolderPreferenceKey.orphanExclusions.rawValue
        return FolderPathPolicy.sanitizedFolderList(paths, allowKeywords: allowKeywords)
    }

    private static func encode(_ value: Any) throws -> Any {
        switch value {
        case let data as Data:
            return [
                typeKey: "data",
                valueKey: data.base64EncodedString()
            ]
        case let date as Date:
            return [
                typeKey: "date",
                valueKey: date.timeIntervalSince1970
            ]
        case let dictionary as [String: Any]:
            return try dictionary.mapValues(encode)
        case let array as [Any]:
            return try array.map(encode)
        case is String, is NSNumber:
            return value
        default:
            throw CodecError.unsupportedValue(String(describing: type(of: value)))
        }
    }

    private static func decode(_ value: Any) throws -> Any {
        if let dictionary = value as? [String: Any] {
            if let encodedType = dictionary[typeKey] as? String {
                guard dictionary.count == 2 else {
                    throw CodecError.invalidEncodedValue(encodedType)
                }

                switch encodedType {
                case "data":
                    guard let string = dictionary[valueKey] as? String,
                          let data = Data(base64Encoded: string) else {
                        throw CodecError.invalidEncodedValue(encodedType)
                    }
                    return data
                case "date":
                    guard let interval = dictionary[valueKey] as? NSNumber else {
                        throw CodecError.invalidEncodedValue(encodedType)
                    }
                    return Date(timeIntervalSince1970: interval.doubleValue)
                default:
                    throw CodecError.invalidEncodedValue(encodedType)
                }
            }

            return try dictionary.mapValues(decode)
        }

        if let array = value as? [Any] {
            return try array.map(decode)
        }

        // UserDefaults accepts property-list values; JSON null is not one and
        // can raise an Objective-C exception if passed to `set(_:forKey:)`.
        guard value is String || value is NSNumber else {
            throw CodecError.unsupportedValue(String(describing: type(of: value)))
        }
        return value
    }
}
