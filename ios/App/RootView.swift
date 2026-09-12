import FamilyControls
import SwiftUI

struct RootView: View {
    private enum AppTab: Hashable {
        case home
        case blocks
        case settings
    }

    @ObservedObject var controller: LockController
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: AppTab = .home
    @State private var showsPicker = false
    @State private var confirmsActivation = false
    @State private var confirmsFullUnlock = false
    @State private var confirmsDelete = false

    var body: some View {
        ZStack {
            PauseTheme.background.ignoresSafeArea()
            if controller.isReady {
                TabView(selection: $selectedTab) {
                    Tab("Home", systemImage: "house.fill", value: AppTab.home) {
                        HomeView(controller: controller) {
                            selectedTab = .blocks
                        }
                    }

                    Tab("Blocks", systemImage: "square.stack.3d.up.fill", value: AppTab.blocks) {
                        BlocksView(
                            controller: controller,
                            showsPicker: $showsPicker,
                            confirmsActivation: $confirmsActivation,
                            confirmsFullUnlock: $confirmsFullUnlock,
                            confirmsDelete: $confirmsDelete
                        )
                    }

                    Tab("Settings", systemImage: "gearshape.fill", value: AppTab.settings) {
                        SettingsView(controller: controller)
                    }
                }
            } else {
                ProgressView()
                    .tint(PauseTheme.coral)
            }
        }
        .tint(PauseTheme.coral)
        .foregroundStyle(PauseTheme.ink)
        .preferredColorScheme(.dark)
        .font(PauseFont.body())
        .sheet(isPresented: $showsPicker) {
            NavigationStack {
                FamilyActivityPicker(
                    headerText: "Choose what this pause blocks",
                    footerText: "Your choices stay on this device.",
                    selection: $controller.draftPolicy.selection
                )
                .navigationTitle("Apps & websites")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showsPicker = false }
                    }
                }
            }
        }
        .alert("Enable \(controller.draftName)?", isPresented: $confirmsActivation) {
            Button("Cancel", role: .cancel) {}
            Button("Enable") { controller.activate() }
        } message: {
            Text(activationMessage)
        }
        .alert("Request full unlock?", isPresented: $confirmsFullUnlock) {
            Button("Cancel", role: .cancel) {}
            Button("Start delay") { controller.requestFullUnlock() }
        } message: {
            Text(fullUnlockMessage)
        }
        .alert("Delete \(controller.draftName)?", isPresented: $confirmsDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { controller.deleteSelectedBlock() }
        } message: {
            Text("This removes the saved inactive pause and its settings.")
        }
        .alert("Hard Pause", isPresented: errorBinding) {
            Button("OK") { controller.errorMessage = nil }
        } message: {
            Text(controller.errorMessage ?? "")
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            controller.start()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    return
                }
                controller.refresh()
            }
        }
    }

    private var activationMessage: String {
        let fullUnlockDelay =
            controller.draftPolicy.fullUnlockDelay
            ?? controller.draftPolicy.waitDuration
        let automaticEnd =
            controller.draftPolicy.fixedDuration.map {
                " This pause ends automatically after \($0.hardPauseDurationLabel), even if another request is pending."
            } ?? " It stays active until a delayed full unlock."
        return
            "A timeout waits \(controller.draftPolicy.waitDuration.hardPauseDurationLabel). A full unlock waits \(fullUnlockDelay.hardPauseDurationLabel). A timeout lasts \(controller.draftPolicy.breakDuration.hardPauseDurationLabel). Rules stay fixed while this pause is active. Time while this device is off does not count.\(automaticEnd)"
    }

    private var fullUnlockMessage: String {
        let delay =
            controller.state.policy.fullUnlockDelay
            ?? controller.state.policy.waitDuration
        return controller.state.phase == .breakActive
            ? "This closes the current timeout. Blocking returns for \(delay.hardPauseDurationLabel), then this pause ends."
            : "Blocking continues for \(delay.hardPauseDurationLabel), then this pause ends."
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { controller.errorMessage != nil },
            set: { if !$0 { controller.errorMessage = nil } }
        )
    }
}

private struct HomeView: View {
    @ObservedObject var controller: LockController
    let managePauses: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                PauseTheme.background.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 22) {
                        if let message = controller.persistentErrorMessage {
                            ErrorCard(message: message)
                        }
                        if controller.authorizationStatus != .approved {
                            AuthorizationView(controller: controller)
                        } else if controller.collection.activeBlocks.isEmpty {
                            welcome
                        } else {
                            activeOverview
                        }
                    }
                    .frame(maxWidth: 620)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("Hard Pause")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    BrandMark()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ScreenTimeStatus(controller: controller)
                }
            }
        }
    }

    private var welcome: some View {
        VStack(spacing: 20) {
            PauseSeed(mood: .calm, size: 270)
                .padding(.top, 4)
            VStack(spacing: 8) {
                Text("Ready when you are.")
                    .font(PauseFont.display(34))
                    .multilineTextAlignment(.center)
                Text("Create named pauses for work, rest, or any set of apps and websites.")
                    .foregroundStyle(PauseTheme.muted)
                    .multilineTextAlignment(.center)
            }
            Button("Set up a pause", action: managePauses)
                .buttonStyle(.glassProminent)
                .tint(PauseTheme.coral)
                .controlSize(.large)
        }
    }

    private var activeOverview: some View {
        VStack(alignment: .leading, spacing: 16) {
            PauseSeed(mood: .calm, size: 180)
                .frame(maxWidth: .infinity)
            Text("Active pauses")
                .font(PauseFont.display(30))
            Text("\(controller.activeBlockCount) of \(LockCollection.maximumActiveBlocks) active")
                .foregroundStyle(PauseTheme.muted)
            ForEach(controller.collection.activeBlocks) { block in
                Button {
                    controller.selectBlock(block.id)
                    managePauses()
                } label: {
                    PauseCard {
                        HStack(spacing: 14) {
                            Image(systemName: block.state.phase.systemImage)
                                .font(.title2)
                                .foregroundStyle(PauseTheme.coral)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(block.name).font(.headline)
                                Text(block.state.phase.displayName)
                                    .font(.subheadline)
                                    .foregroundStyle(PauseTheme.muted)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(PauseTheme.muted)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            Button("Manage pauses", action: managePauses)
                .buttonStyle(.glass)
                .controlSize(.large)
        }
    }
}

private struct BlocksView: View {
    @ObservedObject var controller: LockController
    @Binding var showsPicker: Bool
    @Binding var confirmsActivation: Bool
    @Binding var confirmsFullUnlock: Bool
    @Binding var confirmsDelete: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                PauseTheme.background.ignoresSafeArea()
                ScrollViewReader { scrollProxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Your blocks")
                                    .font(PauseFont.display(31))
                                Text("Select one to view or edit it.")
                                    .foregroundStyle(PauseTheme.muted)
                            }

                            if controller.blocks.isEmpty {
                                PauseCard {
                                    Text("No saved pauses. Create one when you are ready.")
                                        .foregroundStyle(PauseTheme.muted)
                                }
                            } else {
                                VStack(spacing: 10) {
                                    ForEach(controller.blocks) { block in
                                        BlockListRow(
                                            block: block,
                                            isSelected: controller.selectedBlockID == block.id
                                        ) {
                                            controller.selectBlock(block.id)
                                        }
                                    }
                                }
                            }

                            if let block = controller.selectedBlock {
                                Divider()
                                    .overlay(PauseTheme.stroke)
                                    .padding(.vertical, 4)
                                    .id("selected-pause-detail")
                                if block.state.isActive {
                                    ActiveLockView(
                                        controller: controller,
                                        confirmsFullUnlock: $confirmsFullUnlock
                                    )
                                } else {
                                    SetupView(
                                        controller: controller,
                                        showsPicker: $showsPicker,
                                        confirmsActivation: $confirmsActivation,
                                        confirmsDelete: $confirmsDelete
                                    )
                                }
                            }
                        }
                        .frame(maxWidth: 620)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 36)
                    }
                    .onChange(of: controller.selectedBlockID) {
                        scrollToSelectedPause(using: scrollProxy)
                    }
                    .onChange(of: controller.state.phase) {
                        scrollToSelectedPause(using: scrollProxy)
                    }
                }
            }
            .navigationTitle("Blocks")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: controller.createBlock) {
                        Label("New block", systemImage: "plus")
                    }
                }
            }
        }
    }

    private func scrollToSelectedPause(using proxy: ScrollViewProxy) {
        withAnimation(.easeInOut(duration: 0.25)) {
            proxy.scrollTo("selected-pause-detail", anchor: .top)
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var controller: LockController

    var body: some View {
        NavigationStack {
            ZStack {
                PauseTheme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        PauseCard {
                            VStack(alignment: .leading, spacing: 14) {
                                SectionTitle(icon: "hourglass", title: "Capacity")
                                StatusRow(
                                    label: "Active pauses",
                                    value: "\(controller.activeBlockCount) of \(LockCollection.maximumActiveBlocks)"
                                )
                                Text(
                                    "iOS limits Screen Time schedules. Hard Pause stops a new request if no schedule slot is available, so an existing rule is not relaxed."
                                )
                                .font(.footnote)
                                .foregroundStyle(PauseTheme.muted)
                            }
                        }
                        PauseCard {
                            VStack(alignment: .leading, spacing: 14) {
                                SectionTitle(icon: "hand.raised.fill", title: "Screen Time access")
                                Text(controller.authorizationStatus == .approved ? "Approved" : "Access needed")
                                    .font(.headline)
                                Text(
                                    "iOS owns this permission. Hard Pause cannot prevent permission changes in Settings."
                                )
                                .font(.subheadline)
                                .foregroundStyle(PauseTheme.muted)
                                if controller.authorizationStatus != .approved {
                                    Button {
                                        Task { await controller.requestAuthorization() }
                                    } label: {
                                        Text("Allow Screen Time access")
                                    }
                                    .buttonStyle(.glassProminent)
                                    .tint(PauseTheme.coral)
                                    .controlSize(.large)
                                }
                            }
                        }
                        PauseCard {
                            VStack(alignment: .leading, spacing: 10) {
                                SectionTitle(icon: "internaldrive.fill", title: "Privacy")
                                Text(
                                    "Pause names, rules, and state stay on this device. The app has no account, analytics, or server."
                                )
                                .foregroundStyle(PauseTheme.muted)
                            }
                        }
                    }
                    .frame(maxWidth: 620)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 36)
                }
            }
            .navigationTitle("Settings")
        }
    }
}

private struct BrandMark: View {
    var body: some View {
        HStack(spacing: 7) {
            PauseSeed(mood: .calm, size: 32)
                .accessibilityHidden(true)
            Text("hard pause")
                .font(PauseFont.display(18, relativeTo: .headline))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hard Pause")
    }
}

private struct ScreenTimeStatus: View {
    @ObservedObject var controller: LockController

    var body: some View {
        Image(
            systemName: controller.authorizationStatus == .approved
                ? "checkmark.circle.fill"
                : "exclamationmark.circle.fill"
        )
        .foregroundStyle(controller.authorizationStatus == .approved ? PauseTheme.muted : PauseTheme.coral)
        .accessibilityLabel(
            controller.authorizationStatus == .approved ? "Screen Time on" : "Screen Time access needed"
        )
    }
}

private struct BlockListRow: View {
    let block: LockBlock
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 13) {
                Image(systemName: block.state.phase.systemImage)
                    .foregroundStyle(block.state.isActive ? PauseTheme.coral : PauseTheme.muted)
                    .frame(width: 25)
                VStack(alignment: .leading, spacing: 3) {
                    Text(block.name).font(.headline)
                    Text(block.state.phase.displayName)
                        .font(.caption)
                        .foregroundStyle(PauseTheme.muted)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(PauseTheme.coral)
                }
            }
            .padding(15)
            .background(isSelected ? PauseTheme.surface : PauseTheme.surface.opacity(0.55))
            .overlay {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .stroke(isSelected ? PauseTheme.coral.opacity(0.7) : PauseTheme.stroke, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct ErrorCard: View {
    let message: String

    var body: some View {
        PauseCard {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline)
        }
    }
}

extension LockPhase {
    fileprivate var displayName: String {
        switch self {
        case .inactive: "Inactive"
        case .locked: "Blocking"
        case .waitingForBreak: "Timeout requested"
        case .breakActive: "Timeout open"
        case .waitingForEnd: "Full unlock requested"
        }
    }

    fileprivate var systemImage: String {
        switch self {
        case .inactive: "pause.circle"
        case .locked: "lock.fill"
        case .waitingForBreak, .waitingForEnd: "hourglass"
        case .breakActive: "cup.and.saucer.fill"
        }
    }
}

private struct AuthorizationView: View {
    @ObservedObject var controller: LockController

    var body: some View {
        VStack(spacing: 22) {
            PauseSeed(mood: .calm, size: 280)
                .padding(.top, 12)
            VStack(spacing: 10) {
                Text("Your apps can wait.")
                    .font(PauseFont.display(34))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(PauseTheme.ink)
                Text(
                    "Block chosen apps and websites with Apple’s Screen Time controls. Your settings never leave this device."
                )
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(PauseTheme.muted)
            }
            PauseCard {
                VStack(alignment: .leading, spacing: 14) {
                    FeatureRow(icon: "hourglass", text: "A fixed delay before a timeout or full unlock")
                    FeatureRow(icon: "hand.raised.fill", text: "Friendly system shields on blocked apps and sites")
                    FeatureRow(icon: "internaldrive.fill", text: "Local storage only; no account, analytics, or server")
                }
            }
            Button {
                Task { await controller.requestAuthorization() }
            } label: {
                HStack {
                    if controller.isRequestingAuthorization { ProgressView() }
                    Text(controller.isRequestingAuthorization ? "Waiting for iOS…" : "Allow Screen Time access")
                }
            }
            .buttonStyle(.glassProminent)
            .tint(PauseTheme.coral)
            .controlSize(.large)
            .disabled(controller.isRequestingAuthorization)
            if controller.authorizationStatus == .denied {
                Text("Access was denied or revoked. You can change Family Controls permission in iOS Settings.")
                    .font(.footnote)
                    .foregroundStyle(PauseTheme.muted)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

private struct SetupView: View {
    @ObservedObject var controller: LockController
    @Binding var showsPicker: Bool
    @Binding var confirmsActivation: Bool
    @Binding var confirmsDelete: Bool
    @State private var domainInput = ""
    @State private var caretPosition: CGPoint?
    @State private var mascotFrame: CGRect = .zero
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private let waitOptions: [TimeInterval] = [3_600, 14_400, 86_400, 259_200]
    private let breakOptions: [TimeInterval] = [900, 1_800, 3_600, 7_200]
    private let fixedDurationOptions: [TimeInterval?] = [nil, 86_400, 259_200, 604_800]

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Edit this pause")
                        .font(PauseFont.display(31))
                        .foregroundStyle(PauseTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("These settings become fixed when you enable the lock.")
                        .foregroundStyle(PauseTheme.muted)
                }
                Spacer(minLength: 0)
                if !dynamicTypeSize.isAccessibilitySize {
                    PauseSeed(
                        mood: .calm, size: 100,
                        attention: mascotAttention(caret: caretPosition, frame: mascotFrame)
                    )
                    .background(
                        GeometryReader { geometry in
                            Color.clear.preference(key: MascotFrameKey.self, value: geometry.frame(in: .global))
                        })
                }
            }

            PauseCard {
                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(icon: "character.cursor.ibeam", title: "Name")
                    CaretTrackingTextField(
                        "Pause name",
                        text: $controller.draftName,
                        accessibilityLabel: "Pause name",
                        inputMode: .name,
                        onSubmit: {},
                        onCaretChange: { caretPosition = $0 }
                    )
                    .padding(12)
                    .background(PauseTheme.background)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    Text("You can change the name only while this pause is inactive.")
                        .font(.caption)
                        .foregroundStyle(PauseTheme.muted)
                }
            }

            PauseCard {
                VStack(alignment: .leading, spacing: 16) {
                    SectionTitle(icon: "app.badge.checkmark", title: "Apps & websites")
                    Button {
                        showsPicker = true
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Choose with Screen Time")
                                    .font(.headline)
                                Text(selectionSummary)
                                    .font(.subheadline)
                                    .foregroundStyle(PauseTheme.muted)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                        }
                    }
                    .foregroundStyle(PauseTheme.ink)
                }
            }

            PauseCard {
                VStack(alignment: .leading, spacing: 16) {
                    SectionTitle(icon: "safari.fill", title: "Web protection")
                    Toggle(isOn: $controller.draftPolicy.blocksAdultWebsites) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Automatic adult website filter")
                            Text("Uses Apple’s web filter. Coverage and classification are controlled by iOS.")
                                .font(.caption)
                                .foregroundStyle(PauseTheme.muted)
                        }
                    }
                    HStack {
                        CaretTrackingTextField(
                            "example.com", text: $domainInput, onSubmit: addDomain,
                            onCaretChange: { caretPosition = $0 }
                        )
                        .padding(12)
                        .background(PauseTheme.background)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        Button("Add") { addDomain() }
                            .fontWeight(.semibold)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    ForEach(controller.draftPolicy.manualDomains, id: \.self) { domain in
                        HStack {
                            Image(systemName: "globe")
                            Text(domain)
                            Spacer()
                            Button {
                                controller.removeManualDomain(domain)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .accessibilityLabel("Remove \(domain)")
                            .frame(minWidth: 44, minHeight: 44)
                        }
                        .font(.subheadline)
                        .foregroundStyle(PauseTheme.ink)
                    }
                }
            }

            PauseCard {
                VStack(alignment: .leading, spacing: 16) {
                    SectionTitle(icon: "timer", title: "Timeout rules")
                    LabeledPicker(
                        title: "Timeout delay",
                        detail: "Wait before a timeout opens",
                        selection: $controller.draftPolicy.waitDuration,
                        options: waitOptions
                    )
                    Divider().overlay(PauseTheme.stroke)
                    LabeledPicker(
                        title: "Full-unlock delay",
                        detail: "Wait before this pause ends on request",
                        selection: fullUnlockDelayBinding,
                        options: waitOptions
                    )
                    Divider().overlay(PauseTheme.stroke)
                    LabeledPicker(
                        title: "Timeout length",
                        detail: "Blocking returns automatically",
                        selection: $controller.draftPolicy.breakDuration,
                        options: breakOptions
                    )
                    Divider().overlay(PauseTheme.stroke)
                    OptionalDurationPicker(
                        title: "Automatic end",
                        detail: "Optional fixed elapsed duration",
                        selection: $controller.draftPolicy.fixedDuration,
                        options: fixedDurationOptions
                    )
                    Text(
                        "A fixed duration ends this pause at its elapsed-time deadline, even during a pending timeout or full-unlock request."
                    )
                    .font(.caption)
                    .foregroundStyle(PauseTheme.muted)
                    Text("Time while this device is off does not count toward these delays.")
                        .font(.caption)
                        .foregroundStyle(PauseTheme.muted)
                }
            }

            PauseCard {
                VStack(alignment: .leading, spacing: 16) {
                    SectionTitle(icon: "shield.lefthalf.filled", title: "Device protection")
                    Toggle(isOn: $controller.draftPolicy.preventsAppRemoval) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Prevent app removal")
                            Text(
                                "Device-wide: iOS prevents deletion of every app until the lock fully ends, including during a timeout."
                            )
                            .font(.caption)
                            .foregroundStyle(PauseTheme.muted)
                        }
                    }
                    Toggle(isOn: $controller.draftPolicy.requiresAutomaticDateAndTime) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Require automatic date & time")
                            Text(
                                "Device-wide while active. This reduces clock changes that could affect a local delay."
                            )
                            .font(.caption)
                            .foregroundStyle(PauseTheme.muted)
                        }
                    }
                }
            }

            Button("Enable \(controller.draftName)") { confirmsActivation = true }
                .buttonStyle(.glassProminent)
                .tint(PauseTheme.coral)
                .controlSize(.large)
                .disabled(!controller.canActivate)
                .opacity(controller.canActivate ? 1 : 0.45)

            if let message = validationMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(PauseTheme.muted)
                    .multilineTextAlignment(.center)
            }

            Text(
                "iOS still owns Screen Time permission. If permission can be revoked in Settings, Hard Pause cannot stop that. A Screen Time passcode may protect changes on some iOS versions; verify this on your device."
            )
            .font(.footnote)
            .foregroundStyle(PauseTheme.muted)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 8)

            Button("Delete this pause", role: .destructive) { confirmsDelete = true }
                .frame(minHeight: 44)
        }
        .onPreferenceChange(MascotFrameKey.self) { mascotFrame = $0 }
    }

    private var selectionSummary: String {
        let count = controller.draftPolicy.selectedItemCount - controller.draftPolicy.manualDomains.count
        return count == 0 ? "Nothing selected yet" : "\(count) selection\(count == 1 ? "" : "s")"
    }

    private func addDomain() {
        if controller.addManualDomain(domainInput) { domainInput = "" }
    }

    private var validationMessage: String? {
        guard !LockBlock.normalizedName(controller.draftName).isEmpty else {
            return "Enter a name for this pause."
        }
        guard controller.activeBlockCount < LockCollection.maximumActiveBlocks else {
            return "No more than 16 pauses can be active at the same time."
        }
        guard controller.draftPolicy.hasBlockingTarget else {
            return "Choose an app or website, or turn on the adult website filter."
        }
        do {
            try controller.draftPolicy.validateManagedSettingsLimits()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private var fullUnlockDelayBinding: Binding<TimeInterval> {
        Binding(
            get: {
                controller.draftPolicy.fullUnlockDelay
                    ?? controller.draftPolicy.waitDuration
            },
            set: { controller.draftPolicy.fullUnlockDelay = $0 }
        )
    }
}

private struct ActiveLockView: View {
    @ObservedObject var controller: LockController
    @Binding var confirmsFullUnlock: Bool

    var body: some View {
        VStack(spacing: 18) {
            PauseSeed(mood: mood, size: 280)
                .padding(.top, 4)
            VStack(spacing: 7) {
                Text(controller.selectedBlock?.name ?? "Pause")
                    .font(.headline)
                    .foregroundStyle(PauseTheme.coral)
                Text(title)
                    .font(PauseFont.display(30))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(PauseTheme.ink)
                Text(detail)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(PauseTheme.muted)
            }

            if controller.state.nextTransitionAt != nil {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    VStack(spacing: 10) {
                        Text(controller.state.countdownLabel())
                            .font(PauseFont.mono(46))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .foregroundStyle(PauseTheme.ink)
                            .multilineTextAlignment(.center)
                        Text(countdownLabel)
                            .font(PauseFont.body(14, relativeTo: .subheadline))
                            .foregroundStyle(PauseTheme.muted)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
            }

            if controller.state.automaticEndAt != nil {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    VStack(spacing: 8) {
                        Text(controller.state.automaticEndCountdownLabel())
                            .font(PauseFont.mono(32))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Text("Automatic end")
                            .font(.subheadline)
                            .foregroundStyle(PauseTheme.muted)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
            }

            if controller.authorizationStatus != .approved {
                PauseCard {
                    Label {
                        Text(
                            "Screen Time access is no longer approved. iOS may stop enforcing this lock. Open Settings to restore access."
                        )
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(PauseTheme.coral)
                    }
                    .font(.subheadline)
                    .foregroundStyle(PauseTheme.ink)
                }
            }

            if let notice = controller.state.recoveryNotice {
                PauseCard {
                    Label(notice, systemImage: "arrow.clockwise.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(PauseTheme.ink)
                }
            }

            PauseCard {
                VStack(alignment: .leading, spacing: 12) {
                    StatusRow(label: "Chosen apps & sites", value: "\(controller.state.policy.selectedItemCount)")
                    StatusRow(
                        label: "Adult website filter", value: controller.state.policy.blocksAdultWebsites ? "On" : "Off"
                    )
                    StatusRow(
                        label: "Timeout delay", value: controller.state.policy.waitDuration.hardPauseDurationLabel)
                    StatusRow(
                        label: "Full-unlock delay",
                        value: (controller.state.policy.fullUnlockDelay
                            ?? controller.state.policy.waitDuration).hardPauseDurationLabel
                    )
                    StatusRow(label: "Timeout", value: controller.state.policy.breakDuration.hardPauseDurationLabel)
                    StatusRow(
                        label: "Automatic end",
                        value: controller.state.policy.fixedDuration?.hardPauseDurationLabel ?? "After full unlock"
                    )
                    StatusRow(
                        label: "App deletion",
                        value: controller.state.policy.preventsAppRemoval ? "Prevented device-wide" : "Allowed")
                    Text("The name and rules cannot be edited while this pause is active.")
                        .font(.footnote)
                        .foregroundStyle(PauseTheme.muted)
                        .padding(.top, 2)
                }
            }

            if controller.state.phase == .locked {
                Button("Request a timeout") { controller.requestBreak() }
                    .buttonStyle(.glassProminent)
                    .tint(PauseTheme.coral)
                    .controlSize(.large)
            }
            if controller.state.phase == .locked || controller.state.phase == .breakActive {
                Button("Request full unlock") { confirmsFullUnlock = true }
                    .buttonStyle(.glass)
                    .controlSize(.large)
            }
        }
    }

    private var mood: PauseSeedMood {
        return switch controller.state.phase {
        case .breakActive: .resting
        case .waitingForBreak, .waitingForEnd: .waiting
        case .inactive, .locked: .calm
        }
    }

    private var title: String {
        if controller.authorizationStatus != .approved {
            return "Screen Time access needs attention"
        }
        return switch controller.state.phase {
        case .locked: "Your pause is active"
        case .waitingForBreak: "A little more time"
        case .breakActive: "Your break is open"
        case .waitingForEnd: "Full unlock requested"
        case .inactive: "Ready"
        }
    }

    private var detail: String {
        if controller.authorizationStatus != .approved {
            return "iOS may no longer enforce this lock. Restore access in Settings."
        }
        return switch controller.state.phase {
        case .locked: "Chosen apps and websites stay blocked."
        case .waitingForBreak: "Blocking continues until your timeout starts."
        case .breakActive: "Access is open for now. Blocking returns automatically."
        case .waitingForEnd: "Blocking continues until the lock fully ends."
        case .inactive: ""
        }
    }

    private var countdownLabel: String {
        switch controller.state.phase {
        case .waitingForBreak: "Timeout starts in"
        case .breakActive: "Blocking returns in"
        case .waitingForEnd: "Lock ends in"
        case .inactive, .locked: ""
        }
    }
}

private struct FeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        Label(text, systemImage: icon)
            .font(.subheadline)
            .foregroundStyle(PauseTheme.ink)
    }
}

private struct SectionTitle: View {
    let icon: String
    let title: String

    var body: some View {
        Label(title, systemImage: icon)
            .font(PauseFont.display(20, relativeTo: .title3))
            .foregroundStyle(PauseTheme.ink)
    }
}

private struct LabeledPicker: View {
    let title: String
    let detail: String
    @Binding var selection: TimeInterval
    let options: [TimeInterval]
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout =
            dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout())
        return layout {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(PauseTheme.muted)
            }
            Spacer()
            Picker(title, selection: $selection) {
                ForEach(options, id: \.self) { option in
                    Text(option.hardPauseDurationLabel).tag(option)
                }
            }
            .labelsHidden()
        }
    }
}

private struct OptionalDurationPicker: View {
    let title: String
    let detail: String
    @Binding var selection: TimeInterval?
    let options: [TimeInterval?]
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout =
            dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout())
        return layout {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(PauseTheme.muted)
            }
            Spacer()
            Picker(title, selection: $selection) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    Text(option?.hardPauseDurationLabel ?? "Until full unlock")
                        .tag(option)
                }
            }
            .labelsHidden()
        }
    }
}

private struct StatusRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(PauseTheme.muted)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(PauseTheme.ink)
        }
        .font(.subheadline)
    }
}
