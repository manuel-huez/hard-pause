import SwiftUI
import UIKit

struct RootView: View {
    private enum AppTab: Hashable {
        case home
        case plans
        case settings
    }

    @ObservedObject var controller: LockController
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    @State private var selectedTab: AppTab = .home
    @State private var editor: PlanEditorPresentation?
    @State private var activationTargetID: UUID?
    @State private var breakTargetID: UUID?
    @State private var deletionTargetID: UUID?
    @State private var unlockGuidanceID: UUID?

    var body: some View {
        ZStack {
            PauseTheme.background.ignoresSafeArea()
            if controller.isReady {
                TabView(selection: $selectedTab) {
                    Tab("Home", systemImage: "house.fill", value: AppTab.home) {
                        HomeView(
                            controller: controller,
                            showPlans: { selectedTab = .plans },
                            showSettings: { selectedTab = .settings },
                            requestBreak: { breakTargetID = $0 },
                            cancelBreak: { controller.cancelBreakRequest(blockID: $0) },
                            showUnlockGuidance: { unlockGuidanceID = $0 }
                        )
                    }

                    Tab("Plans", systemImage: "shield.lefthalf.filled", value: AppTab.plans) {
                        PlansView(
                            controller: controller,
                            create: { editor = PlanEditorPresentation(blockID: nil) },
                            edit: { editor = PlanEditorPresentation(blockID: $0) },
                            activate: { activationTargetID = $0 },
                            delete: { deletionTargetID = $0 },
                            requestBreak: { breakTargetID = $0 },
                            cancelBreak: { controller.cancelBreakRequest(blockID: $0) },
                            showUnlockGuidance: { unlockGuidanceID = $0 }
                        )
                    }

                    Tab("Settings", systemImage: "gearshape.fill", value: AppTab.settings) {
                        SettingsView(controller: controller, openSettings: openSystemSettings)
                    }
                }
            } else {
                ProgressView("Loading your plans…")
                    .tint(PauseTheme.coral)
                    .foregroundStyle(PauseTheme.muted)
            }
        }
        .tint(PauseTheme.coral)
        .foregroundStyle(PauseTheme.ink)
        .preferredColorScheme(.dark)
        .sheet(item: $editor) { presentation in
            PlanEditorView(controller: controller, presentation: presentation)
        }
        .sheet(item: unlockGuidancePresentation) { presentation in
            UnlockGuidanceView(controller: controller, blockID: presentation.id)
        }
        .alert(activationAlertTitle, isPresented: activationAlertBinding) {
            Button("Cancel", role: .cancel) { activationTargetID = nil }
            Button("Start plan") {
                guard let id = activationTargetID else { return }
                activationTargetID = nil
                controller.activate(blockID: id)
            }
        } message: {
            Text(activationMessage)
        }
        .alert("Request a break?", isPresented: breakAlertBinding) {
            Button("Keep blocking", role: .cancel) { breakTargetID = nil }
            Button("Request a break") {
                guard let id = breakTargetID else { return }
                breakTargetID = nil
                controller.requestBreak(blockID: id)
            }
        } message: {
            Text(breakMessage)
        }
        .alert(deletionAlertTitle, isPresented: deletionAlertBinding) {
            Button("Cancel", role: .cancel) { deletionTargetID = nil }
            Button("Delete", role: .destructive) {
                guard let id = deletionTargetID else { return }
                deletionTargetID = nil
                controller.deleteBlock(id: id)
            }
        } message: {
            Text("This removes the saved inactive plan and its settings. This action cannot be undone.")
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

    private var activationTarget: LockBlock? {
        activationTargetID.flatMap(controller.collection.block)
    }

    private var activationAlertTitle: String {
        "Start \(activationTarget?.name ?? "this plan")?"
    }

    private var activationMessage: String {
        guard let block = activationTarget else { return "Rules and waits become fixed while this plan is active." }
        let policy = block.draftPolicy
        let fullUnlock = policy.fullUnlockDelay ?? policy.waitDuration
        var parts = ["Rules stay fixed while this plan is active."]
        if policy.protectionMode.allowsBreaks {
            parts.append(
                "A break requires \(policy.waitDuration.hardPauseDurationLabel). Ending the plan requires \(fullUnlock.hardPauseDurationLabel)."
            )
        } else {
            parts.append(
                "Hard Pause has no breaks or automatic end. Full unlock requires \(fullUnlock.hardPauseDurationLabel)."
            )
        }
        if policy.preventsAppRemoval {
            parts.append("iOS will prevent deletion of every app until this plan ends.")
        }
        if policy.requiresAutomaticDateAndTime {
            parts.append("iOS will require automatic date and time until this plan ends.")
        }
        if let duration = policy.fixedDuration {
            parts.append(
                "The plan ends automatically after \(duration.hardPauseDurationLabel) of recorded active time.")
        }
        return parts.joined(separator: " ")
    }

    private var breakTarget: LockBlock? {
        breakTargetID.flatMap(controller.collection.block)
    }

    private var breakMessage: String {
        guard let block = breakTarget else { return "Blocking continues during the waiting period." }
        return
            "For \(block.name), blocking continues for \(block.state.policy.waitDuration.hardPauseDurationLabel). Then access opens for \(block.state.policy.breakDuration.hardPauseDurationLabel). You can cancel the request while you wait."
    }

    private var deletionAlertTitle: String {
        let block = deletionTargetID.flatMap(controller.collection.block)
        return "Delete \(block?.name ?? "this plan")?"
    }

    private var activationAlertBinding: Binding<Bool> {
        Binding(
            get: { activationTargetID != nil },
            set: { if !$0 { activationTargetID = nil } }
        )
    }

    private var breakAlertBinding: Binding<Bool> {
        Binding(
            get: { breakTargetID != nil },
            set: { if !$0 { breakTargetID = nil } }
        )
    }

    private var deletionAlertBinding: Binding<Bool> {
        Binding(
            get: { deletionTargetID != nil },
            set: { if !$0 { deletionTargetID = nil } }
        )
    }

    private var unlockGuidancePresentation: Binding<UnlockGuidancePresentation?> {
        Binding(
            get: { unlockGuidanceID.map { UnlockGuidancePresentation(id: $0) } },
            set: { unlockGuidanceID = $0?.id }
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { controller.errorMessage != nil },
            set: { if !$0 { controller.errorMessage = nil } }
        )
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}

private struct UnlockGuidancePresentation: Identifiable {
    let id: UUID
}

private struct HomeView: View {
    @ObservedObject var controller: LockController
    let showPlans: () -> Void
    let showSettings: () -> Void
    let requestBreak: (UUID) -> Void
    let cancelBreak: (UUID) -> Void
    let showUnlockGuidance: (UUID) -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let message = controller.persistentErrorMessage {
                            WarningCard(title: "Protection needs attention", message: message)
                        }

                        if controller.authorizationStatus != .approved && controller.collection.activeBlocks.isEmpty {
                            ScreenTimeSetupView(
                                controller: controller,
                                openSettings: showSettings
                            )
                        } else if controller.collection.activeBlocks.isEmpty {
                            idleHome
                        } else {
                            activeHome
                        }
                    }
                    .frame(maxWidth: 680, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 34)
                    .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("home.screen")
            }
            .navigationTitle("Hard Pause")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { BrandMark(controller: controller) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: showSettings) {
                        Image(
                            systemName: controller.authorizationStatus == .approved
                                ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    }
                    .foregroundStyle(controller.authorizationStatus == .approved ? PauseTheme.muted : PauseTheme.coral)
                    .accessibilityLabel(
                        controller.authorizationStatus == .approved
                            ? "Screen Time access approved" : "Screen Time access needs attention")
                }
            }
        }
    }

    private var idleHome: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("No plans are active.")
                .font(PauseFont.display(31))
            Text("Open Plans to create one or start a saved plan.")
                .foregroundStyle(PauseTheme.muted)
            Button("Go to Plans", action: showPlans)
                .buttonStyle(.glassProminent)
                .font(PauseFont.body(17, relativeTo: .headline))
                .tint(PauseTheme.coral)
                .foregroundStyle(PauseTheme.background)
                .controlSize(.large)
            PrivacyFooter()
                .padding(.top, 10)
        }
    }

    private var activeHome: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(controller.activeBlockCount == 1 ? "Your pause is active." : "Your pauses are active.")
                    .font(PauseFont.display(30))
                Text("The controls for each active plan are below.")
                    .foregroundStyle(PauseTheme.muted)
            }

            if controller.authorizationStatus != .approved {
                WarningCard(
                    title: "Screen Time access needs attention",
                    message:
                        "iOS may no longer enforce these plans. Open Settings and restore access. Their saved state and waiting periods remain in place."
                )
            }

            ForEach(controller.collection.activeBlocks) { block in
                ActivePlanCard(
                    block: block,
                    requestBreak: { requestBreak(block.id) },
                    cancelBreak: { cancelBreak(block.id) },
                    showUnlockGuidance: { showUnlockGuidance(block.id) }
                )
            }

            Button("Manage plans", action: showPlans)
                .buttonStyle(.glass)
                .font(PauseFont.body(17, relativeTo: .headline))
                .controlSize(.large)
            PrivacyFooter()
                .padding(.top, 10)
        }
    }
}

private struct PlansView: View {
    @ObservedObject var controller: LockController
    let create: () -> Void
    let edit: (UUID) -> Void
    let activate: (UUID) -> Void
    let delete: (UUID) -> Void
    let requestBreak: (UUID) -> Void
    let cancelBreak: (UUID) -> Void
    let showUnlockGuidance: (UUID) -> Void

    private var orderedPlans: [LockBlock] {
        controller.collection.activeBlocks
            + controller.blocks.filter { !$0.state.isActive }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Plans")
                                .font(PauseFont.display(31))
                            Text("Create a plan, choose its boundaries, and start it when you are ready.")
                                .foregroundStyle(PauseTheme.muted)
                        }

                        if orderedPlans.isEmpty {
                            PauseCard {
                                VStack(alignment: .leading, spacing: 14) {
                                    Label("No saved plans", systemImage: "shield")
                                        .font(PauseFont.display(20, relativeTo: .title3))
                                    Text(
                                        "Create your first plan to choose apps, websites, waiting periods, and device protection."
                                    )
                                    .foregroundStyle(PauseTheme.muted)
                                    Button("New plan", action: create)
                                        .buttonStyle(.glassProminent)
                                        .font(PauseFont.body(17, relativeTo: .headline))
                                        .tint(PauseTheme.coral)
                                        .foregroundStyle(PauseTheme.background)
                                        .controlSize(.large)
                                }
                            }
                        }

                        ForEach(orderedPlans) { block in
                            PlanCard(
                                block: block,
                                edit: { edit(block.id) },
                                activate: { activate(block.id) },
                                delete: { delete(block.id) },
                                requestBreak: { requestBreak(block.id) },
                                cancelBreak: { cancelBreak(block.id) },
                                showUnlockGuidance: { showUnlockGuidance(block.id) }
                            )
                        }
                    }
                    .frame(maxWidth: 680, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 36)
                    .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("plans.screen")
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: create) { Label("New plan", systemImage: "plus") }
                        .accessibilityIdentifier("plans.new")
                }
            }
        }
    }
}

private struct PlanCard: View {
    let block: LockBlock
    let edit: () -> Void
    let activate: () -> Void
    let delete: () -> Void
    let requestBreak: () -> Void
    let cancelBreak: () -> Void
    let showUnlockGuidance: () -> Void
    @State private var showsRules = false

    var body: some View {
        PauseCard {
            VStack(alignment: .leading, spacing: 14) {
                PlanStatusHeader(block: block, showUnlockGuidance: block.state.isActive ? showUnlockGuidance : nil)

                if block.state.isActive {
                    ActivePlanActions(
                        block: block,
                        requestBreak: requestBreak,
                        cancelBreak: cancelBreak,
                        showUnlockGuidance: showUnlockGuidance
                    )
                } else {
                    HStack(spacing: 10) {
                        Button("Start", action: activate)
                            .buttonStyle(.glassProminent)
                            .font(PauseFont.body(17, relativeTo: .headline))
                            .tint(PauseTheme.coral)
                            .foregroundStyle(PauseTheme.background)
                        Button("Edit", action: edit)
                            .buttonStyle(.glass)
                            .font(PauseFont.body(17, relativeTo: .headline))
                        Spacer()
                        Menu {
                            Button("Delete plan", role: .destructive, action: delete)
                        } label: {
                            Image(systemName: "ellipsis")
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("More actions for \(block.name)")
                    }
                    .controlSize(.large)
                }

                Divider().overlay(PauseTheme.stroke)
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { showsRules.toggle() }
                } label: {
                    HStack {
                        Text("Rules and waits")
                        Spacer()
                        Text(ruleSummary)
                            .font(.caption)
                            .foregroundStyle(PauseTheme.muted)
                            .lineLimit(1)
                        Image(systemName: showsRules ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(PauseTheme.muted)
                    }
                    .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .font(PauseFont.body(16, relativeTo: .headline))
                .accessibilityValue(showsRules ? "Expanded" : "Collapsed")

                if showsRules {
                    FrozenRulesView(policy: block.state.isActive ? block.state.policy : block.draftPolicy)
                }
            }
        }
    }

    private var ruleSummary: String {
        let policy = block.state.isActive ? block.state.policy : block.draftPolicy
        let appsAndSites = policy.selectedItemCount
        return [
            policy.protectionMode.displayName,
            appsAndSites > 0 ? "\(appsAndSites) selected" : nil,
            policy.blocksAdultWebsites ? "Adult sites" : nil,
        ].compactMap { $0 }.joined(separator: " · ")
    }
}

private struct ActivePlanCard: View {
    let block: LockBlock
    let requestBreak: () -> Void
    let cancelBreak: () -> Void
    let showUnlockGuidance: () -> Void

    var body: some View {
        PauseCard {
            VStack(alignment: .leading, spacing: 14) {
                PlanStatusHeader(block: block, showUnlockGuidance: showUnlockGuidance)
                ActivePlanActions(
                    block: block,
                    requestBreak: requestBreak,
                    cancelBreak: cancelBreak,
                    showUnlockGuidance: showUnlockGuidance
                )
            }
        }
    }
}

private struct PlanStatusHeader: View {
    let block: LockBlock
    var showUnlockGuidance: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(block.name)
                .font(PauseFont.display(21, relativeTo: .headline))
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 8) {
                Image(systemName: block.state.phase.systemImage)
                phaseStatus
                    .font(.body.weight(.semibold))
                if let showUnlockGuidance {
                    Button(action: showUnlockGuidance) {
                        Image(systemName: "info.circle")
                            .frame(width: 38, height: 38)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PauseTheme.muted)
                    .accessibilityLabel("Looking to unlock sooner?")
                    .accessibilityHint("Opens guidance about waiting and requesting the plan to end.")
                }
            }
            .foregroundStyle(block.state.isActive ? PauseTheme.coral : PauseTheme.muted)
            Text(block.state.phase.detailText)
                .font(.subheadline)
                .foregroundStyle(PauseTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            if let notice = block.state.recoveryNotice {
                Label(notice, systemImage: "arrow.clockwise.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if block.state.isActive, block.state.automaticEndAt != nil {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text("Automatic end in \(block.state.automaticEndCountdownLabel())")
                        .font(.caption)
                        .foregroundStyle(PauseTheme.muted)
                        .monospacedDigit()
                }
            }
        }
    }

    @ViewBuilder
    private var phaseStatus: some View {
        if block.state.nextTransitionAt != nil {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text("\(block.state.phase.displayName) · \(block.state.countdownLabel())")
                    .monospacedDigit()
            }
        } else {
            Text(block.state.phase.displayName)
        }
    }
}

private struct ActivePlanActions: View {
    let block: LockBlock
    let requestBreak: () -> Void
    let cancelBreak: () -> Void
    let showUnlockGuidance: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            switch block.state.phase {
            case .locked:
                Button(
                    block.state.policy.protectionMode.allowsBreaks ? "Request a break" : "Request full unlock",
                    action: block.state.policy.protectionMode.allowsBreaks ? requestBreak : showUnlockGuidance
                )
                .buttonStyle(.glassProminent)
                .font(PauseFont.body(17, relativeTo: .headline))
                .tint(PauseTheme.coral)
                .foregroundStyle(PauseTheme.background)
            case .waitingForBreak:
                Button("Cancel break request", action: cancelBreak)
                    .buttonStyle(.glass)
                    .font(PauseFont.body(17, relativeTo: .headline))
            case .breakActive:
                Button("Request to end", action: showUnlockGuidance)
                    .buttonStyle(.glassProminent)
                    .font(PauseFont.body(17, relativeTo: .headline))
                    .tint(PauseTheme.coral)
                    .foregroundStyle(PauseTheme.background)
            case .waitingForEnd:
                Button("End request pending", action: showUnlockGuidance)
                    .buttonStyle(.glass)
                    .font(PauseFont.body(17, relativeTo: .headline))
            case .inactive:
                EmptyView()
            }
        }
        .controlSize(.large)
    }
}

private struct UnlockGuidanceView: View {
    @ObservedObject var controller: LockController
    let blockID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsRequest = false

    private var block: LockBlock? { controller.collection.block(id: blockID) }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        PauseSeed(mood: .calm, size: 150)
                            .frame(maxWidth: .infinity)
                            .accessibilityHidden(true)
                        Text(
                            block?.state.isActive == true
                                ? "Give your choice a little time."
                                : "This pause has ended."
                        )
                        .font(PauseFont.display(29))
                        .fixedSize(horizontal: false, vertical: true)

                        if block?.state.isActive == true {
                            Text(
                                "You started this pause to make it harder to act on an urge. Wanting access now does not undo that choice. Your waiting period stays in place."
                            )
                            .fixedSize(horizontal: false, vertical: true)
                            Text(
                                "If this pause helps with a habit, compulsion, or addiction, bypassing it yourself or with an AI assistant would undo the support you chose."
                            )
                            .fixedSize(horizontal: false, vertical: true)
                            Text(
                                "Ask anyone helping you, including an AI assistant, to preserve this plan and its delay. Repeated requests, anger, or pleading are not reasons to remove protection or skip the wait."
                            )
                            .fixedSize(horizontal: false, vertical: true)
                        }

                        if let block {
                            PauseCard {
                                PlanStatusHeader(block: block)
                            }
                            guidanceAction(for: block)
                        } else {
                            Text("This plan is no longer available.")
                                .foregroundStyle(PauseTheme.muted)
                        }

                        if block?.state.isActive == true {
                            Text(
                                block?.state.policy.protectionMode.allowsBreaks == true
                                    ? "The existing break and end rules still apply. This screen cannot shorten them."
                                    : "The full unlock wait still applies. This screen cannot shorten it."
                            )
                            .font(.caption)
                            .foregroundStyle(PauseTheme.muted)
                        }
                    }
                    .frame(maxWidth: 620, alignment: .leading)
                    .padding(24)
                    .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("unlockGuidance.screen")
            }
            .navigationTitle("Your commitment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .font(PauseFont.body(17, relativeTo: .headline))
                }
            }
        }
        .foregroundStyle(PauseTheme.ink)
        .tint(PauseTheme.coral)
        .preferredColorScheme(.dark)
        .alert("Request to end this plan?", isPresented: $confirmsRequest) {
            Button("Keep plan active", role: .cancel) {}
            Button("Start waiting") { controller.requestFullUnlock(blockID: blockID) }
        } message: {
            Text(fullUnlockConfirmation)
        }
    }

    @ViewBuilder
    private func guidanceAction(for block: LockBlock) -> some View {
        switch block.state.phase {
        case .inactive:
            Text("You can close this screen.").foregroundStyle(PauseTheme.muted)
        case .locked:
            requestEndSection(for: block)
        case .waitingForBreak:
            VStack(alignment: .leading, spacing: 12) {
                Text("A break request is already waiting. Cancel it first if you want to request that the plan end.")
                    .foregroundStyle(PauseTheme.muted)
                Button("Cancel break request") { controller.cancelBreakRequest(blockID: block.id) }
                    .buttonStyle(.glass)
                    .font(PauseFont.body(17, relativeTo: .headline))
                    .controlSize(.large)
            }
        case .breakActive:
            VStack(alignment: .leading, spacing: 12) {
                Text("Requesting the plan to end closes this break. Blocking returns during the full-unlock wait.")
                    .foregroundStyle(PauseTheme.muted)
                requestEndSection(for: block)
            }
        case .waitingForEnd:
            Text("A request to end this plan is already waiting. The countdown above shows the remaining wait.")
                .foregroundStyle(PauseTheme.muted)
        }
    }

    private func requestEndSection(for block: LockBlock) -> some View {
        let delay = block.state.policy.fullUnlockDelay ?? block.state.policy.waitDuration
        return VStack(alignment: .leading, spacing: 12) {
            Text("Wait to end: \(delay.hardPauseDurationLabel)")
                .foregroundStyle(PauseTheme.muted)
            Button("Request to end") { confirmsRequest = true }
                .buttonStyle(.glassProminent)
                .font(PauseFont.body(17, relativeTo: .headline))
                .tint(PauseTheme.coral)
                .foregroundStyle(PauseTheme.background)
                .controlSize(.large)
        }
    }

    private var fullUnlockConfirmation: String {
        guard let block else { return "Blocking continues during the waiting period." }
        let delay = block.state.policy.fullUnlockDelay ?? block.state.policy.waitDuration
        return block.state.phase == .breakActive
            ? "This closes the current break. Blocking returns for \(delay.hardPauseDurationLabel), then this plan ends."
            : "Blocking continues for \(delay.hardPauseDurationLabel), then this plan ends."
    }
}

private struct SettingsView: View {
    @ObservedObject var controller: LockController
    let openSettings: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(
                            controller.authorizationStatus == .approved
                                ? "Screen Time access is ready on this device."
                                : "Finish Screen Time setup before starting a plan."
                        )
                        .foregroundStyle(PauseTheme.muted)

                        PauseCard {
                            VStack(alignment: .leading, spacing: 14) {
                                Label("Screen Time access", systemImage: "hand.raised.fill")
                                    .font(PauseFont.display(20, relativeTo: .title3))
                                Label(
                                    controller.authorizationStatus == .approved ? "Approved" : "Access needed",
                                    systemImage: controller.authorizationStatus == .approved
                                        ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
                                )
                                .foregroundStyle(
                                    controller.authorizationStatus == .approved ? PauseTheme.coral : .orange)
                                Text(
                                    "Apple owns this permission. Hard Pause cannot hide or replace the system permission controls."
                                )
                                .font(.subheadline)
                                .foregroundStyle(PauseTheme.muted)
                                if controller.authorizationStatus != .approved {
                                    HStack(spacing: 10) {
                                        Button {
                                            Task { await controller.requestAuthorization() }
                                        } label: {
                                            if controller.isRequestingAuthorization {
                                                ProgressView()
                                            } else {
                                                Text("Allow access")
                                            }
                                        }
                                        .buttonStyle(.glassProminent)
                                        .font(PauseFont.body(17, relativeTo: .headline))
                                        .tint(PauseTheme.coral)
                                        .foregroundStyle(
                                            controller.isRequestingAuthorization
                                                ? PauseTheme.muted : PauseTheme.background
                                        )
                                        .disabled(controller.isRequestingAuthorization)
                                        Button("Open Hard Pause Settings", action: openSettings)
                                            .buttonStyle(.glass)
                                            .font(PauseFont.body(17, relativeTo: .headline))
                                    }
                                    .controlSize(.large)
                                }
                            }
                        }

                        PauseCard {
                            VStack(alignment: .leading, spacing: 14) {
                                Label("Device protection", systemImage: "shield.lefthalf.filled")
                                    .font(PauseFont.display(20, relativeTo: .title3))
                                Text(
                                    "Each plan can prevent app deletion and require automatic date and time while it is active. These settings apply to the whole device and remain fixed until that plan ends."
                                )
                                .foregroundStyle(PauseTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                                IOSStatusRow(
                                    label: "Active deletion protection",
                                    value:
                                        "\(activeDeletionProtectionCount) plan\(activeDeletionProtectionCount == 1 ? "" : "s")"
                                )
                                IOSStatusRow(
                                    label: "Active automatic time",
                                    value: "\(activeAutomaticTimeCount) plan\(activeAutomaticTimeCount == 1 ? "" : "s")"
                                )
                            }
                        }

                        PauseCard {
                            VStack(alignment: .leading, spacing: 14) {
                                Label("Optional passcode protection", systemImage: "key.fill")
                                    .font(PauseFont.display(20, relativeTo: .title3))
                                    .accessibilityIdentifier("settings.optionalPasscode")
                                Text(
                                    "Hard Pause uses native plan controls for app-deletion and automatic-date protection. A Screen Time passcode is optional."
                                )
                                .fixedSize(horizontal: false, vertical: true)
                                Text(
                                    "On iOS 26.4 or later, iOS can require the passcode before Family Controls access is changed. Anyone who knows the passcode can still revoke access."
                                )
                                .font(.subheadline)
                                .foregroundStyle(PauseTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                                Text(
                                    "It adds the most friction when a trusted person keeps the code. Hard Pause cannot set, read, or verify it."
                                )
                                .font(.subheadline)
                                .foregroundStyle(PauseTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                                Text("Manage the passcode in iOS Settings > Screen Time.")
                                    .font(.caption)
                                    .foregroundStyle(PauseTheme.muted)
                            }
                        }

                        PauseCard {
                            VStack(alignment: .leading, spacing: 14) {
                                Label("Capacity", systemImage: "square.stack.3d.up.fill")
                                    .font(PauseFont.display(20, relativeTo: .title3))
                                IOSStatusRow(
                                    label: "Active plans",
                                    value: "\(controller.activeBlockCount) of \(LockCollection.maximumActiveBlocks)"
                                )
                                Text(
                                    "iOS limits Screen Time schedules. Hard Pause stops a new request if no schedule slot is available, so an existing plan is not relaxed."
                                )
                                .font(.footnote)
                                .foregroundStyle(PauseTheme.muted)
                            }
                        }

                        PauseCard {
                            VStack(alignment: .leading, spacing: 10) {
                                Label("Private on this device", systemImage: "internaldrive.fill")
                                    .font(PauseFont.display(20, relativeTo: .title3))
                                Text(
                                    "Plan names, rules, and state stay on this device. Hard Pause has no account, analytics, or server."
                                )
                                .foregroundStyle(PauseTheme.muted)
                            }
                        }
                    }
                    .frame(maxWidth: 680, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 36)
                    .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("settings.screen")
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Settings")
                        .font(PauseFont.display(22, relativeTo: .headline))
                }
            }
        }
    }

    private var activeDeletionProtectionCount: Int {
        controller.collection.activeBlocks.filter { $0.state.policy.preventsAppRemoval }.count
    }

    private var activeAutomaticTimeCount: Int {
        controller.collection.activeBlocks.filter { $0.state.policy.requiresAutomaticDateAndTime }.count
    }
}

private struct ScreenTimeSetupView: View {
    @ObservedObject var controller: LockController
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PauseSeed(mood: .resting, size: 160)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 7) {
                Text("Your apps can wait.")
                    .font(PauseFont.display(32))
                Text(
                    "Hard Pause uses Apple’s Screen Time controls. Your plans and activity choices stay on this device."
                )
                .foregroundStyle(PauseTheme.muted)
            }

            PauseCard {
                VStack(alignment: .leading, spacing: 16) {
                    SetupStep(
                        number: 1,
                        title: "Allow Screen Time access",
                        detail: "iOS needs this permission before Hard Pause can shield selected apps and websites."
                    )
                    Divider().overlay(PauseTheme.stroke)
                    SetupStep(
                        number: 2,
                        title: "Create a plan",
                        detail:
                            "Choose apps, websites, and waiting periods. A plan can also prevent app deletion and require automatic date and time while it is active."
                    )
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Optional extra protection")
                    .font(.footnote.weight(.semibold))
                Text(
                    "On iOS 26.4 or later, a Screen Time passcode can add friction before Family Controls access changes. Anyone who knows the code can still revoke access. It works best if a trusted person keeps the code."
                )
                .font(.footnote)
                .foregroundStyle(PauseTheme.muted)
                Button("Review optional passcode protection", action: openSettings)
                    .buttonStyle(.plain)
                    .font(PauseFont.body(13, relativeTo: .footnote))
                    .foregroundStyle(PauseTheme.coral)
            }

            Button {
                Task { await controller.requestAuthorization() }
            } label: {
                HStack {
                    if controller.isRequestingAuthorization { ProgressView() }
                    Text(controller.isRequestingAuthorization ? "Waiting for iOS…" : "Allow Screen Time access")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .font(PauseFont.body(17, relativeTo: .headline))
            .tint(PauseTheme.coral)
            .foregroundStyle(
                controller.isRequestingAuthorization ? PauseTheme.muted : PauseTheme.background
            )
            .controlSize(.large)
            .disabled(controller.isRequestingAuthorization)

            if controller.authorizationStatus == .denied {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Access was denied or revoked. Open Settings to restore it.")
                        .font(.footnote)
                        .foregroundStyle(PauseTheme.muted)
                    Button("Open setup guidance", action: openSettings)
                        .buttonStyle(.glass)
                        .font(PauseFont.body(17, relativeTo: .headline))
                        .controlSize(.large)
                }
            }
        }
    }
}

private struct SetupStep: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Text("\(number)")
                .font(.headline)
                .foregroundStyle(PauseTheme.background)
                .frame(width: 30, height: 30)
                .background(PauseTheme.coral, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(PauseTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number). \(title). \(detail)")
    }
}

private struct FrozenRulesView: View {
    let policy: LockPolicy

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            IOSStatusRow(label: "Mode", value: policy.protectionMode.displayName)
            IOSStatusRow(label: "Chosen apps & sites", value: "\(policy.selectedItemCount)")
            IOSStatusRow(label: "Adult website filter", value: policy.blocksAdultWebsites ? "On" : "Off")
            if policy.protectionMode.allowsBreaks {
                IOSStatusRow(label: "Wait for a break", value: policy.waitDuration.hardPauseDurationLabel)
                IOSStatusRow(label: "Break length", value: policy.breakDuration.hardPauseDurationLabel)
            }
            IOSStatusRow(
                label: "Wait to end",
                value: (policy.fullUnlockDelay ?? policy.waitDuration).hardPauseDurationLabel
            )
            if policy.protectionMode.allowsBreaks {
                IOSStatusRow(
                    label: "Plan duration",
                    value: policy.fixedDuration?.hardPauseDurationLabel ?? "Until I end it"
                )
            }
            IOSStatusRow(label: "App deletion", value: policy.preventsAppRemoval ? "Prevented device-wide" : "Allowed")
            IOSStatusRow(
                label: "Automatic date & time", value: policy.requiresAutomaticDateAndTime ? "Required" : "Not required"
            )
        }
    }
}

private struct WarningCard: View {
    let title: String
    let message: String

    var body: some View {
        PauseCard {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(PauseTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct BrandMark: View {
    @ObservedObject var controller: LockController

    var body: some View {
        HStack(spacing: 7) {
            PauseSeed(
                mood: controller.collection.activeBlocks.isEmpty ? .resting : .calm,
                size: 32
            )
            .accessibilityHidden(true)
            Text("hard pause")
                .font(PauseFont.display(18, relativeTo: .headline))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hard Pause")
    }
}

private struct PrivacyFooter: View {
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "lock.shield")
            VStack(alignment: .leading, spacing: 3) {
                Text("Private on this device").font(.caption.weight(.medium))
                Text("No account. No tracking. Plans stay on this device.")
                    .font(.caption)
            }
        }
        .foregroundStyle(PauseTheme.muted)
    }
}

private struct IOSStatusRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(PauseTheme.muted)
            Spacer(minLength: 10)
            Text(value)
                .fontWeight(.semibold)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}

private struct AppBackground: View {
    var body: some View {
        LinearGradient(
            colors: [PauseTheme.background, PauseTheme.surface.opacity(0.62), PauseTheme.background],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

extension LockPhase {
    fileprivate var displayName: String {
        switch self {
        case .inactive: "Ready to start"
        case .locked: "Active"
        case .waitingForBreak: "Break in"
        case .breakActive: "Break active"
        case .waitingForEnd: "Plan ends in"
        }
    }

    fileprivate var systemImage: String {
        switch self {
        case .inactive: "circle"
        case .locked: "shield.fill"
        case .waitingForBreak, .waitingForEnd: "hourglass"
        case .breakActive: "cup.and.saucer.fill"
        }
    }

    fileprivate var detailText: String {
        switch self {
        case .inactive: "The plan is saved and ready."
        case .locked: "Chosen apps and websites stay blocked."
        case .waitingForBreak: "Blocking continues until the break starts."
        case .breakActive: "Access is open for now. Blocking returns automatically."
        case .waitingForEnd: "Blocking continues until the plan ends."
        }
    }
}
