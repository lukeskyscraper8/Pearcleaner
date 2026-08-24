import Foundation

enum GitPathParsing {
    static func verifiedRelativePath(fromGitPath path: String) -> VerifiedRelativePath? {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\\") else {
            return nil
        }

        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }

        var components: [VerifiedPathComponent] = []
        components.reserveCapacity(parts.count)
        for part in parts {
            let text = String(part)
            if text.isEmpty || text == "." || text == ".." {
                return nil
            }
            guard let component = try? VerifiedPathComponent(bytes: Data(text.utf8)) else {
                return nil
            }
            components.append(component)
        }

        return try? VerifiedRelativePath(components: components)
    }

    static func verifiedRelativePaths(fromGitPaths paths: [String]) -> Set<VerifiedRelativePath> {
        Set(paths.compactMap(verifiedRelativePath(fromGitPath:)))
    }
}
