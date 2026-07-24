//
//  main.swift
//  PearcleanerHelper
//
//  Created by Alin Lupascu on 3/14/25.
//  Modified for the independently maintained Pearcleaner fork.
//

import Foundation
import ObjectiveC

@objc(HelperToolProtocol)
public protocol HelperToolProtocol {
    func runCommand(command: String, withReply reply: @escaping (Bool, String) -> Void)
    func runThinning(atPath: String, withReply reply: @escaping (Bool, String) -> Void)
    func runBundleThinning(bundlePath: String, withReply reply: @escaping (Bool, String, [String: UInt64]) -> Void)
}

// XPC Communication setup
class HelperToolDelegate: NSObject, NSXPCListenerDelegate, HelperToolProtocol {
    private var activeConnections = Set<NSXPCConnection>()
    
    override init() {
        super.init()
    }
    

    
    // Accept new XPC connections by setting up the exported interface and object.
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        guard isValidClient(connection: newConnection) else {
            print("❌ Rejected connection from unauthorized client")
            return false
        }
        newConnection.setCodeSigningRequirement(CodesignCheck.clientRequirement)
        newConnection.exportedInterface = NSXPCInterface(with: HelperToolProtocol.self)
        newConnection.exportedObject = self
        newConnection.invalidationHandler = { [weak self] in
            self?.activeConnections.remove(newConnection)
            if self?.activeConnections.isEmpty == true {
                exit(0) // Exit when no active connections remain
            }
        }
        activeConnections.insert(newConnection)
        newConnection.resume()
        return true
    }
    
    // Execute the shell command and reply with output.
    func runCommand(command: String, withReply reply: @escaping (Bool, String) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let outputLimit = 1_048_576
        let outputLock = NSLock()
        var capturedOutput = Data()
        var outputWasTruncated = false

        func drain(_ pipe: Pipe, group: DispatchGroup) {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                let handle = pipe.fileHandleForReading
                while true {
                    let data = handle.availableData
                    if data.isEmpty {
                        break
                    }

                    outputLock.lock()
                    let remainingCapacity = max(0, outputLimit - capturedOutput.count)
                    if remainingCapacity > 0 {
                        capturedOutput.append(data.prefix(remainingCapacity))
                    }
                    if data.count > remainingCapacity {
                        outputWasTruncated = true
                    }
                    outputLock.unlock()
                }
                group.leave()
            }
        }

        let drainGroup = DispatchGroup()
        do {
            try process.run()
            drain(outputPipe, group: drainGroup)
            drain(errorPipe, group: drainGroup)
            process.waitUntilExit()
            drainGroup.wait()
        } catch {
            reply(false, "Failed to run command: \(error.localizedDescription)")
            return
        }

        outputLock.lock()
        let data = capturedOutput
        let wasTruncated = outputWasTruncated
        outputLock.unlock()

        var output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if wasTruncated {
            output += output.isEmpty ? "[Output truncated]" : "\n[Output truncated]"
        }
        let success = (process.terminationStatus == 0) // Check if process exited successfully
        reply(success, output.isEmpty ? "No output" : output)
    }
    
    // Execute app lipo using privileges for apps owned by root
    func runThinning(atPath: String, withReply reply: @escaping (Bool, String) -> Void) {
        let success = thinBinaryUsingMachO(executablePath: atPath)
        reply(success, success ? "Success" : "Failed")
    }
    
    func runBundleThinning(bundlePath: String, withReply reply: @escaping (Bool, String, [String: UInt64]) -> Void) {
        let bundleURL = URL(fileURLWithPath: bundlePath)
        let result = thinAppBundle(at: bundleURL)
        
        let success = result.0
        let message = success ? "Bundle thinning completed successfully" : "Bundle thinning failed"
        let sizes = result.1 ?? [:]
        
        reply(success, message, sizes)
    }

    // Check that the codesigning matches between the main app and the helper app
    private func isValidClient(connection: NSXPCConnection) -> Bool {
        do {
            return try CodesignCheck.clientIsPearcleaner(pid: connection.processIdentifier)
        } catch {
            print("Helper code signing check failed with error: \(error)")
            return false
        }
    }
}

// Set up and start the XPC listener.
let delegate = HelperToolDelegate()
let listener = NSXPCListener(machServiceName: "com.lukerow.Pearcleaner.PearcleanerHelper")
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
