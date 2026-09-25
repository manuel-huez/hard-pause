import AppKit
import SwiftUI

struct AppleProtectionCard: View {
    @ObservedObject var model: AppleProtectionModel
    var proposedDelay: TimeInterval = 86_400
    @State private var showsSetup = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Screen Time protection", systemImage: "lock.shield")
                .font(PauseFont.display(18, relativeTo: .headline))
            Text(statusText)
                .foregroundStyle(PauseTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            if model.isBusy { ProgressView().controlSize(.small) }
            switch model.snapshot?.phase {
            case .inactive:
                Button("Set up Screen Time code") { openSetup() }
            case .pendingSetup:
                HStack {
                    Button("Verify setup") { Task { await model.verifySetup() } }
                    Button("Continue setup") { openSetup() }
                }
            case .active:
                Button("Request to end Screen Time protection") { Task { await model.requestEnd() } }
            case .waitingForFullUnlock:
                Text("Protection stays on during the wait.").font(.caption)
            case .readyForRelease, .releaseInProgress:
                Button("Finish ending Screen Time protection") { Task { await model.finishEnd() } }
            case nil:
                Button("Check protection") { Task { await model.refresh() } }
            }
            if model.snapshot != nil {
                Button("Check Screen Time code") { Task { await model.inspectSettings() } }
                    .buttonStyle(.link)
            }
            if let codeCheck = model.codeCheck {
                Text(
                    codeCheck
                        ? "Last check: a Screen Time code is enabled on this Mac. The code was not verified."
                        : "Last check: no Screen Time code was found on this Mac."
                )
                .font(.caption)
                .foregroundStyle(codeCheck ? PauseTheme.muted : .orange)
            }
            if let message = model.message {
                Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            Text(
                "iPhone protection and sharing are not verified. Apple account recovery can still reset a Screen Time code."
            )
            .font(.caption).foregroundStyle(PauseTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(model.isBusy)
        .task {
            while !Task.isCancelled {
                await model.refresh()
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
        .sheet(isPresented: $showsSetup) {
            AppleProtectionSetupView(model: model, proposedDelay: proposedDelay)
        }
    }

    private var statusText: String {
        switch model.snapshot?.phase {
        case .inactive:
            if model.codeCheck == true {
                return
                    "Screen Time already has a code. Enter the current code during setup to let Hard Pause replace it."
            }
            return "Hard Pause keeps a private Screen Time code. You can set it up before or during a Hard Pause plan."
        case .pendingSetup:
            return "Setup is incomplete. The saved code is retained until setup is verified."
        case .active:
            if model.codeCheck == false {
                return "The last check found no Screen Time code. Hard Pause's saved protection needs attention."
            }
            return
                "The code is saved and verified on this Mac. To remove it, request to end protection and wait \(duration(model.snapshot?.fullUnlockDelay)). All plans must also end."
        case .waitingForFullUnlock:
            return "Ready to remove the code in \(duration(model.snapshot?.remainingDelay)). All plans must also end."
        case .readyForRelease, .releaseInProgress:
            return "The wait has finished. End all active plans, then finish removing the Screen Time code."
        case nil:
            return "Check the saved Screen Time protection status."
        }
    }

    private func openSetup() {
        Task {
            await model.inspectSettings()
            guard model.message == nil else { return }
            NSApp.activate(ignoringOtherApps: true)
            showsSetup = true
        }
    }

    private func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "the saved waiting period" }
        return Duration.seconds(max(0, seconds)).formatted(.units(allowed: [.days, .hours, .minutes], width: .wide))
    }
}

struct ScreenTimeWebsitesCard: View {
    @ObservedObject var model: AppleProtectionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Screen Time websites", systemImage: "globe")
                .font(PauseFont.display(18, relativeTo: .headline))
            Text(
                "Sync the active plans with Apple's Restricted and Allowed website lists. Hard Pause asks before it replaces entries it did not add."
            )
            .foregroundStyle(PauseTheme.muted)
            if model.snapshot?.phase.hasConfirmedSystemPasscode == true,
                model.snapshot?.enablesAdultFilter == true
            {
                HStack {
                    Button("Read Apple lists") { Task { await model.readNativeWebsites() } }
                    Button("Sync websites") { Task { await model.syncWebsites(presentingResult: true) } }
                }
            }
            if model.isSyncingWebsites { ProgressView().controlSize(.small) }
            if let websites = model.nativeWebsites {
                websiteGroup("Restricted", entries: websites.restrictedEntries)
                websiteGroup("Allowed", entries: websites.allowedEntries)
                Text("An Allowed site overrides only its own plan. Another active plan can still block it.")
                    .font(.caption).foregroundStyle(PauseTheme.muted)
            }
            if let message = model.websiteSyncMessage {
                Text(message).font(.callout)
            }
        }
        .disabled(model.isSyncingWebsites)
        .sheet(
            item: Binding(
                get: { model.pendingWebsiteOverwrite },
                set: { if $0 == nil { model.cancelWebsiteOverwrite() } }
            )
        ) { overwrite in
            VStack(alignment: .leading, spacing: 16) {
                Text("Replace Apple website entries?")
                    .font(PauseFont.display(24, relativeTo: .title))
                Text(
                    "These entries are in Screen Time but not in the active Hard Pause plans. Sync will remove them from Apple’s lists."
                )
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        overwriteGroup("Restricted entries to remove", entries: overwrite.restricted)
                        overwriteGroup("Allowed entries to remove", entries: overwrite.allowed)
                    }
                }
                HStack {
                    Spacer()
                    Button("Cancel") { model.cancelWebsiteOverwrite() }
                    Button("Replace and sync") {
                        Task { await model.syncWebsites(approving: overwrite, presentingResult: true) }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
            .frame(minWidth: 440, minHeight: 300)
        }
    }

    private func websiteGroup(_ title: String, entries: [String]) -> some View {
        DisclosureGroup("\(title) (\(entries.count))") {
            if entries.isEmpty {
                Text("None").foregroundStyle(PauseTheme.muted)
            } else {
                ForEach(entries, id: \.self) { entry in Text(entry).textSelection(.enabled) }
            }
        }
    }

    private func overwriteGroup(_ title: String, entries: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(title) (\(entries.count))").font(.headline)
            ForEach(entries, id: \.self) { entry in Text(entry).textSelection(.enabled) }
        }
    }
}

private struct AppleProtectionSetupView: View {
    @ObservedObject var model: AppleProtectionModel
    @Environment(\.dismiss) private var dismiss
    @State private var delay: TimeInterval
    @State private var enableAdultFilter = true
    @State private var currentCode = ""

    init(model: AppleProtectionModel, proposedDelay: TimeInterval) {
        self.model = model
        _delay = State(initialValue: proposedDelay)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Keep the code out of reach")
                .font(PauseFont.display(24, relativeTo: .title))
            Text("Hard Pause saves a random code securely before it changes Screen Time. The new code is never shown.")
            Text("This setup uses System Settings on this Mac. Keep it in front until setup finishes.")
                .foregroundStyle(PauseTheme.muted)
            if model.snapshot?.phase != .pendingSetup, model.codeCheck == true {
                Text(
                    "A Screen Time code is already enabled. Enter its current code below to replace it with Hard Pause's private code."
                )
                .foregroundStyle(PauseTheme.muted)
            }
            if model.snapshot?.phase != .pendingSetup {
                Picker("Wait to remove the code", selection: $delay) {
                    ForEach(Array(Set([TimeInterval(3_600), 86_400, 604_800, delay])).sorted(), id: \.self) { value in
                        Text(Duration.seconds(value).formatted(.units(allowed: [.days, .hours], width: .wide))).tag(
                            value)
                    }
                }
                Toggle("Use Apple's adult website filter", isOn: $enableAdultFilter)
                SecureField("Current Screen Time code, if set", text: $currentCode)
                    .textFieldStyle(.roundedBorder)
                Text(
                    "Requesting to end a Hard Pause plan starts this wait too. The code stays until all plans have ended. Existing filters are kept."
                )
                .font(.caption).foregroundStyle(PauseTheme.muted)
            } else {
                Text(
                    "First choose Verify setup. If your original code is still set, enter it below to continue with the saved new code."
                )
            }
            if model.snapshot?.phase == .pendingSetup {
                SecureField("Original Screen Time code, if still set", text: $currentCode)
                    .textFieldStyle(.roundedBorder)
            }
            if let message = model.message { Text(message).font(.callout) }
            HStack {
                Button("Close") {
                    currentCode = ""
                    dismiss()
                }
                Spacer()
                if model.isBusy { ProgressView().controlSize(.small) }
                Button(model.snapshot?.phase == .pendingSetup ? "Continue setup" : "Save and set up code") {
                    let oldCode = currentCode
                    currentCode = ""
                    Task {
                        if model.snapshot?.phase == .pendingSetup {
                            await model.retrySetup(existingPasscode: oldCode)
                        } else {
                            await model.setUp(
                                fullUnlockDelay: delay, enablesAdultFilter: enableAdultFilter, existingPasscode: oldCode
                            )
                        }
                        if model.snapshot?.phase == .active { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent).tint(PauseTheme.coral)
            }
            .disabled(model.isBusy)
        }
        .padding(24).frame(width: 480)
        .background(PauseTheme.background)
        .interactiveDismissDisabled(model.isBusy)
        .onDisappear { currentCode = "" }
    }
}
