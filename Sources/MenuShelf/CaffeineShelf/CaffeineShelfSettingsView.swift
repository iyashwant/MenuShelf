//
//  CaffeineShelfSettingsView.swift
//  MenuShelf
//
//  Settings tab for the CaffeineShelf feature. The `.caffeineShelf` case in
//  `SettingsSection` and the dispatch that constructs this view stay in
//  SettingsView.swift since they're inside an exhaustive switch.
//

import AppKit
import SwiftUI

struct CaffeineShelfSettingsView: View {
    @EnvironmentObject private var store: PreferencesStore

    /// Whether the privileged lid-closed grant is currently installed. Probed
    /// off the main thread on appear and after any grant change.
    @State private var lidGrantInstalled = false

    private var caffeine: CaffeineShelfSettings {
        store.settings.resolvedCaffeineShelf
    }

    var body: some View {
        SettingsPane(
            "CaffeineShelf",
            subtitle: "Keep your Mac awake from the menu bar.",
            symbolName: "cup.and.saucer"
        ) {
            SettingsCard("CaffeineShelf") {
                SettingsToggle(
                    "Enable CaffeineShelf",
                    helper: "Add a menu-bar control that prevents your Mac from going to sleep.",
                    isOn: Binding(
                        get: { caffeine.enableCaffeineShelf },
                        set: { store.setEnableCaffeineShelf($0) }
                    )
                )
            }

            if caffeine.enableCaffeineShelf {
                SettingsCard("Behavior") {
                    SettingsToggle(
                        "Allow the display to sleep",
                        helper: "Keep the system awake but let the screen turn off (otherwise the display stays on too).",
                        isOn: Binding(
                            get: { caffeine.allowDisplaySleep },
                            set: { value in
                                store.updateCaffeineShelfSettings { $0.allowDisplaySleep = value }
                            }
                        )
                    )

                    SettingsRow(
                        "When toggled on",
                        helper: "Duration applied when you click the icon to keep awake without picking a length."
                    ) {
                        Picker("", selection: Binding(
                            get: { caffeine.defaultDurationSeconds },
                            set: { value in
                                store.updateCaffeineShelfSettings { $0.defaultDurationSeconds = value }
                            }
                        )) {
                            ForEach(CaffeineShelfDurationOption.all) { option in
                                Text(option.shortLabel).tag(option.seconds)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 160)
                    }
                }

                SettingsCard("Lid Closed") {
                    SettingsToggle(
                        "Keep awake with lid closed",
                        helper: "Stay awake even when the lid is shut. Needs a one-time admin approval and changes a protected macOS setting (pmset disablesleep).",
                        isOn: Binding(
                            get: { caffeine.resolvedKeepAwakeWithLidClosed },
                            set: { value in
                                CaffeineShelfController.shared.setLidClosedMode(value)
                            }
                        )
                    )

                    SettingsBlockRow {
                        HStack(spacing: 10) {
                            if lidGrantInstalled {
                                Label("Permission granted", systemImage: "checkmark.seal.fill")
                                    .foregroundStyle(.green)
                                Spacer()
                                Button("Remove Permission") { removeLidGrant() }
                            } else {
                                Label("Permission not granted", systemImage: "lock")
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                        }
                    }

                    if !lidGrantInstalled {
                        SettingsBlockRow {
                            Text("You'll be asked to approve once (Touch ID or password) when you turn this on.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                SettingsCard("Auto-Off") {
                    SettingsToggle(
                        "Allow sleep on low battery",
                        helper: "Stop keeping the Mac awake when the battery drops to the threshold while on battery power.",
                        isOn: Binding(
                            get: { caffeine.batteryAutoOffEnabled },
                            set: { value in
                                store.updateCaffeineShelfSettings { $0.batteryAutoOffEnabled = value }
                            }
                        )
                    )

                    if caffeine.batteryAutoOffEnabled {
                        SettingsRow("Battery threshold") {
                            HStack(spacing: 10) {
                                Slider(
                                    value: Binding(
                                        get: { caffeine.batteryThresholdPercent },
                                        set: { value in
                                            store.updateCaffeineShelfSettings { $0.batteryThresholdPercent = value }
                                        }
                                    ),
                                    in: 10...100,
                                    step: 5
                                )
                                .frame(width: 160)

                                Text("\(Int(caffeine.resolvedBatteryThresholdPercent))%")
                                    .monospacedDigit()
                                    .frame(width: 44, alignment: .trailing)
                            }
                        }
                    }

                    SettingsToggle(
                        "Allow sleep in Low Power Mode",
                        helper: "Stop keeping the Mac awake when macOS Low Power Mode turns on.",
                        isOn: Binding(
                            get: { caffeine.lowPowerModeAutoOffEnabled },
                            set: { value in
                                store.updateCaffeineShelfSettings { $0.lowPowerModeAutoOffEnabled = value }
                            }
                        )
                    )
                }

                SettingsCard("Menu Bar") {
                    SettingsBlockRow {
                        Text("Add a CaffeineShelf icon from the Menu Bar tab. Left-click it for the toggle and durations; right-click (or ⌥-click) opens these settings.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .task { refreshLidGrantStatus() }
        .onChange(of: caffeine.resolvedKeepAwakeWithLidClosed) { _, _ in
            refreshLidGrantStatus()
        }
    }

    /// Probe whether the lid-closed grant is installed, off the main thread.
    private func refreshLidGrantStatus() {
        Task {
            let installed = await Task.detached {
                CaffeineShelfLidControl.isGrantInstalled()
            }.value
            lidGrantInstalled = installed
        }
    }

    /// Turn the feature off (clearing `disablesleep` while the grant still
    /// works), remove the grant, then refresh status. The clear-then-remove
    /// order runs in one detached task so the reset can't race the removal.
    private func removeLidGrant() {
        store.setKeepAwakeWithLidClosed(false)
        Task {
            await Task.detached {
                _ = CaffeineShelfLidControl.setDisableSleep(false)
                _ = CaffeineShelfLidControl.removeGrant()
            }.value
            CaffeineShelfController.shared.notifyLidGrantRemoved()
            refreshLidGrantStatus()
        }
    }
}
