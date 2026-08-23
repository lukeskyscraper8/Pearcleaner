import Darwin
import Foundation

final class TemporaryProjectFixture {
    let url: URL

    init() throws {
        let templateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).XXXXXX", isDirectory: true)
        var template = templateURL.path.utf8CString
        let createdPath = try template.withUnsafeMutableBufferPointer { buffer -> String in
            guard let created = mkdtemp(buffer.baseAddress) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return String(cString: created)
        }
        url = URL(fileURLWithPath: createdPath, isDirectory: true)
    }

    func directory(named name: String) throws -> URL {
        let directory = url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    func regularFile(named name: String) throws -> URL {
        let file = url.appendingPathComponent(name, isDirectory: false)
        guard FileManager.default.createFile(atPath: file.path, contents: Data()) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return file
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
