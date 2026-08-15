//
//  AppGroupDefaults.swift
//  Pearcleaner
//
//  Created by Alin Lupascu on 9/30/25.
//

import Foundation

extension UserDefaults {
    static let appGroup = UserDefaults(suiteName: "group.com.lukerow.pearcleaner.68583n3mnf")!

    struct Keys {
        static let showAppIconInMenu = "showAppIconInMenu"
        static let sentinelWatcherPaused = "sentinelWatcherPaused"
    }

    // Setting for showing app icon in context menu
    static var showAppIconInMenu: Bool {
        get {
            return appGroup.bool(forKey: Keys.showAppIconInMenu)
        }
        set {
            appGroup.set(newValue, forKey: Keys.showAppIconInMenu)
        }
    }

    static var sentinelWatcherPaused: Bool {
        get {
            return appGroup.bool(forKey: Keys.sentinelWatcherPaused)
        }
        set {
            appGroup.set(newValue, forKey: Keys.sentinelWatcherPaused)
        }
    }
}
