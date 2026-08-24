import Foundation
import ProjectScannerCore
import Security

protocol SecItemClient: Sendable {
    func add(_ attributes: [CFString: Any]) -> OSStatus
    func copyMatching(_ query: [CFString: Any]) -> (OSStatus, CFTypeRef?)
}

private struct SystemSecItemClient: SecItemClient {
    func add(_ attributes: [CFString: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func copyMatching(_ query: [CFString: Any]) -> (OSStatus, CFTypeRef?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result)
    }
}

struct KeychainProjectKeyStore: ProjectKeyMaterialStoring, Sendable {
    private let client: any SecItemClient

    init(client: any SecItemClient = SystemSecItemClient()) {
        self.client = client
    }

    func read() async -> StoredKeyRead {
        readStored()
    }

    func createIfMissing(_ material: ProjectKeyMaterial) async -> StoredKeyCreate {
        let status = add(material)
        switch status {
        case errSecSuccess:
            return .created(material)
        case errSecDuplicateItem:
            switch readStored() {
            case let .found(existing):
                return .existing(existing)
            case .invalidRecord:
                return .invalidRecord
            case let .unavailable(reason):
                return .unavailable(reason)
            case .missing:
                return .unavailable(.systemFailure)
            }
        case errSecInteractionNotAllowed:
            return .unavailable(.interactionNotAllowed)
        default:
            return .unavailable(.systemFailure)
        }
    }

    private func add(_ material: ProjectKeyMaterial) -> OSStatus {
        var record = material.secureStorageRecord()
        let mutableRecord = NSMutableData(data: record)
        let status = autoreleasepool { () -> OSStatus in
            let attributes: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: "com.lukerow.Pearcleaner.project-scanner.hmac",
                kSecAttrAccount: "suppression-v1",
                kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                kSecAttrSynchronizable: kCFBooleanFalse as Any,
                kSecValueData: mutableRecord,
            ]
            return client.add(attributes)
        }
        mutableRecord.resetBytes(in: NSRange(location: 0, length: mutableRecord.length))
        record.resetBytes(in: record.startIndex..<record.endIndex)
        return status
    }

    private func readStored() -> StoredKeyRead {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "com.lukerow.Pearcleaner.project-scanner.hmac",
            kSecAttrAccount: "suppression-v1",
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
            kSecReturnData: kCFBooleanTrue as Any,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        let (status, result) = client.copyMatching(query)
        switch status {
        case errSecItemNotFound:
            return .missing
        case errSecInteractionNotAllowed:
            return .unavailable(.interactionNotAllowed)
        case errSecSuccess:
            break
        default:
            return .unavailable(.systemFailure)
        }

        guard let data = result as? Data else { return .invalidRecord }
        var record = data
        defer {
            record.resetBytes(in: record.startIndex..<record.endIndex)
            if let mutable = result as? NSMutableData {
                mutable.resetBytes(in: NSRange(location: 0, length: mutable.length))
            }
        }
        do {
            return .found(try ProjectKeyMaterial(secureStorageRecord: record))
        } catch {
            return .invalidRecord
        }
    }
}
