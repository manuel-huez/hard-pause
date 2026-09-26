import AppKit
import ApplicationServices
import SwiftUI

struct AppleProtectionCard: View {
    @ObservedObject var model: AppleProtectionModel
    var canRemoveCode = false
    @State private var showsSetup = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Screen Time protection")
                    .font(PauseFont.display(18, relativeTo: .headline))
                Spacer()
                Text(stateLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(needsAttention ? .orange : PauseTheme.muted)
            }
            Text(statusText)
                .foregroundStyle(PauseTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            if let activity = model.activity {
                ProgressView(activity.label).controlSize(.small)
            } else {
                actions
            }
            if model.hasError, let message = model.message {
                Text(message).font(.callout).foregroundStyle(.orange)
            }
            if let message = model.websiteSyncMessage {
                Text(message).font(.callout)
                    .foregroundStyle(model.websiteSyncNeedsRetry ? .orange : PauseTheme.muted)
                Button(model.websiteSyncNeedsRetry ? "Retry website sync" : "Review website sync") {
                    Task { await model.syncWebsites(presentingResult: true) }
                }
                .buttonStyle(PauseButtonStyle())
                .disabled(model.isBusy)
            }
            if model.snapshot?.phase.hasConfirmedSystemPasscode == true {
                DisclosureGroup("Details") {
                    VStack(alignment: .leading, spacing: 10) {
                        if model.snapshot?.enablesAdultFilter == true {
                            Text("Apple’s adult filter and website limits stay on during breaks.")
                            if let websites = model.nativeWebsites {
                                websiteGroup("Restricted", entries: websites.restrictedEntries)
                                websiteGroup("Allowed", entries: websites.allowedEntries)
                            }
                        }
                        Text(
                            "This status is saved on this Mac. iPhone protection and device sharing are not verified. Apple account recovery can still reset the code."
                        )
                    }
                    .font(.caption).foregroundStyle(PauseTheme.muted)
                    .padding(.top, 8)
                }
            }
        }
        .task { await model.refresh() }
        .sheet(isPresented: $showsSetup) { AppleProtectionSetupView(model: model) }
        .screenTimeWebsiteOverwriteSheet(model: model, isActive: !showsSetup)
    }

    @ViewBuilder private var actions: some View {
        switch model.snapshot?.phase {
        case .inactive:
            Button("Set up Screen Time") { showsSetup = true }
                .buttonStyle(PauseButtonStyle(primary: true))
        case .pendingSetup:
            Button("Continue setup") { showsSetup = true }
                .buttonStyle(PauseButtonStyle(primary: true))
        case .active:
            if model.snapshot?.fullUnlockDelay != 0 {
                Button("Request to end protection") { Task { await model.requestEnd() } }
                    .buttonStyle(PauseButtonStyle())
            } else if canRemoveCode {
                Button("Remove unused Screen Time code") {
                    Task {
                        await model.requestEnd()
                        if model.snapshot?.phase == .readyForRelease { await model.finishEnd() }
                    }
                }
                .buttonStyle(PauseButtonStyle())
            }
        case .readyForRelease, .releaseInProgress:
            Button("Finish removing code") { Task { await model.finishEnd() } }
                .buttonStyle(PauseButtonStyle(primary: true))
        case nil:
            if model.hasError {
                Button("Retry connection") { Task { await model.refresh() } }
                    .buttonStyle(PauseButtonStyle())
            }
        case .waitingForFullUnlock: EmptyView()
        }
    }

    private var needsAttention: Bool {
        model.hasError || model.websiteSyncMessage != nil || model.snapshot?.phase == .pendingSetup
    }

    private var stateLabel: String {
        if needsAttention { return "Needs attention" }
        switch model.snapshot?.phase {
        case .inactive: return "Not set up"
        case .active: return "On"
        case .waitingForFullUnlock: return "Waiting"
        case .readyForRelease, .releaseInProgress: return "Ending"
        case .pendingSetup: return "Setup incomplete"
        case nil: return "Checking"
        }
    }

    private var statusText: String {
        switch model.snapshot?.phase {
        case .inactive:
            return "Let Hard Pause keep a private code for Apple’s Screen Time settings."
        case .pendingSetup:
            return "The private code is saved. Finish setup so Hard Pause can verify it."
        case .active:
            if model.snapshot?.fullUnlockDelay == 0 {
                return canRemoveCode
                    ? "The code is ready for your next plan. No current plan needs it."
                    : "The code stays on until the last plan that uses Screen Time ends."
            }
            return
                "To remove the code, end all plans and wait \(duration(model.snapshot?.fullUnlockDelay)) after your request."
        case .waitingForFullUnlock:
            return "The code can be removed in \(duration(model.snapshot?.remainingDelay)), once all plans have ended."
        case .readyForRelease, .releaseInProgress:
            return "The wait is complete. Hard Pause can finish removing its code once all plans have ended."
        case nil:
            return "Connecting to saved Screen Time protection."
        }
    }

    private func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "the saved waiting period" }
        return Duration.seconds(max(0, seconds)).formatted(.units(allowed: [.days, .hours, .minutes], width: .wide))
    }

    private func websiteGroup(_ title: String, entries: [String]) -> some View {
        DisclosureGroup("\(title) (\(entries.count))") {
            ForEach(entries, id: \.self) { Text($0).textSelection(.enabled) }
        }
    }
}

struct ScreenTimeWebsiteOverwriteView: View {
    @ObservedObject var model: AppleProtectionModel
    let overwrite: AppleWebsiteOverwrite

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Replace Apple website entries?")
                .font(PauseFont.display(24, relativeTo: .title))
            Text(
                "These entries are in Screen Time but not in your current plans. Sync will remove them from Apple’s lists."
            )
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    entries("Restricted entries to remove", overwrite.restricted)
                    entries("Allowed entries to remove", overwrite.allowed)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Keep Apple entries") { model.cancelWebsiteOverwrite() }
                    .buttonStyle(PauseButtonStyle())
                Spacer()
                Button("Replace and sync") {
                    Task { await model.syncWebsites(approving: overwrite, presentingResult: true) }
                }
                .buttonStyle(PauseButtonStyle(primary: true))
            }.disabled(model.isBusy)
        }
        .padding(24).frame(width: 520, height: 360)
        .background(PauseTheme.background)
        .interactiveDismissDisabled(model.isBusy)
    }

    private func entries(_ title: String, _ values: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(title) (\(values.count))").font(.headline)
            ForEach(values, id: \.self) { Text($0).textSelection(.enabled) }
        }
    }
}

struct AppleProtectionSetupView: View {
    @ObservedObject var model: AppleProtectionModel
    @Environment(\.dismiss) private var dismiss
    @State private var hasInspected = false
    @State private var showsRetry = false
    @State private var enableAdultFilter = true
    @State private var currentCode = ""
    @State private var hasAccessibilityAccess = AXIsProcessTrusted()

    var body: some View {
        Group {
            if hasAccessibilityAccess {
                setupSteps
            } else {
                accessibilityStep
            }
        }
        .padding(24).frame(width: 540)
        .background(PauseTheme.background)
        .interactiveDismissDisabled(model.isBusy)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasAccessibilityAccess = AXIsProcessTrusted()
        }
        .onDisappear { currentCode = "" }
    }

    private var accessibilityStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Allow access to System Settings")
                .font(PauseFont.display(24, relativeTo: .title))
            Text("Hard Pause needs Accessibility access to enter the private code and manage Screen Time for you.")
            Text("Turn on Hard Pause in Accessibility settings, then return here. Setup will continue automatically.")
                .foregroundStyle(PauseTheme.muted)
            HStack {
                Button("Close") { dismiss() }.buttonStyle(PauseButtonStyle())
                Spacer()
                Button("Open Accessibility Settings") {
                    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                    hasAccessibilityAccess = AXIsProcessTrustedWithOptions(options)
                    if !hasAccessibilityAccess,
                        let url = URL(
                            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
                    {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(PauseButtonStyle(primary: true))
            }.disabled(model.isBusy)
        }
    }

    private var setupSteps: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(isPending ? "Finish Screen Time setup" : "Set a private Screen Time code")
                .font(PauseFont.display(24, relativeTo: .title))
            if isPending {
                Text(
                    "Hard Pause saved the private code before setup stopped. Check whether macOS accepted it before you try again."
                )
            } else if !hasInspected {
                Text(
                    "Hard Pause will open System Settings, check for an existing code, then ask you to continue. It saves a random code before entering it for you."
                )
                Text(
                    "Leave the keyboard and mouse alone while setup runs. Hard Pause does not display the code, but macOS may show digits during entry. Look away during that step if you do not want to see them."
                )
                .foregroundStyle(PauseTheme.muted)
                Text(
                    "The code stays until the last plan that uses Screen Time ends. You can remove an unused setup at any time."
                )
                .font(.callout)
                Text(
                    "Setup uses your own Screen Time settings on this Mac. Protection on other devices is not verified. Apple account recovery can still reset the code."
                )
                .foregroundStyle(PauseTheme.muted)
            } else {
                Toggle("Use Apple’s adult website filter and sync websites", isOn: $enableAdultFilter)
                if enableAdultFilter {
                    Text(
                        "Content & Privacy must already be on in Screen Time. Review Apple’s settings before you enable it. Apple’s filter and synced limits stay on during breaks."
                    )
                    .foregroundStyle(PauseTheme.muted)
                }
                if model.codeCheck == true {
                    Text("Screen Time already has a code. Enter it once so Hard Pause can replace it.")
                    SecureField("Current Screen Time code", text: $currentCode)
                        .textFieldStyle(.roundedBorder)
                }
                Text(
                    "When you continue, look away if you want to avoid seeing any digits in System Settings. Hard Pause will return here when it finishes."
                )
                .font(.callout).foregroundStyle(PauseTheme.muted)
            }
            if isPending && showsRetry {
                Text(
                    "If your original code is still set, enter it below. Leave this empty if Screen Time has no code. Hard Pause will reuse its saved private code."
                )
                .font(.callout).foregroundStyle(PauseTheme.muted)
                SecureField("Original Screen Time code", text: $currentCode)
                    .textFieldStyle(.roundedBorder)
            }
            if let activity = model.activity {
                ProgressView(activity.label).controlSize(.small)
            } else if model.hasError, let message = model.message {
                Text(message).font(.callout).foregroundStyle(.orange)
            }
            HStack {
                Button("Close") { dismiss() }.buttonStyle(PauseButtonStyle())
                Spacer()
                if isPending {
                    if showsRetry {
                        Button("Retry setup") { runSetup(retry: true) }
                            .buttonStyle(PauseButtonStyle())
                            .disabled(!currentCode.isEmpty && !AppleScreenTimeAutomation.validCode(currentCode))
                    }
                    Button("Verify setup") {
                        Task {
                            await model.verifySetup()
                            if model.snapshot?.phase == .active { dismiss() } else { showsRetry = true }
                        }
                    }
                    .buttonStyle(PauseButtonStyle(primary: true))
                } else if !hasInspected {
                    Button("Continue") {
                        Task {
                            await model.inspectSettings()
                            hasInspected = model.codeCheck != nil && !model.hasError
                        }
                    }
                    .buttonStyle(PauseButtonStyle(primary: true))
                } else {
                    Button("Set private code") { runSetup(retry: false) }
                        .buttonStyle(PauseButtonStyle(primary: true))
                        .disabled(model.codeCheck == true && !AppleScreenTimeAutomation.validCode(currentCode))
                }
            }.disabled(model.isBusy)
        }
    }

    private var isPending: Bool { model.snapshot?.phase == .pendingSetup }

    private func runSetup(retry: Bool) {
        let oldCode = currentCode
        currentCode = ""
        Task {
            if retry {
                await model.retrySetup(existingPasscode: oldCode.isEmpty ? nil : oldCode)
            } else {
                await model.setUp(
                    enablesAdultFilter: enableAdultFilter, existingPasscode: oldCode.isEmpty ? nil : oldCode)
            }
            if model.snapshot?.phase == .active { dismiss() }
        }
    }
}
