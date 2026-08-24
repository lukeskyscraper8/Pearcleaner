import Foundation
import GitEvidenceShared

final class GitEvidenceServiceDelegate: NSObject, NSXPCListenerDelegate, GitEvidenceXPCProtocol {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        _ = listener

        let interface = NSXPCInterface(with: GitEvidenceXPCProtocol.self)
        interface.setClasses(
            NSSet(array: [GitEvidenceXPCRequest.self, GitEvidenceXPCReply.self]) as! Set<AnyHashable>,
            for: #selector(GitEvidenceXPCProtocol.perform(_:reply:)),
            argumentIndex: 0,
            ofReply: false
        )
        interface.setClasses(
            NSSet(array: [GitEvidenceXPCReply.self]) as! Set<AnyHashable>,
            for: #selector(GitEvidenceXPCProtocol.perform(_:reply:)),
            argumentIndex: 0,
            ofReply: true
        )

        newConnection.exportedInterface = interface
        newConnection.exportedObject = self
        newConnection.invalidationHandler = {
            exit(0)
        }
        newConnection.resume()
        return true
    }

    func perform(_ request: GitEvidenceXPCRequest, reply: @escaping (GitEvidenceXPCReply?, NSError?) -> Void) {
        _ = request
        reply(GitEvidenceXPCReply(), nil)
    }
}
