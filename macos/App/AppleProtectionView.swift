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
                Button("Set up Screen Time code") { showsSetup = true }
            case .pendingSetup:
                HStack {
                    Button("Verify setup") { Task { await model.verifySetup() } }
                    Button("Continue setup") { showsSetup = true }
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
            return "Hard Pause keeps a private Screen Time code. Set it up once before starting a Hard Pause plan."
        case .pendingSetup:
            return "Setup is incomplete. The saved code is retained until setup is verified."
        case .active:
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

    private func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "the saved waiting period" }
        return Duration.seconds(max(0, seconds)).formatted(.units(allowed: [.days, .hours, .minutes], width: .wide))
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
            Text("This setup uses System Settings on this Mac. Keep it open and use English during setup.")
                .foregroundStyle(PauseTheme.muted)
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
