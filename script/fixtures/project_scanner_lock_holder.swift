import Darwin
import Foundation

private let readinessByte: UInt8 = 0x52

private enum LockHolderFailure: Error {
    case invalidArguments
    case invalidPath
    case invalidLock
    case openFailed
    case lockFailed
    case readinessFailed
}

private struct LockIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
    let type: mode_t
    let owner: uid_t
    let mode: mode_t

    init(_ status: stat) {
        device = status.st_dev
        inode = status.st_ino
        type = status.st_mode & S_IFMT
        owner = status.st_uid
        mode = status.st_mode & 0o7777
    }
}

private func requireLock(_ status: stat) throws -> LockIdentity {
    let identity = LockIdentity(status)
    guard identity.type == S_IFREG,
          identity.owner == geteuid(),
          identity.mode == 0o600 else {
        throw LockHolderFailure.invalidLock
    }
    return identity
}

private func inspect(_ path: String) throws -> stat {
    var status = stat()
    while true {
        let result = path.withCString { lstat($0, &status) }
        if result == 0 { return status }
        if errno == EINTR { continue }
        throw LockHolderFailure.invalidLock
    }
}

private func openedStatus(_ descriptor: Int32) throws -> stat {
    var status = stat()
    while fstat(descriptor, &status) != 0 {
        if errno != EINTR { throw LockHolderFailure.invalidLock }
    }
    return status
}

private func acquire(_ descriptor: Int32) throws {
    while flock(descriptor, LOCK_EX) != 0 {
        if errno != EINTR { throw LockHolderFailure.lockFailed }
    }
}

private func writeReadiness() throws {
    var byte = readinessByte
    while true {
        let count = withUnsafePointer(to: &byte) {
            Darwin.write(STDOUT_FILENO, $0, 1)
        }
        if count == 1 { return }
        if count < 0, errno == EINTR { continue }
        throw LockHolderFailure.readinessFailed
    }
}

private func run() throws -> Never {
    guard CommandLine.arguments.count == 2 else {
        throw LockHolderFailure.invalidArguments
    }
    let path = CommandLine.arguments[1]
    let url = URL(fileURLWithPath: path)
    let components = url.pathComponents
    guard path.hasPrefix("/"),
          url.path == path,
          url.standardizedFileURL.path == path,
          components.count == 8,
          components[1] == "tmp",
          components[2].hasPrefix("project-scanner-process."),
          components[2].count == "project-scanner-process.".count + 6,
          components[4] == "state-root",
          components[5] == "Pearcleaner",
          components[6] == "ProjectScanner",
          url.lastPathComponent == ".state.lock" else {
        throw LockHolderFailure.invalidPath
    }

    let before = try requireLock(inspect(path))
    let descriptor = path.withCString {
        Darwin.open($0, O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    }
    guard descriptor >= 0 else { throw LockHolderFailure.openFailed }
    defer { _ = Darwin.close(descriptor) }

    let openedBeforeLock = try requireLock(openedStatus(descriptor))
    guard openedBeforeLock == before else { throw LockHolderFailure.invalidLock }

    try acquire(descriptor)

    let after = try requireLock(inspect(path))
    let openedAfterLock = try requireLock(openedStatus(descriptor))
    guard after == before, openedAfterLock == before else {
        throw LockHolderFailure.invalidLock
    }

    try writeReadiness()
    while true { _ = pause() }
}

do {
    try run()
} catch {
    _exit(1)
}
