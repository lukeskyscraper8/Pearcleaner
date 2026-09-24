import Darwin
import Foundation

// A runner that exits early must not take the service down with SIGPIPE when
// the supervisor writes cat-file requests to its stdin.
signal(SIGPIPE, SIG_IGN)

let delegate = GitEvidenceServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
