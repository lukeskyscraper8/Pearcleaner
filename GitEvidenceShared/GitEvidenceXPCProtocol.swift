import Foundation

@objc(GitEvidenceXPCRequest)
public final class GitEvidenceXPCRequest: NSObject, NSSecureCoding {
    public static let supportsSecureCoding: Bool = true

    public override init() {
        super.init()
    }

    public required init?(coder: NSCoder) {
        super.init()
    }

    public func encode(with coder: NSCoder) {
        _ = coder
    }
}

@objc(GitEvidenceXPCReply)
public final class GitEvidenceXPCReply: NSObject, NSSecureCoding {
    public static let supportsSecureCoding: Bool = true

    public override init() {
        super.init()
    }

    public required init?(coder: NSCoder) {
        super.init()
    }

    public func encode(with coder: NSCoder) {
        _ = coder
    }
}

@objc(GitEvidenceXPCProtocol)
public protocol GitEvidenceXPCProtocol {
    func perform(
        _ request: GitEvidenceXPCRequest,
        reply: @escaping (GitEvidenceXPCReply?, NSError?) -> Void
    )
}
