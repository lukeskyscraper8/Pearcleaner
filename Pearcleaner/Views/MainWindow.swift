//
//  AppListH.swift
//  Pearcleaner
//
//  Created by Alin Lupascu on 11/5/23.
//

import AlinFoundation
import Foundation
import SwiftUI

struct MainWindow: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var consoleManager = GlobalConsoleManager.shared
    @StateObject private var brewManager = HomebrewManager()
    @StateObject private var updateManager = UpdateManager.shared
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var locations: Locations
    @EnvironmentObject var fsm: FolderSettingsManager
    @EnvironmentObject var updater: Updater
    @EnvironmentObject var permissionManager: PermissionManagerLocal
    @Environment(\.colorScheme) var colorScheme
    @AppStorage("settings.general.glass") private var glass: Bool = false
    @AppStorage("settings.general.sidebarWidth") private var sidebarWidth: Double = 265
    @AppStorage("settings.interface.animationEnabled") private var animationEnabled: Bool = true
    @AppStorage("settings.tutorial.switchUtilitiesShown") private var tutorialShown: Bool = true
    @AppStorage("settings.updater.loadOnStartup") private var loadUpdatesOnStartup: Bool = true
    @AppStorage("settings.console.state") private var consoleStateData: Data = Data()

    @State private var isDraggingOver: Bool = false
    @State private var showSys: Bool = true
    @State private var showUsr: Bool = true
    @State private var showMenu = false
    @State private var isFullscreen = false

    // Badges
    @State private var showUpdateView = false
    @State private var showFeatureView = false
    @State private var showPermissionList = false
    @State private var glowRadius = 0.0

    var body: some View {

        // Main App Window
        ZStack {

            HStack(alignment: .center, spacing: 0) {

                Group {
                    switch appState.currentPage {
                    case .applications:
                        withConsole {
                            applicationsView
                        }

                    case .orphans:
                        withConsole {
                            ZombieView()
                        }

                    case .development:
                        withConsole {
                            EnvironmentCleanerView()
                        }

                    case .lipo:
                        withConsole {
                            LipoView()
                        }

                    case .services:
                        withConsole {
                            DaemonView()
                        }

                    case .packages:
                        withConsole {
                            PackageView()
                        }

                    case .plugins:
                        withConsole {
                            PluginsView()
                        }

                    case .fileSearch:
                        withConsole {
                            FileSearchView()
                        }

                    case .homebrew:
                        HomebrewView()
                            .environmentObject(brewManager)

                    case .updater:
                        withConsole {
                            AppsUpdaterView()
                                .environmentObject(brewManager)
                                .environmentObject(updateManager)
                        }
                    }
                }

            }

            // Drop overlay
            if isDraggingOver {
                ZStack {
                    ThemeColors.shared(for: colorScheme).primaryBG
                        .ignoresSafeArea()

                    Image(systemName: "arrow.down")
                        .font(.system(size: 100))
                        .foregroundColor(ThemeColors.shared(for: colorScheme).primaryText)
                        .padding(40)
                        .background(
                            RoundedRectangle(cornerRadius: 20)
                                .strokeBorder(style: StrokeStyle(lineWidth: 5, dash: [10, 5]))
                                .foregroundColor(ThemeColors.shared(for: colorScheme).primaryText)
                        )
                }
                .transition(.opacity)
            }

            // Badge overlay (unified overlay for all badge notifications)
            BadgeOverlay()
                .environmentObject(updater)
                .zIndex(100)

        }
        .background(backgroundView(color: ThemeColors.shared(for: colorScheme).primaryBG))
        .frame(minWidth: 900, minHeight: 650)
        .handlesExternalEvents(preferring: Set(arrayLiteral: "pear"), allowing: Set(arrayLiteral: "*"))
        .handleFileDrop(
            updater: updater,
            fsm: fsm,
            appState: appState,
            locations: locations,
            isTargeted: $isDraggingOver
        )
        .onOpenURL(perform: { url in
            let deeplinkManager = DeeplinkManager(updater: updater, fsm: fsm)
            deeplinkManager.manage(url: url, appState: appState, locations: locations)
        })
        .sheet(isPresented: $updater.sheet, content: {
            /// This will show the update sheet based on the frequency check function only
            updater.getUpdateView()
        })
        .sheet(isPresented: $appState.showDeleteHistory, content: {
            DeleteHistoryView()
                .environmentObject(appState)
                .environmentObject(locations)
                .environmentObject(fsm)
        })
        .onReceive(
            NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)
        ) { _ in
            isFullscreen = true
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)
        ) { _ in
            isFullscreen = false
        }
        .task {
            // Restore console state from AppStorage
            if let decoded = try? JSONDecoder().decode(ConsoleState.self, from: consoleStateData) {
                await MainActor.run {
                    consoleManager.showConsole = decoded.isOpen
                    consoleManager.consoleHeight = decoded.height
                }
            }
        }
        .onChange(of: consoleManager.showConsole) { newValue in
            // Save console state
            let state = ConsoleState(isOpen: newValue, height: consoleManager.consoleHeight)
            if let encoded = try? JSONEncoder().encode(state) {
                consoleStateData = encoded
            }

            // When console is hidden, trim output to 300 lines max to prevent memory bloat
            if !newValue {
                Task { @MainActor in
                    consoleManager.trimOutput(toLines: 300)
                }
            }
        }
        .onChange(of: consoleManager.consoleHeight) { newValue in
            // Save console height when changed
            let state = ConsoleState(isOpen: consoleManager.showConsole, height: newValue)
            if let encoded = try? JSONEncoder().encode(state) {
                consoleStateData = encoded
            }
        }
        .toolbar {
            TahoeToolbarItem(placement: .navigation, isGroup: true) {

                // Page Selector
                Menu {
                    ForEach(CurrentPage.availablePages, id: \.self) { page in
                        Button {
                            // Animate only the page content transition
                            withAnimation(.easeInOut(duration: animationEnabled ? 0.3 : 0)) {
                                // Reset appInfo when changing pages
                                if page == .applications {
                                    appState.appInfo = .empty
                                    appState.currentView = .empty
                                }
                            }

                            // Change page immediately (no animation on toolbar icon)
                            appState.currentPage = page

                            // Hide tutorial when user interacts with menu
                            if tutorialShown {
                                tutorialShown = false
                            }
                        } label: {
                            if page == .updater {
                                HStack(spacing: 8) {
                                    Image(systemName: page.icon)
                                        .frame(width: 16)
                                    if loadUpdatesOnStartup || updateManager.totalUpdateCount > 0 {
                                        Text(page.title)
                                            .foregroundStyle(ThemeColors.shared(for: colorScheme).primaryText)
                                            .badge(updateManager.totalUpdateCount)
                                    } else {
                                        Text(page.title)
                                            .foregroundStyle(ThemeColors.shared(for: colorScheme).primaryText)
                                    }
                                }
                            } else {
                                HStack(spacing: 8) {
                                    Image(systemName: page.icon)
                                        .frame(width: 16)
                                    Text(page.title)
                                        .foregroundStyle(ThemeColors.shared(for: colorScheme).primaryText)
                                }
                            }
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: appState.currentPage.icon)
                    }
                }
                .menuIndicator(.hidden)

                if tutorialShown {
                    HStack {
                        Image(systemName: "arrowshape.left.fill")
                        Text("Switch Utilities")
                    }
                    .foregroundStyle(ThemeColors.shared(for: colorScheme).accent)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(ThemeColors.shared(for: colorScheme).secondaryBG)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(
                                        ThemeColors.shared(for: colorScheme).accent.opacity(0.5),
                                        lineWidth: 1)
                            )
                    )
                    .onTapGesture {
                        // Hide tutorial when user interacts with label
                        tutorialShown = false
                    }
                }

                // Notice Icons
                if updater.updateAvailable {
                    noticeButton(
                        image: "icloud.and.arrow.down.fill",
                        color: .green,
                        help: "Update Available"
                    ) {
                        showUpdateView.toggle()
                    }
                    .sheet(isPresented: $showUpdateView) {
                        updater.getUpdateView()
                    }
                } else if updater.announcementAvailable {
                    noticeButton(
                        image: "sparkles.2",
                        color: .purple,
                        help: "New Feature"
                    ) {
                        showFeatureView.toggle()
                    }
                    .sheet(isPresented: $showFeatureView) {
                        updater.getAnnouncementView()
                    }
                } else if permissionManager.shouldShowPermissionWarning {
                    noticeButton(
                        image: "lock.slash.fill",
                        color: .red,
                        help: "Permissions Missing"
                    ) {
                        showPermissionList.toggle()
                    }
                    .sheet(isPresented: $showPermissionList) {
                        PermissionsSheetView()
                    }
                } else if HelperToolManager.shared.shouldShowHelperBadge {
                    noticeButton(
                        image: "gear",
                        color: .orange,
                        help: "Helper Not Installed"
                    ) {
                        openAppSettingsWindow(tab: .helper, updater: updater)
                    }
                }

            }

        }
    }

    @ViewBuilder
    private func noticeButton(
        image: String, color: Color, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: image)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(color)
            }
            .shadow(color: Color(NSColor.windowBackgroundColor).opacity(1), radius: 1, x: 0, y: 0)
            .shadow(color: color.opacity(1), radius: glowRadius, x: 0, y: 0)
            .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: glowRadius)
        }
        .buttonStyle(.plain)
        .help(help)
        .onAppear {
            glowRadius = 5.0
        }
    }

    /// Helper to wrap view content with console at bottom
    @ViewBuilder
    private func withConsole<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()

            if consoleManager.showConsole && !(appState.currentPage == .applications && appState.currentView == .empty) {
                GlobalConsoleView(
                    output: consoleManager.consoleOutput,
                    height: $consoleManager.consoleHeight,
                    onClear: {
                        Task { @MainActor in
                            consoleManager.clearOutput()
                        }
                    }
                )
                .frame(height: consoleManager.consoleHeight)
                .transition(.move(edge: .bottom))
            }
        }
    }

    @ViewBuilder
    private var applicationsView: some View {
        HStack(alignment: .center, spacing: 0) {

            // App List
            AppSearchView()
                .frame(width: sidebarWidth)
                .transition(.opacity)
                .ifGlassMain()
                .padding([.leading, .vertical], 8)
                .ignoresSafeArea(edges: .top)

            HStack(spacing: 0) {
                Group {
                    switch appState.currentView {
                    case .empty:
                        MountedVolumeView()
                            .id(appState.appInfo.id)
                    case .files:
                        FilesView()
                            .id(appState.appInfo.id)
                            .environmentObject(brewManager)
                    }
                }
                .transition(.opacity)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .zIndex(2)
        }
    }

}
