//
//  Helper.swift
//  Pearcleaner
//
//  Created by Alin Lupascu on 3/14/25.
//  Modified for the independently maintained Pearcleaner fork.
//

import SwiftUI
import Foundation
import AlinFoundation

struct HelperSettingsTab: View {
    @Environment(\.colorScheme) var colorScheme
    @ObservedObject private var helperToolManager = HelperToolManager.shared
#if DEBUG
    @State private var commandOutput: String = "Command output will display here"
    @State private var commandToRun: String = "whoami"
    @State private var showTestingUI: Bool = false
#endif

    var body: some View {
        VStack(spacing: 20) {

            // === Frequency ============================================================================================
            PearGroupBox(
                header: {
                    HStack {
                        Text("Management").foregroundStyle(ThemeColors.shared(for: colorScheme).primaryText).font(.title2)
                        Spacer()
//                        Button(action: {
                    }

                },
                content: {

                    VStack {
                        HStack(spacing: 0) {
                            Image(systemName: "key")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 20, height: 20)
                                .padding(.trailing)
                                .foregroundStyle(ThemeColors.shared(for: colorScheme).primaryText)
#if DEBUG
                                .onTapGesture {
                                    showTestingUI.toggle()
                                }
#endif
                            Text("Perform privileged operations seamlessly without password prompts")
                                .font(.callout)
                                .foregroundStyle(ThemeColors.shared(for: colorScheme).primaryText)
                                .frame(minWidth: 450, maxWidth: .infinity, alignment: .leading)

//                            Spacer()

                            Toggle(isOn: Binding(
                                get: { helperToolManager.isHelperToolInstalled },
                                set: { newValue in
                                    Task {
                                        if newValue {
                                            await helperToolManager.manageHelperTool(action: .install)
                                        } else {
                                            await helperToolManager.manageHelperTool(action: .uninstall)
                                        }
                                    }
                                }
                            ), label: {
                            })
                            .toggleStyle(SettingsToggle())
                            .frame(alignment: .trailing)

                        }

                        Divider()
                            .padding(.vertical, 5)

                        HStack {
                            Text(helperToolManager.message)
                                .font(.footnote)
                                .foregroundStyle(ThemeColors.shared(for: colorScheme).secondaryText)
                            Spacer()

                        }
                    }
                    .padding(5)



                })


            PearGroupBox(header: {
                Text("Information").foregroundStyle(ThemeColors.shared(for: colorScheme).primaryText).font(.title2)
            }, content: {
                let message: LocalizedStringKey = """
                Pearcleaner will ask you to enter your password once to enable the helper, then all subsequent privileged operations will run without any other prompts as long as the helper stays enabled in Settings > Login Items. This authorization is all managed by macOS via SMAppService.
                """

                VStack(alignment: .leading, spacing: 20) {
                    Text(message).foregroundStyle(ThemeColors.shared(for: colorScheme).primaryText).font(.body).lineSpacing(5)

                    Text("Pearcleaner uses the signed helper for normal privileged operations. The deprecated authorization prompt is retained only as a recovery fallback when the helper cannot be reached.").font(.footnote).foregroundStyle(ThemeColors.shared(for: colorScheme).secondaryText)
                }

            })

#if DEBUG
            if showTestingUI {
            PearGroupBox(header: {
                Text("Helper Playground").foregroundStyle(ThemeColors.shared(for: colorScheme).primaryText).font(.title2)
            }, content: {
                VStack {

                    Picker("Example privileged commands", selection: $commandToRun) {
                        Text(verbatim: "whoami").tag("whoami")
                    }
                    .foregroundStyle(ThemeColors.shared(for: colorScheme).primaryText)
                    .pickerStyle(MenuPickerStyle())
                    .onChange(of: commandToRun) { _ in
                        Task { await runAllowedHelperProbe() }
                    }
                    .onAppear {
                        Task { await runAllowedHelperProbe() }
                    }

                    ScrollView {
                        Text(commandOutput)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(ThemeColors.shared(for: colorScheme).secondaryText)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                            .padding()
                    }
                    .frame(height: 150)
                    .frame(maxWidth: .infinity)
                    .background(.tertiary.opacity(0.1))
                    .cornerRadius(8)

                    Text("**whoami** command should return 'root' if helper is running correctly.").font(.footnote).foregroundStyle(ThemeColors.shared(for: colorScheme).secondaryText)
                        .padding(.top, 5)
                }
                .padding(5)
            })
            .disabled(!helperToolManager.isHelperToolInstalled)
            .opacity(helperToolManager.isHelperToolInstalled ? 1 : 0.5)
            }
#endif


        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task {
                await helperToolManager.manageHelperTool()
            }
#if DEBUG
            if helperToolManager.isHelperToolInstalled && showTestingUI {
                Task { await runAllowedHelperProbe() }
            }
#endif
        }

    }

#if DEBUG
    private func runAllowedHelperProbe() async {
        guard helperToolManager.isHelperToolInstalled else { return }
        let (success, output) = await helperToolManager.runOperation("whoami")
        await MainActor.run {
            commandOutput = success ? output : "Error: \(output)"
        }
    }
#endif

}
