//
//  About.swift
//  Pearcleaner
//
//  Created by Alin Lupascu on 11/5/23.
//  Modified for the independently maintained Pearcleaner fork.
//

import SwiftUI
import AlinFoundation

struct AboutSettingsTab: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) var colorScheme
    @State private var disclose = false
    @State private var discloseCredits = false
    @State private var isResetting = false

    var body: some View {

        VStack(alignment: .center) {

            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                Text(Bundle.main.name)
                    .foregroundStyle(ThemeColors.shared(for: colorScheme).primaryText)
                    .font(.title)
                    .bold()
                HStack {
                    Text("Version \(Bundle.main.version)")
                    Text("(Build \(Bundle.main.buildVersion))")
                        .font(.footnote)
                        .foregroundStyle(ThemeColors.shared(for: colorScheme).primaryText)
                }
                .foregroundStyle(ThemeColors.shared(for: colorScheme).primaryText)

                Text("Created by Alin Lupascu")
                    .foregroundStyle(ThemeColors.shared(for: colorScheme).primaryText)
                    .font(.footnote)
                Text("Independently maintained fork by Luke Row")
                    .foregroundStyle(ThemeColors.shared(for: colorScheme).secondaryText)
                    .font(.footnote)

            }
            .padding(.vertical, 50)


            VStack(spacing: 20) {
                // GitHub
                PearGroupBox(header: { Text("Support").foregroundStyle(ThemeColors.shared(for: colorScheme).primaryText).font(.title) }, content: {
                    HStack{
                        Image(systemName: "ant")
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(ThemeColors.shared(for: colorScheme).primaryText)
                            .frame(width: 20, height: 20)
                            .padding(.trailing)

                        VStack(alignment: .leading){
                            Text("Report a bug or request support")
                                .font(.title3)
                                .foregroundStyle(ThemeColors.shared(for: colorScheme).primaryText)

                        }
                        Spacer()
                        Button {
                            NSWorkspace.shared.open(URL(string: "https://github.com/lukeskyscraper8/Pearcleaner/issues/new/choose")!)
                        } label: {
                            Text("View")
                        }
                        .controlSize(.small)
                        .buttonStyle(.plain)
                        .foregroundStyle(ThemeColors.shared(for: colorScheme).accent)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 14)
                        .controlGroup(Capsule(style: .continuous), level: .primary)
                    }

                })

                // Translators
                PearGroupBox(header: { Text("Translation").foregroundStyle(ThemeColors.shared(for: colorScheme).primaryText).font(.title) }, content: {
                    HStack{
                        Image(systemName: "globe")
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(ThemeColors.shared(for: colorScheme).primaryText)
                            .frame(width: 20, height: 20)
                            .padding(.trailing)

                        VStack(alignment: .leading, spacing: 10){
                            Text("A **huge** thank you to everyone who has contributed so far!")
                                .font(.title3)
                                .foregroundStyle(ThemeColors.shared(for: colorScheme).primaryText)
                            Text(translators)
                                .font(.callout)
                                .foregroundStyle(ThemeColors.shared(for: colorScheme).secondaryText)

                        }

                        Spacer()
                        Button {
                            NSWorkspace.shared.open(URL(string: "https://github.com/alienator88/Pearcleaner/discussions/137")!)
                        } label: {
                            Text("View")
                        }
                        .controlSize(.small)
                        .buttonStyle(.plain)
                        .foregroundStyle(ThemeColors.shared(for: colorScheme).accent)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 14)
                        .controlGroup(Capsule(style: .continuous), level: .primary)

                    }

                })

                SettingsControlButtonGroup(isResetting: $isResetting, resetAction: {
                    resetUserDefaults()
                }, exportAction: {
                    exportUserDefaults()
                }, importAction: {
                    importUserDefaults()
                })

            }

        }
    }

    private func resetUserDefaults() {
        isResetting = true
        DispatchQueue.global(qos: .background).async {
            let keys = UserDefaults.standard.dictionaryRepresentation().keys
                .filter { $0.hasPrefix("settings.") }
            for key in keys {
                UserDefaults.standard.removeObject(forKey: key)
            }
            DispatchQueue.main.async {
                isResetting = false
            }
        }
    }

    private func exportUserDefaults() {
        let defaults = UserDefaults.standard.dictionaryRepresentation()
        let settingsOnly = defaults.filter { $0.key.hasPrefix("settings.") }
        let jsonData: Data
        do {
            jsonData = try SettingsExportCodec.exportData(from: settingsOnly)
        } catch {
            printOS("Settings export failed: \(error.localizedDescription)")
            return
        }

        let savePanel = NSSavePanel()
        savePanel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        savePanel.allowedContentTypes = [.json]
        savePanel.nameFieldStringValue = "PearcleanerSettings.json"
        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else { return }
            do {
                try jsonData.write(to: url, options: .atomic)
            } catch {
                printOS("Settings export write failed: \(error.localizedDescription)")
            }
        }
    }

    private func importUserDefaults() {
        let openPanel = NSOpenPanel()
        openPanel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        openPanel.allowedContentTypes = [.json]
        openPanel.begin { response in
            guard response == .OK, let url = openPanel.url,
                  let data = try? Data(contentsOf: url) else { return }

            do {
                let settings = try SettingsExportCodec.importSettings(from: data)
                for (key, value) in settings {
                    UserDefaults.standard.set(value, forKey: key)
                }
            } catch {
                printOS("Settings import failed: \(error.localizedDescription)")
            }
        }
    }
}


let translators = "changanmoon, L1cardo, funsiyuan, megabitsenmzq, iFloneUEFN, matxpa, vogt65, AgiMaulana, kiwamizamurai, readingsnail, rokartur, MARCELOisME, exituser, Skro11-ru, Svec-Tomas, DrRoglaa, realkeremcam, Ihor-Khomenko, HungThinhIT"
