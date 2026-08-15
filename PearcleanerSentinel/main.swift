//
//  main.swift
//  PearcleanerSentinel
//
//  Created by Alin Lupascu on 11/9/23.
//


import AppKit

main()

var globalFileWatcher: FileWatcher?

func startGlobalFileWatcher() {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    globalFileWatcher = FileWatcher(["\(home)/.Trash"])
    globalFileWatcher?.queue = DispatchQueue.global()
    globalFileWatcher?.callback = { event in
        checkApp(file: event.path)
    }
    globalFileWatcher?.start()
}

func main() {
    startGlobalFileWatcher()
    RunLoop.main.run()
}


func checkApp(file: String) {
    let app = URL(fileURLWithPath: file)
    let appExt = app.pathExtension
    if appExt == "app" {
        if let appBundle = Bundle(url: app) {
            if appBundle.bundleIdentifier == "com.lukerow.Pearcleaner" {
                return
            } else {
                if FileManager.default.isInTrash(app) {
                    if UserDefaults.sentinelWatcherPaused {
                        return
                    }
                    var components = URLComponents()
                    components.scheme = "pear"
                    components.host = "openApp"
                    components.queryItems = [URLQueryItem(name: "path", value: file)]

                    if let url = components.url {
                        NSWorkspace.shared.open(url)
                    } else {
                        NSLog("PearcleanerSentinel: Failed to construct Pearcleaner URL for %@", file as NSString)
                    }
                }
            }
        } else {
            print("Error: Unable to get bundle information for \(file)")
        }
    }
}



// --- Trash Relationship ---
extension FileManager {
    public func isInTrash(_ file: URL) -> Bool {
        var relationship: URLRelationship = .other
        do {
            try getRelationship(&relationship, of: .trashDirectory, in: .userDomainMask, toItemAt: file)
            return relationship == .contains
        } catch {
            return false
        }
    }
}
