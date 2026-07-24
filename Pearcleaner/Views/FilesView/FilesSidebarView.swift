//
//  SidebarView.swift
//  Pearcleaner
//
//  Created by Alin Lupascu on 7/31/25.
//  Modified for the independently maintained Pearcleaner fork.
//

import Foundation
import SwiftUI
import AlinFoundation

struct SidebarView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) var colorScheme
    @Binding var infoSidebar: Bool
    let displaySizeTotal: String

    var body: some View {
        if infoSidebar {
            HStack {
                Spacer()

                VStack(spacing: 0) {
                    AppDetailsHeaderView(displaySizeTotal: displaySizeTotal)
                    Divider().padding(.vertical, 5)
                    AppDetails()
                    Spacer()
                    ExtraOptions()
                }
                .padding()
                .frame(width: 250)
                .ifGlassSidebar()
            }
            .background(.black.opacity(0.00000000001))
            .transition(.move(edge: .trailing))
            .onTapGesture {
                infoSidebar = false
            }
        }
    }
}

struct AppDetailsHeaderView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) var colorScheme
    let displaySizeTotal: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {

            headerMain()


            if let buildNumber = appState.appInfo.appBuildNumber {
                headerDetailRow(label: "Version", value: "\(appState.appInfo.appVersion) (\(buildNumber))")
            } else {
                headerDetailRow(label: "Version", value: appState.appInfo.appVersion)
            }
            headerDetailRow(label: "Bundle", value: appState.appInfo.bundleIdentifier)
            headerDetailRow(label: "Total size of all files", value: displaySizeTotal)

            //MARK: Badges
            HStack(alignment: .center, spacing: 5) {

                if appState.appInfo.webApp { badge("web") }
                if appState.appInfo.wrapped { badge("iOS") }
                if appState.appInfo.arch != .empty { badge(appState.appInfo.arch.type) }
                badge(appState.appInfo.system ? "system" : "user")
                if appState.appInfo.brew { badge("brew") }
                if appState.appInfo.hasSparkle { badge("sparkle") }
                if appState.appInfo.isAppStore { badge("mas") }
                if appState.appInfo.steam { badge("steam") }

            }
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func headerMain() -> some View {
        VStack(alignment: .center) {
            if let appIcon = appState.appInfo.appIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 50, height: 50)
                    .shadow(color: appState.appInfo.averageColor ?? .black, radius: 6)
            }

            Text(appState.appInfo.appName)
                .font(.title3)
                .fontWeight(.bold)
                .lineLimit(2)
                .padding(4)
                .padding(.horizontal, 2)
//                .background {
//                    RoundedRectangle(cornerRadius: 8)
//                        .fill(appState.appInfo.averageColor ?? .clear)
//                }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private func headerDetailRow(label: String, value: String) -> some View {
        VStack(alignment: .leading) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(ThemeColors.shared(for: colorScheme).secondaryText)
            Text(value)
        }
        .padding(.bottom, 5)
    }

    @ViewBuilder
    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(ThemeColors.shared(for: colorScheme).primaryText)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(ThemeColors.shared(for: colorScheme).primaryText.opacity(0.1))
            .clipShape(Capsule())
    }
}


struct AppDetails: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var locations: Locations
    @Environment(\.colorScheme) var colorScheme
    @AppStorage("settings.general.searchSensitivity") private var globalSensitivityLevel: SearchSensitivityLevel = .strict
    @State private var isSliderActive: Bool = false

    private var localSensitivity: SearchSensitivityLevel {
        get {
            appState.perAppSensitivity[appState.appInfo.path.path] ?? globalSensitivityLevel
        }
        nonmutating set {
            appState.perAppSensitivity[appState.appInfo.path.path] = newValue
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {

            detailRow(label: "Location", value: appState.appInfo.path.deletingLastPathComponent().path, location: true)
            detailRow(label: "Date Created", value: appState.appInfo.creationDate.map { formattedMDDate(from: $0) })
            detailRow(label: "Date Added", value: appState.appInfo.dateAdded.map { formattedMDDate(from: $0) })
            detailRow(label: "Modified Date", value: appState.appInfo.contentChangeDate.map { formattedMDDate(from: $0) })
            detailRow(label: "Last Used Date".localized(), value: appState.appInfo.lastUsedDate.map { formattedMDDate(from: $0) })

            Divider().padding(.vertical, 5)

            // Sensitivity Level Slider
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Custom Sensitivity")
                        .font(.subheadline)
                        .foregroundStyle(ThemeColors.shared(for: colorScheme).secondaryText)
                    Spacer()
                    Text(localSensitivity.title)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(localSensitivity.color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(ThemeColors.shared(for: colorScheme).secondaryBG)
                        }
                }

                HStack {
                    Text("Fewer files").textCase(.uppercase).font(.caption2).foregroundStyle(ThemeColors.shared(for: colorScheme).secondaryText)
                    Slider(value: Binding(
                        get: { Double(localSensitivity.rawValue) },
                        set: { newValue in
                            let newLevel = SearchSensitivityLevel(rawValue: Int(newValue)) ?? .strict
                            localSensitivity = newLevel
                        }
                    ), in: 0...Double(SearchSensitivityLevel.allCases.count - 1), step: 1,
                           onEditingChanged: { editing in
                        isSliderActive = editing
                        if !editing {
                            // User finished adjusting the slider, now refresh with new sensitivity
                            refreshFiles()
                        }
                    })
                    .tint(localSensitivity.color)
                    Text("Most files").textCase(.uppercase).font(.caption2).foregroundStyle(ThemeColors.shared(for: colorScheme).secondaryText)
                }
            }
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 5)
    }


    private func refreshFiles() {
        // Refresh the file search with the current sensitivity level
        showAppInFiles(appInfo: appState.appInfo, appState: appState, locations: locations)
    }

    @ViewBuilder
    private func detailRow(label: String, value: String?, location: Bool = false) -> some View {
        VStack(alignment: .leading) {
            HStack(spacing: 2) {
                Text(label.localized())
                if location {
                    Button {
                        NSWorkspace.shared.selectFile(appState.appInfo.path.path, inFileViewerRootedAtPath: appState.appInfo.path.deletingLastPathComponent().path)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                }

            }
            .font(.subheadline)
            .foregroundStyle(ThemeColors.shared(for: colorScheme).secondaryText)

            Text(value ?? "--")
        }
        .padding(.bottom, 5)
    }
}



struct ExtraOptions: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var brewManager: HomebrewManager
    @Environment(\.colorScheme) var colorScheme
    @AppStorage("settings.files.showSidebarOnLoad") private var showSidebarOnLoad: Bool = false

    // Translation selection sheet state
    @State private var languageSheetWindow: NSWindow?
    @State private var availableLanguages: [LanguageInfo] = []
    @State private var selectedLanguagesToRemove: Set<String> = []
    @State private var isLoadingLanguages: Bool = false
    @State private var languageSheetAppURL: URL?

    // Homebrew adoption state
    @State private var showAdoptionSheet: Bool = false
    @State private var isLoadingCasks: Bool = false

    var body: some View {
        HStack() {
            Text("Click to dismiss").font(.caption).foregroundStyle(ThemeColors.shared(for: colorScheme).primaryText.opacity(0.5))
            Spacer()
            Menu {
                Toggle("Show sidebar on view load", isOn: $showSidebarOnLoad)

                // Homebrew Adoption (only show for non-App Store and non-Homebrew apps)
                if !appState.appInfo.isAppStore && appState.appInfo.cask == nil {
                    Divider()

                    Button(isLoadingCasks ? "Loading..." : "Adopt with Homebrew") {
                        // Lazy load casks only when user clicks
                        if brewManager.allAvailableCasks.isEmpty {
                            isLoadingCasks = true
                            Task {
                                await brewManager.loadAvailablePackages(appState: appState)
                                await MainActor.run {
                                    isLoadingCasks = false
                                    showAdoptionSheet = true
                                }
                            }
                        } else {
                            showAdoptionSheet = true
                        }
                    }
                    .disabled(isLoadingCasks)
                }

                Divider()

                if appState.appInfo.arch == .universal {
                    Button("Lipo Architectures") {
                        let app = appState.appInfo
                        let title = NSLocalizedString("App Lipo", comment: "Lipo alert title")
                        let message = String(format: NSLocalizedString("Pearcleaner will strip the %@ architecture from %@'s executable file to save space. Would you like to proceed?", comment: "Lipo alert message"), isOSArm() ? "intel" : "arm64", app.appName)
                        showCustomAlert(title: title, message: message, style: .informational, onOk: {
                            Task {
                                let eligibility = AppBundleMutationSafety.inspect(
                                    app.path
                                )
                                guard eligibility.allowsMutation else {
                                    await MainActor.run {
                                        showCustomAlert(
                                            title: "Lipo Skipped",
                                            message: eligibility.userFacingReason,
                                            style: .warning
                                        )
                                    }
                                    return
                                }

                                guard await terminateAppForMutation(
                                    bundleIdentifier: app.bundleIdentifier
                                ) else {
                                    await MainActor.run {
                                        showCustomAlert(
                                            title: "Lipo Failed",
                                            message:
                                                "\(app.appName) did not terminate, so no files were modified.",
                                            style: .critical
                                        )
                                    }
                                    return
                                }

                                let outcome = thinAppBundleArchitectureOutcome(
                                    at: app.path,
                                    of: app.arch
                                )
                                switch outcome {
                                case .succeeded:
                                    break
                                case .partiallySucceeded(_, let message):
                                    await MainActor.run {
                                        showCustomAlert(
                                            title: "Lipo Partially Completed",
                                            message: message,
                                            style: .warning
                                        )
                                    }
                                case .blocked(let eligibility):
                                    await MainActor.run {
                                        showCustomAlert(
                                            title: "Lipo Skipped",
                                            message: eligibility.userFacingReason,
                                            style: .warning
                                        )
                                    }
                                case .failed(let message):
                                    await MainActor.run {
                                        showCustomAlert(
                                            title: "Lipo Failed",
                                            message: message,
                                            style: .critical
                                        )
                                    }
                                }
                            }
                        })
                    }
                }

                Menu("Translations") {
                    Button("Auto Prune (Keep macOS Language)") {
                        let app = appState.appInfo
                        let title = NSLocalizedString("Prune Translations", comment: "Prune alert title")
                        let message = String(format: NSLocalizedString("This will remove all unused language translation files except your macOS language", comment: "Prune alert message"))
                        showCustomAlert(title: title, message: message, style: .warning, onOk: {
                            Task {
                                do {
                                    try await pruneLanguages(
                                        in: app.path.path,
                                        showAlert: true
                                    )
                                } catch {
                                    await MainActor.run {
                                        showCustomAlert(
                                            title: "Prune Skipped",
                                            message: error.localizedDescription,
                                            style: .warning
                                        )
                                    }
                                    printOS("Translation prune error: \(error)")
                                }
                            }
                        })
                    }

                    Button("Choose Languages...") {
                        Task {
                            await showLanguageSelectionSheet()
                        }
                    }
                }
            } label: {
                Label("Options", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderedButton)
            .menuIndicator(.hidden)
            .fixedSize()

        }
        .sheet(isPresented: $showAdoptionSheet) {
            AdoptionSheetView(
                appInfo: appState.appInfo,
                context: .filesView,
                isPresented: $showAdoptionSheet
            )
            .environmentObject(brewManager)
        }
    }

    // MARK: - Language Selection Sheet

    private func showLanguageSelectionSheet() async {
        let app = appState.appInfo
        guard let parentWindow = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) else {
            return
        }

        await MainActor.run {
            // Set initial loading state
            self.isLoadingLanguages = true
            self.availableLanguages = []
            self.selectedLanguagesToRemove = []
            self.languageSheetAppURL = app.path

            // Create the SwiftUI view with loading state
            let contentView = TranslationSelectionSheet(
                appName: app.appName,
                appPath: app.path.path,
                languages: $availableLanguages,
                selectedLanguages: $selectedLanguagesToRemove,
                isLoading: $isLoadingLanguages,
                onConfirm: {
                    if let sheetWindow = self.languageSheetWindow {
                        parentWindow.endSheet(sheetWindow)
                    }
                    self.languageSheetWindow = nil
                    self.languageSheetAppURL = nil
                    Task {
                        await performManualPrune(in: app.path)
                    }
                },
                onCancel: {
                    if let sheetWindow = self.languageSheetWindow {
                        parentWindow.endSheet(sheetWindow)
                    }
                    self.languageSheetWindow = nil
                    self.languageSheetAppURL = nil
                }
            )

            // Create sheet window
            let hostingController = NSHostingController(rootView: contentView)

            let sheetWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            sheetWindow.title = "Choose Translations"
            sheetWindow.contentViewController = hostingController
            sheetWindow.isReleasedWhenClosed = false

            // Present as sheet (shows loading state immediately)
            parentWindow.beginSheet(sheetWindow)

            self.languageSheetWindow = sheetWindow
        }

        // Load languages in background
        let languages = await findAvailableLanguages(in: app.path.path)

        // Update with results
        await MainActor.run {
            guard self.languageSheetAppURL == app.path else { return }
            self.availableLanguages = languages
            self.isLoadingLanguages = false
        }
    }

    private func performManualPrune(in appBundleURL: URL) async {
        // Filter selected languages from available languages by code
        let languagesToRemove = availableLanguages.filter { language in
            selectedLanguagesToRemove.contains(language.code)
        }

        do {
            let result = try await pruneLanguagesManual(
                languagesToRemove: languagesToRemove,
                in: appBundleURL
            )

            await MainActor.run {
                let removedCount = result.removedLanguageCount
                let keptCount = availableLanguages.count - removedCount
                let message: String
                if result.allSucceeded {
                    message =
                        "Successfully removed \(removedCount) language\(removedCount == 1 ? "" : "s"). Kept \(keptCount) language\(keptCount == 1 ? "" : "s")."
                } else {
                    message =
                        "Removed \(removedCount) of \(result.requestedLanguageCount) selected languages. \(result.failedPathCount) translation folder(s) could not be removed."
                }
                showCustomAlert(
                    title: result.allSucceeded
                        ? "Translations Pruned"
                        : "Translations Partially Pruned",
                    message: message,
                    style: result.allSucceeded ? .informational : .warning
                )
            }
        } catch {
            await MainActor.run {
                showCustomAlert(
                    title: "Prune Failed",
                    message: "Failed to prune translations: \(error.localizedDescription)",
                    style: .critical
                )
            }
            printOS("Manual translation prune error: \(error)")
        }
    }
}
