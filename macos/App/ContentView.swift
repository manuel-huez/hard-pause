import SwiftUI

private enum WorkspacePane: String, CaseIterable, Identifiable {
    case home = "Home"
    case blocks = "Plans"
    case settings = "Settings"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .home: return "house"
        case .blocks: return "shield.lefthalf.filled"
        case .settings: return "gearshape"
        }
    }
}

private struct BlockEditorPresentation: Identifiable {
    let id = UUID()
    let block: ProtectedBlockSnapshot?
}

private struct UnlockGuidancePresentation: Identifiable {
    let id: UUID
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: WorkspacePane? = .home
    @State private var editor: BlockEditorPresentation?
    @State private var activationTarget: ProtectedBlockSnapshot?
    @State private var deletionTarget: ProtectedBlockSnapshot?
    @State private var unlockGuidance: UnlockGuidancePresentation?
    @State private var caretPosition: CGPoint?
    @State private var sidebarMascotFrame: CGRect = .zero
    @State private var hoveredControl: CGPoint?

    var body: some View {
        Group {
            if model.setupState == .checking {
                ProgressView("Checking protection…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(LowLightBackground())
            } else if shouldShowMandatorySetup {
                MandatorySetupView()
            } else {
                NavigationSplitView {
                    List(WorkspacePane.allCases, selection: $selection) { pane in
                        Label(pane.rawValue, systemImage: pane.symbol)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                            .mascotHoverTarget()
                            .listRowInsets(EdgeInsets())
                            .tag(pane)
                    }
                    .listStyle(.sidebar)
                    .tint(PauseTheme.coral)
                    .navigationTitle("Hard Pause")
                    .navigationSplitViewColumnWidth(min: 180, ideal: 205, max: 240)
                    .safeAreaInset(edge: .bottom) {
                        VStack(spacing: 4) {
                            PauseSeed(
                                mood: sidebarMascotMood,
                                size: 144,
                                attention: mascotAttention(
                                    caret: hoveredControl ?? caretPosition, frame: sidebarMascotFrame),
                                isAnimationPaused: editor != nil
                            )
                            .onGeometryChange(for: CGRect.self) {
                                $0.frame(in: .global)
                            } action: {
                                sidebarMascotFrame = $0
                            }
                            Text("hard pause")
                                .font(PauseFont.display(15))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                    }
                } detail: {
                    NavigationStack {
                        Group {
                            switch selection ?? .home {
                            case .home:
                                HomePane(
                                    showBlocks: { selection = .blocks },
                                    showSetup: { selection = .settings },
                                    showUnlockGuidance: { unlockGuidance = UnlockGuidancePresentation(id: $0) }
                                )
                            case .blocks:
                                BlocksPane(
                                    edit: { editor = BlockEditorPresentation(block: $0) },
                                    activate: { activationTarget = $0 },
                                    delete: { deletionTarget = $0 },
                                    addBlock: { editor = BlockEditorPresentation(block: nil) },
                                    showUnlockGuidance: { unlockGuidance = UnlockGuidancePresentation(id: $0) }
                                )
                            case .settings:
                                ProtectionSettingsPane()
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                        .background(LowLightBackground())
                        .navigationTitle((selection ?? .home).rawValue)
                        .toolbar {
                            if selection == .blocks {
                                ToolbarItem(placement: .primaryAction) {
                                    Button {
                                        editor = BlockEditorPresentation(block: nil)
                                    } label: {
                                        Label("New plan", systemImage: "plus")
                                    }
                                    .disabled(!model.canChangeBlocks)
                                    .keyboardShortcut("n", modifiers: .command)
                                    .mascotHoverTarget()
                                }
                            }
                        }
                    }
                }
            }
        }
        .environment(\.mascotHoverChanged, { hoveredControl = editor == nil ? $0 : nil })
        .onChange(of: editor?.id) { _, _ in
            hoveredControl = nil
            caretPosition = nil
        }
        .foregroundStyle(PauseTheme.ink)
        .tint(PauseTheme.coral)
        .preferredColorScheme(.dark)
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await model.refresh() }
        }
        .sheet(item: $editor) { presentation in
            BlockEditorView(block: presentation.block)
                .environmentObject(model)
        }
        .sheet(item: $unlockGuidance) { presentation in
            UnlockGuidanceView(blockID: presentation.id)
                .environmentObject(model)
        }
        .alert(
            "Start \(activationTarget?.draft.name ?? "this plan")?",
            isPresented: Binding(
                get: { activationTarget != nil },
                set: { if !$0 { activationTarget = nil } }
            ),
            presenting: activationTarget
        ) { block in
            Button("Cancel", role: .cancel) { activationTarget = nil }
            Button("Start plan") {
                activationTarget = nil
                Task { _ = await model.activate(block) }
            }
            .keyboardShortcut(.defaultAction)
        } message: { block in
            Text(block.activationConfirmation)
        }
        .alert(
            "Delete \(deletionTarget?.draft.name ?? "this plan")?",
            isPresented: Binding(
                get: { deletionTarget != nil },
                set: { if !$0 { deletionTarget = nil } }
            ),
            presenting: deletionTarget
        ) { block in
            Button("Cancel", role: .cancel) { deletionTarget = nil }
            Button("Delete", role: .destructive) {
                deletionTarget = nil
                Task { _ = await model.delete(block) }
            }
        } message: { _ in
            Text("This removes the saved plan. This action cannot be undone.")
        }
        .alert(
            "Hard Pause",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.clearError() } }
            )
        ) {
            Button("OK") { model.clearError() }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var shouldShowMandatorySetup: Bool {
        guard model.activeBlocks.isEmpty else { return false }
        return model.setupState == .incomplete
    }

    private var sidebarMascotMood: PauseSeedMood {
        // Resting keeps the idle mascot awake; every active block uses calm, closed eyes.
        return model.activeBlocks.isEmpty ? .resting : .calm
    }
}

private struct HomePane: View {
    @EnvironmentObject private var model: AppModel
    let showBlocks: () -> Void
    let showSetup: () -> Void
    let showUnlockGuidance: (UUID) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !model.activeBlocks.isEmpty && model.setupState == .incomplete
                    && !model.serviceUpdateIsOnlySetupGap
                {
                    SetupIncompleteBanner(showSetup: showSetup)
                }

                if case .unavailable = model.serviceAvailability {
                    ServiceSetupPanel()
                }

                VStack(alignment: .leading, spacing: 18) {
                    Text(model.activeBlocks.isEmpty ? "No plans are active." : "Your pause is active.")
                        .font(PauseFont.display(26, relativeTo: .title))
                    Text(
                        model.activeBlocks.isEmpty
                            ? "Open Plans to create one or start a saved plan."
                            : "The controls for your active plan are below."
                    )
                    .font(.body)
                    .foregroundStyle(PauseTheme.muted)

                    if model.activeBlocks.isEmpty && model.serviceAvailability == .ready {
                        Button("Go to Plans", action: showBlocks)
                            .buttonStyle(PauseButtonStyle(primary: true))
                    }

                    if !model.activeBlocks.isEmpty {
                        ForEach(model.activeBlocks) { block in
                            HomeActiveBlockCard(
                                block: block,
                                showUnlockGuidance: { showUnlockGuidance(block.id) }
                            )
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 13))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Private on this Mac")
                            .font(.caption.weight(.medium))
                        Text("No account. No tracking. Checks stay on this Mac.")
                            .font(.caption)
                    }
                }
                .foregroundStyle(PauseTheme.muted)
                .help(
                    "Rules and protection state stay on this Mac. Adult website list updates contact a public provider. Browser checks read tab addresses only when page protection is active. Chrome and Safari RTA checks read rating tags only; Firefox cannot read RTA labels. Positive RTA detections are cached locally for 24 hours. No browsing history is uploaded."
                )
                .padding(.top, 12)
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

private struct BreakRequestButton: View {
    @EnvironmentObject private var model: AppModel
    @State private var showsConfirmation = false
    let block: ProtectedBlockSnapshot

    var body: some View {
        Group {
            if block.canRequestBreak {
                Button("Request a break") { showsConfirmation = true }
                    .buttonStyle(PauseButtonStyle(primary: true))
                    .accessibilityLabel("Request a break from plan \(block.draft.name)")
                    .alert("Request a break?", isPresented: $showsConfirmation) {
                        Button("Keep blocking", role: .cancel) {}
                        Button("Request a break") {
                            Task { _ = await model.requestBreak(for: block) }
                        }
                    } message: {
                        Text(
                            "For \(block.draft.name), blocking will continue for \(block.draft.breakDelay.longDuration). Then you can take a \(block.draft.breakDuration.longDuration) break. You can cancel the request while you wait."
                        )
                    }
            } else if block.canCancelBreak {
                Button("Cancel break request") {
                    Task { _ = await model.cancelBreak(for: block) }
                }
                .buttonStyle(PauseButtonStyle())
                .accessibilityLabel("Cancel break request for plan \(block.draft.name)")
            }
        }
    }
}

private struct HomeActiveBlockCard: View {
    @EnvironmentObject private var model: AppModel
    let block: ProtectedBlockSnapshot
    let showUnlockGuidance: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            BlockStatusPanel(block: block, showUnlockGuidance: showUnlockGuidance)
            if block.canRequestBreak || block.canCancelBreak || block.canRequestFullEnd {
                HStack(spacing: 12) {
                    if block.canRequestBreak || block.canCancelBreak {
                        BreakRequestButton(block: block)
                    }
                    if block.canRequestFullEnd {
                        Button("Request to end") {
                            Task { _ = await model.requestEnd(for: block) }
                        }
                        .buttonStyle(PauseButtonStyle())
                        .controlSize(.large)
                    }
                }
                .controlSize(.large)
                .disabled(!model.canRequestUnlock)
            }
        }
        .settingsPanel()
    }
}

private struct BlocksPane: View {
    @EnvironmentObject private var model: AppModel
    let edit: (ProtectedBlockSnapshot) -> Void
    let activate: (ProtectedBlockSnapshot) -> Void
    let delete: (ProtectedBlockSnapshot) -> Void
    let addBlock: () -> Void
    let showUnlockGuidance: (UUID) -> Void

    var body: some View {
        Group {
            switch model.serviceAvailability {
            case .checking:
                ProgressView("Checking the Hard Pause service…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .unavailable:
                ScrollView {
                    ServiceSetupPanel()
                        .frame(maxWidth: 680, alignment: .leading)
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            case .ready:
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        Text("Plans")
                            .font(PauseFont.display(26, relativeTo: .title))
                        if model.blocks.isEmpty {
                            Text("Create a plan, choose its boundaries, and start it when you are ready.")
                                .foregroundStyle(PauseTheme.muted)
                            Button("New plan", action: addBlock)
                                .buttonStyle(PauseButtonStyle(primary: true))
                        }
                        ForEach(model.activeBlocks + model.blocks.filter { $0.phase == .inactive }) { block in
                            BlockPanel(
                                block: block,
                                edit: { edit(block) },
                                activate: { activate(block) },
                                delete: { delete(block) },
                                showUnlockGuidance: { showUnlockGuidance(block.id) }
                            )
                        }
                    }
                    .frame(maxWidth: 680, alignment: .leading)
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
    }
}

private struct SetupIncompleteBanner: View {
    let showSetup: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(PauseTheme.coral)
                .font(.title3)
            VStack(alignment: .leading, spacing: 6) {
                Text("Finish setup to keep protection ready")
                    .font(PauseFont.display(18, relativeTo: .headline))
                Text(
                    "Your active plan and its unlock delays remain in place. Complete the missing setup step when you can."
                )
                .foregroundStyle(PauseTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
                Button("Open setup", action: showSetup)
                    .buttonStyle(PauseButtonStyle(primary: true))
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PauseTheme.coral.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(PauseTheme.coral.opacity(0.28), lineWidth: 1)
        }
    }
}

private struct BlockPanel: View {
    @EnvironmentObject private var model: AppModel
    let block: ProtectedBlockSnapshot
    let edit: () -> Void
    let activate: () -> Void
    let delete: () -> Void
    let showUnlockGuidance: () -> Void
    @State private var showsRules = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            BlockStatusPanel(block: block, showUnlockGuidance: showUnlockGuidance)

            HStack(spacing: 12) {
                if block.phase == .inactive {
                    Button("Start", action: activate)
                        .buttonStyle(PauseButtonStyle(primary: true))
                        .accessibilityLabel("Start plan \(block.draft.name)")
                    Button("Edit", action: edit)
                        .buttonStyle(PauseButtonStyle())
                        .accessibilityLabel("Edit plan \(block.draft.name)")
                    Spacer()
                    Menu {
                        Button("Delete plan", role: .destructive, action: delete)
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 32, height: 32)
                            .contentShape(Circle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .mascotHoverTarget()
                    .fixedSize()
                    .accessibilityLabel("More actions for plan \(block.draft.name)")
                } else {
                    Button("Add rules", action: edit)
                        .buttonStyle(PauseButtonStyle())
                        .accessibilityLabel("Add rules to plan \(block.draft.name)")
                    if block.canRequestBreak || block.canCancelBreak {
                        BreakRequestButton(block: block)
                    }
                    if block.canRequestFullEnd {
                        Button("Request to end") {
                            Task { _ = await model.requestEnd(for: block) }
                        }
                        .buttonStyle(PauseButtonStyle())
                        .accessibilityLabel("Request to end for plan \(block.draft.name)")
                    }
                }
            }
            .controlSize(.large)
            .disabled(block.phase == .inactive ? !model.canChangeBlocks : !model.canRequestUnlock)

            Divider()
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showsRules.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Text("Rules and delays")
                    Spacer()
                    Text(block.ruleSummary).foregroundStyle(PauseTheme.muted)
                    Image(systemName: showsRules ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PauseTheme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .mascotHoverTarget()
            .accessibilityLabel("Rules and delays for plan \(block.draft.name)")
            .accessibilityValue(showsRules ? "Expanded" : "Collapsed")
            if showsRules {
                FixedRulesView(draft: block.draft)
            }
        }
        .settingsPanel()
    }
}

private struct BlockStatusPanel: View {
    @EnvironmentObject private var model: AppModel
    let block: ProtectedBlockSnapshot
    var showUnlockGuidance: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(block.draft.name)
                .font(PauseFont.display(18, relativeTo: .headline))
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 8) {
                Label(block.phase.statusText(elapsed: model.displayElapsed), systemImage: block.phase.symbol)
                    .font(.body.weight(.medium))
                    .foregroundStyle(block.phase == .inactive ? PauseTheme.muted : PauseTheme.coral)
                if block.phase != .inactive, let showUnlockGuidance {
                    Button(action: showUnlockGuidance) {
                        Image(systemName: "info.circle")
                            .padding(3)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .mascotHoverTarget()
                    .foregroundStyle(PauseTheme.muted)
                    .help("Looking to unlock sooner?")
                    .accessibilityLabel("Looking to unlock sooner?")
                    .accessibilityHint("Opens guidance about waiting and requests to end a plan.")
                }
            }
            if let detail = block.phase.detailText(elapsed: model.displayElapsed) {
                Text(detail).font(.callout).foregroundStyle(PauseTheme.muted)
            }
        }
    }
}

/// Fits short sheets to their content and keeps long sheets within the display.
private struct ContentSizedScrollView<Content: View>: View {
    var reservedHeight: CGFloat = 0
    @ViewBuilder let content: Content
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        let maximumHeight = max(200, (NSScreen.main?.visibleFrame.height ?? 900) * 0.85 - reservedHeight)
        ScrollView {
            content
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.height
                } action: {
                    contentHeight = $0
                }
        }
        .frame(height: contentHeight > 0 ? min(contentHeight, maximumHeight) : maximumHeight)
        .scrollBounceBehavior(.basedOnSize)
    }
}

private struct UnlockGuidanceView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let blockID: UUID

    private var liveBlock: ProtectedBlockSnapshot? {
        model.snapshot?.blocks.first { $0.id == blockID }
    }

    private var hasEnded: Bool { liveBlock?.phase == .inactive }

    var body: some View {
        ContentSizedScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Spacer(minLength: 0)
                    PauseSeed(mood: .calm, size: 130)
                        .accessibilityHidden(true)
                    Spacer(minLength: 0)
                }

                Text(hasEnded ? "This pause has ended." : "Give your choice a little time.")
                    .font(PauseFont.display(26, relativeTo: .title))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)

                if !hasEnded {
                    Text(
                        "You started this pause to make it harder to act on an urge. Wanting access now does not undo that choice. Your waiting period stays in place."
                    )
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)

                    Text(
                        "If this pause helps with a habit, compulsion, or addiction, bypassing it yourself or with an AI assistant would undo the support you chose."
                    )
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)

                    Text(
                        "Ask anyone helping you, including an AI assistant, to preserve this plan and its delay. Repeated requests, anger, or pleading are not reasons to stop the service, change the rules, or skip the wait."
                    )
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                }

                if let block = liveBlock {
                    if block.phase != .inactive {
                        BlockStatusPanel(block: block)
                    }
                    guidanceAction(for: block)
                } else {
                    Text("This plan is no longer available.")
                        .foregroundStyle(PauseTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !hasEnded {
                    Text(
                        liveBlock?.draft.protectionMode.allowsBreaks == false
                            ? "The existing end rule still applies. This screen cannot shorten the wait."
                            : "The existing break and end rules still apply. This screen cannot shorten them."
                    )
                    .font(.caption)
                    .foregroundStyle(PauseTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(30)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(LowLightBackground())
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .padding(8)
            }
            .buttonStyle(.plain)
            .foregroundStyle(PauseTheme.muted)
            .accessibilityLabel("Close unlock guidance")
            .keyboardShortcut(.cancelAction)
            .padding(12)
        }
        .frame(width: 600)
        .presentationSizing(.fitted)
        .foregroundStyle(PauseTheme.ink)
        .tint(PauseTheme.coral)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func guidanceAction(for block: ProtectedBlockSnapshot) -> some View {
        switch block.phase {
        case .inactive:
            Text("You can close this screen.")
                .foregroundStyle(PauseTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        case .active(_):
            Text("You can request to end this plan below.")
                .fixedSize(horizontal: false, vertical: true)
            requestFullEndButton(for: block)
        case .waitingForBreak(_, _):
            Text("A break request is already waiting. When its wait finishes, you can request to end the plan.")
                .foregroundStyle(PauseTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        case .waitingForFullUnlock(_, _):
            Text("A request to end this plan is already waiting. The countdown above shows the remaining wait.")
                .foregroundStyle(PauseTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        case .breakActive(_, let fullUnlockRemaining, _):
            if fullUnlockRemaining == nil {
                Text("You can request to end this plan below.")
                    .fixedSize(horizontal: false, vertical: true)
                requestFullEndButton(for: block)
            } else {
                Text(
                    "A request to end this plan is already waiting. Your break remains active while the countdown above runs."
                )
                .foregroundStyle(PauseTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func requestFullEndButton(for block: ProtectedBlockSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Wait to end: \(block.draft.fullUnlockDelay.longDuration)")
                .foregroundStyle(PauseTheme.muted)
            Button("Request to end") {
                Task { _ = await model.requestEnd(for: block) }
            }
            .buttonStyle(PauseButtonStyle(primary: true))
            .disabled(!model.canRequestUnlock)
            .accessibilityLabel("Request to end for plan \(block.draft.name)")
        }
    }
}

private enum PlanWizardStep: Int, CaseIterable, Hashable, Identifiable {
    case intention
    case boundaries
    case commitment

    var id: Self { self }

    var title: String {
        switch self {
        case .intention: return "Intention"
        case .boundaries: return "Boundaries"
        case .commitment: return "Commitment"
        }
    }
}

private enum PlanIntention: String, CaseIterable, Identifiable {
    case focus
    case lessTime
    case stayAway
    case custom

    var id: Self { self }

    var title: String {
        switch self {
        case .focus: return "Focus for a while"
        case .lessTime: return "Spend less time"
        case .stayAway: return "Stay away"
        case .custom: return "Set it up myself"
        }
    }

    var detail: String {
        switch self {
        case .focus:
            return "A one-hour plan with short waits if you need access."
        case .lessTime:
            return "An ongoing plan with a 15-minute break wait and a one-day wait to end it."
        case .stayAway:
            return "An ongoing plan with a one-day break wait and a one-week wait to end it."
        case .custom:
            return "Choose your own sites, apps, and waiting periods."
        }
    }

    var symbol: String {
        switch self {
        case .focus: return "scope"
        case .lessTime: return "clock.arrow.circlepath"
        case .stayAway: return "shield.lefthalf.filled"
        case .custom: return "slider.horizontal.3"
        }
    }

    var suggestedName: String {
        switch self {
        case .focus: return "Focus time"
        case .lessTime: return "Less time"
        case .stayAway: return "Stay away"
        case .custom: return ""
        }
    }
}

@Observable
private final class EditorMascotTracking {
    var caret: CGPoint?
    var hover: CGPoint?
    var isScrolling = false
}

private struct EditorMascot: View {
    let tracking: EditorMascotTracking
    let greetingTrigger: Int
    @State private var frame = CGRect.zero

    var body: some View {
        PauseSeed(
            mood: .resting,
            size: 120,
            attention: tracking.isScrolling
                ? nil : mascotAttention(caret: tracking.hover ?? tracking.caret, frame: frame),
            greetingTrigger: greetingTrigger,
            isAnimationPaused: tracking.isScrolling
        )
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .global)
        } action: {
            frame = $0
        }
        .help("Say hello to Low Light")
    }
}

private struct BlockEditorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let block: ProtectedBlockSnapshot?

    @AccessibilityFocusState private var headerFocused: Bool
    @AccessibilityFocusState private var errorFocused: Bool

    @State private var step: PlanWizardStep
    @State private var intention: PlanIntention?
    @State private var name: String
    @State private var domainInput = ""
    @State private var allowedInput = ""
    @State private var blocksAdultWebsites: Bool
    @State private var domains: [String]
    @State private var allowedDomains: [String]
    @State private var urlPatterns: [String]
    @State private var applications: [ProtectedApplication]
    @State private var protectionMode: ProtectionMode
    @State private var breakDelay: TimeInterval
    @State private var fullUnlockDelay: TimeInterval
    @State private var breakDuration: TimeInterval
    @State private var hasFixedDuration: Bool
    @State private var fixedDuration: TimeInterval
    @State private var validationMessage: String?
    @State private var addedDomains: [String] = []
    @State private var addedURLPatterns: [String] = []
    @State private var addedApplications: [ProtectedApplication] = []
    @State private var enableAdultWebsites = false
    @State private var isSubmitting = false
    @State private var mascotTracking = EditorMascotTracking()
    @State private var mascotGreetingTrigger = 0

    init(block: ProtectedBlockSnapshot?) {
        self.block = block
        _step = State(initialValue: block == nil ? .intention : .boundaries)
        _intention = State(initialValue: nil)
        let draft = block?.draft
        _name = State(initialValue: draft?.name ?? "")
        _blocksAdultWebsites = State(initialValue: draft?.rules.blocksAdultWebsites ?? false)
        let adultDomains = draft?.rules.blockedAdultDomains ?? []
        var patterns = draft?.rules.blockedURLPatterns ?? []
        for domain in adultDomains where !domain.hasPrefix("www.") {
            guard adultDomains.contains("www.\(domain)") else { continue }
            let wildcard = "*.\(domain)"
            if !patterns.contains(wildcard) { patterns.append(wildcard) }
        }
        let networkAliases = Set(patterns.flatMap { URLPatternRule.networkDomains(from: $0) })
        var editableDomains = (draft?.rules.blockedDomains ?? []).filter { !networkAliases.contains($0) }
        for domain in adultDomains {
            if domain.hasPrefix("www."), adultDomains.contains(String(domain.dropFirst(4))) { continue }
            if !editableDomains.contains(domain) { editableDomains.append(domain) }
        }
        _domains = State(initialValue: editableDomains)
        _allowedDomains = State(initialValue: draft?.rules.allowedDomains ?? [])
        _urlPatterns = State(initialValue: patterns)
        _applications = State(initialValue: draft?.rules.blockedApplications ?? [])
        _protectionMode = State(initialValue: draft?.protectionMode ?? .softLock)
        _breakDelay = State(initialValue: draft?.breakDelay ?? 3_600)
        _fullUnlockDelay = State(initialValue: draft?.fullUnlockDelay ?? 86_400)
        _breakDuration = State(initialValue: draft?.breakDuration ?? 900)
        _hasFixedDuration = State(initialValue: draft?.elapsedDuration != nil)
        _fixedDuration = State(initialValue: draft?.elapsedDuration ?? 86_400)
    }

    private var isReadOnly: Bool {
        guard let block else { return false }
        return block.phase != .inactive
    }

    private var availableSteps: [PlanWizardStep] {
        block == nil ? PlanWizardStep.allCases : [.boundaries, .commitment]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(headerTitle)
                        .font(PauseFont.display(26, relativeTo: .title))
                    Text(headerDetail)
                        .foregroundStyle(PauseTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityFocused($headerFocused)
                Spacer(minLength: 12)
                EditorMascot(tracking: mascotTracking, greetingTrigger: mascotGreetingTrigger)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 14)

            if !isReadOnly {
                PlanWizardStepIndicator(steps: availableSteps, current: step)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
            }

            Divider()

            if isReadOnly, let block {
                ScrollView {
                    activeRulesStep(for: block)
                        .padding(24)
                        .disabled(isSubmitting)
                }
            } else {
                ScrollView {
                    Group {
                        switch step {
                        case .intention:
                            intentionStep
                        case .boundaries:
                            boundariesStep
                        case .commitment:
                            commitmentStep
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                    .disabled(isSubmitting)
                }
                .onScrollPhaseChange { _, phase in
                    mascotTracking.isScrolling = phase != .idle
                    if phase != .idle { mascotTracking.hover = nil }
                }
            }

            Divider()
            footer
        }
        .buttonStyle(PauseButtonStyle())
        .controlSize(.large)
        .background(LowLightBackground())
        .frame(width: 720, height: min(680, max(480, (NSScreen.main?.visibleFrame.height ?? 800) - 100)))
        .presentationSizing(.fitted)
        .interactiveDismissDisabled(isSubmitting)
        .environment(
            \.mascotHoverChanged,
            {
                guard !mascotTracking.isScrolling else { return }
                mascotTracking.hover = $0
            }
        )
        .onChange(of: step) { _, _ in
            mascotTracking.caret = nil
            mascotTracking.hover = nil
            headerFocused = true
            mascotGreetingTrigger += 1
        }
        .onChange(of: intention) { _, _ in mascotGreetingTrigger += 1 }
        .onChange(of: validationMessage) { _, message in
            if message != nil { errorFocused = true }
        }
        .onDisappear { mascotTracking.caret = nil }
    }

    private var headerTitle: String {
        if isReadOnly { return "Add protection" }
        return block == nil ? "Create a plan" : "Edit plan"
    }

    private var headerDetail: String {
        if isReadOnly {
            return "Add rules to \(block?.draft.name ?? "this plan"). Existing rules and delays stay fixed."
        }
        switch step {
        case .intention: return "Start with a suggestion that fits what you want to change."
        case .boundaries: return "Name your plan and choose the websites and apps it will block."
        case .commitment: return "Review your plan and choose when you can get access."
        }
    }

    private func activeRulesStep(for block: ProtectedBlockSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(
                "You can add websites and apps. You cannot remove existing rules or change the waiting periods while this plan is active.",
                systemImage: "lock.fill"
            )
            .foregroundStyle(PauseTheme.coral)
            .fixedSize(horizontal: false, vertical: true)
            FixedRulesView(draft: block.draft)
                .settingsPanel()

            editorSection("Add websites") {
                HStack(spacing: 10) {
                    CaretTrackingTextField(
                        "example.com or example.com/page", text: $domainInput,
                        accessibilityLabel: "Website to add", onSubmit: { _ = addActiveWebsite() },
                        onCaretChange: { mascotTracking.caret = $0 }
                    )
                    .frame(height: 28)
                    Button("Add") { _ = addActiveWebsite() }
                        .disabled(domainInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                PagedPlanRules(addedDomains) { domain in
                    RemovableRule(title: domain, symbol: "globe") {
                        addedDomains.removeAll { $0 == domain }
                        addedURLPatterns.removeAll { $0 == "*.\(domain)" }
                    }
                }
                PagedPlanRules(
                    addedURLPatterns.filter { pattern in
                        !addedDomains.contains { pattern == "*.\($0)" }
                    }
                ) { pattern in
                    RemovableRule(title: pattern, symbol: "link") {
                        addedURLPatterns.removeAll { $0 == pattern }
                    }
                }
            }

            if !block.draft.rules.blocksAdultWebsites {
                editorSection("Adult websites") {
                    Toggle("Block adult websites", isOn: $enableAdultWebsites)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }
            }

            editorSection("Add applications") {
                PagedPlanRules(addedApplications) { application in
                    RemovableRule(title: application.displayName, symbol: "app") {
                        addedApplications.removeAll { $0.id == application.id }
                    }
                }
                Button {
                    Task {
                        let selected = await model.chooseApplications()
                        for application in selected
                        where !block.draft.rules.blockedApplications.contains(where: { $0.id == application.id })
                            && !addedApplications.contains(where: { $0.id == application.id })
                        {
                            addedApplications.append(application)
                        }
                    }
                } label: {
                    Label("Add applications…", systemImage: "plus")
                }
            }
        }
    }

    private var intentionStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("What would you like help with?")
                    .font(PauseFont.display(20, relativeTo: .title2))
                Text("Each choice is only a starting point. You can adjust the settings before starting.")
                    .foregroundStyle(PauseTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                spacing: 12
            ) {
                ForEach(PlanIntention.allCases) { option in
                    intentionCard(option)
                }
            }
        }
    }

    private func intentionCard(_ option: PlanIntention) -> some View {
        let isSelected = intention == option
        return Button {
            selectIntention(option)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: option.symbol)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(PauseTheme.coral)
                    Spacer()
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? PauseTheme.coral : PauseTheme.muted)
                }
                Text(option.title)
                    .font(PauseFont.display(17, relativeTo: .headline))
                    .foregroundStyle(PauseTheme.ink)
                Text(option.detail)
                    .font(.callout)
                    .foregroundStyle(PauseTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 126, alignment: .topLeading)
            .background(
                isSelected ? PauseTheme.coral.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(isSelected ? PauseTheme.coral.opacity(0.65) : PauseTheme.stroke, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .mascotHoverTarget()
        .accessibilityLabel("\(option.title). \(option.detail)")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }

    private func adultFilterDetail(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var boundariesStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            editorSection("Plan name") {
                CaretTrackingTextField(
                    "e.g. Focus time", text: $name, accessibilityLabel: "Plan name",
                    inputMode: .name, onSubmit: {},
                    onCaretChange: {
                        mascotTracking.caret = $0
                        if $0 != nil { mascotTracking.hover = nil }
                    }
                )
                .frame(height: 28)
                .mascotHoverTarget()
            }

            editorSection("Websites") {
                HStack(spacing: 10) {
                    CaretTrackingTextField(
                        "example.com or example.com/page", text: $domainInput,
                        accessibilityLabel: "Website", onSubmit: { _ = addDomain() },
                        onCaretChange: {
                            mascotTracking.caret = $0
                            if $0 != nil { mascotTracking.hover = nil }
                        }
                    )
                    .frame(height: 28)
                    .mascotHoverTarget()
                    Button("Add") { _ = addDomain() }
                        .disabled(domainInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("Add a whole site, a page, or a pattern such as *.example.com.")
                    .font(.caption)
                    .foregroundStyle(PauseTheme.muted)
                HStack(spacing: 8) {
                    Text("Quick add").foregroundStyle(PauseTheme.muted)
                    ForEach(SitePreset.allCases) { preset in
                        Button(preset.rawValue) { addPreset(preset) }
                    }
                }
                .buttonStyle(PauseButtonStyle(compact: true))
                .controlSize(.regular)
                Divider()
                if domains.isEmpty && urlPatterns.isEmpty {
                    Text("No websites added yet. Enter an address above or use Quick add.")
                        .font(.callout)
                        .foregroundStyle(PauseTheme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                }
                PagedPlanRules(domains) { domain in
                    let wildcard = "*.\(domain)"
                    RemovableRule(
                        title: domain,
                        symbol: "globe",
                        includesSubdomains: URLPatternRule.normalize(wildcard) == nil
                            ? nil
                            : Binding(
                                get: { urlPatterns.contains(wildcard) },
                                set: { enabled in
                                    urlPatterns.removeAll { $0 == wildcard }
                                    if enabled { urlPatterns.append(wildcard) }
                                }
                            )
                    ) {
                        domains.removeAll { $0 == domain }
                        urlPatterns.removeAll { $0 == wildcard }
                    }
                }
                PagedPlanRules(standalonePatterns) { pattern in
                    RemovableRule(title: pattern, symbol: "link") {
                        urlPatterns.removeAll { $0 == pattern }
                    }
                }
            }

            editorSection("Allowed websites") {
                Text(
                    "Allowed websites override this plan's rules. Another active plan can still block them. You cannot add exceptions after this plan starts."
                )
                .font(.caption)
                .foregroundStyle(PauseTheme.muted)
                HStack(spacing: 10) {
                    TextField("example.com", text: $allowedInput)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { _ = addAllowedDomain() }
                    Button("Add") { _ = addAllowedDomain() }
                        .disabled(allowedInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                PagedPlanRules(allowedDomains) { domain in
                    RemovableRule(title: domain, symbol: "checkmark.shield") {
                        allowedDomains.removeAll { $0 == domain }
                    }
                }
            }

            editorSection("Adult websites") {
                Toggle("Block adult websites", isOn: $blocksAdultWebsites)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .mascotHoverTarget()
                VStack(alignment: .leading, spacing: 8) {
                    adultFilterDetail(
                        "list.bullet",
                        "Downloads The Block List Project’s adult website list daily. Checks domains and their subdomains on this Mac."
                    )
                    adultFilterDetail(
                        "tag",
                        "Checks RTA adult-content tags in Chrome and Safari. Requires Allow JavaScript from Apple Events."
                    )
                    adultFilterDetail(
                        "lock", "Remembers detected pages on this Mac for 24 hours. No browsing history is uploaded.")
                    adultFilterDetail(
                        "info.circle", "Firefox uses the list and saved results. No filter catches every adult site.")
                }
                .font(.caption)
                .foregroundStyle(PauseTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            }

            editorSection("Applications") {
                PagedPlanRules(applications) { application in
                    RemovableRule(
                        title: application.displayName, symbol: "app",
                        detail: application.bundleIdentifier
                    ) { applications.removeAll { $0.id == application.id } }
                }
                Button {
                    Task {
                        let selected = await model.chooseApplications()
                        for application in selected
                        where !applications.contains(where: { $0.id == application.id }) {
                            applications.append(application)
                        }
                    }
                } label: {
                    Label("Add applications…", systemImage: "plus")
                }
                Text("Selected apps close while the plan is active. Save your work before starting it.")
                    .font(.caption)
                    .foregroundStyle(PauseTheme.muted)
            }
        }
    }

    private var commitmentStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            editorSection(name.trimmingCharacters(in: .whitespacesAndNewlines)) {
                DisclosureGroup {
                    planRuleReview.padding(.top, 8)
                } label: {
                    Label(reviewTargetSummary, systemImage: "list.bullet")
                        .foregroundStyle(PauseTheme.ink)
                }
                .mascotHoverTarget()
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Plan type").font(.body.weight(.semibold))
                    HStack(spacing: 10) {
                        ForEach(ProtectionMode.allCases, id: \.self) { mode in
                            protectionModeCard(mode)
                        }
                    }
                }
                Divider()
                VStack(spacing: 10) {
                    if protectionMode.allowsBreaks {
                        HStack {
                            Text("Duration")
                            Spacer()
                            Picker(
                                "Duration",
                                selection: Binding<TimeInterval>(
                                    get: { hasFixedDuration ? fixedDuration : 0 },
                                    set: { value in
                                        hasFixedDuration = value != 0
                                        if value != 0 { fixedDuration = value }
                                    }
                                )
                            ) {
                                Text("Until I end it").tag(TimeInterval(0))
                                ForEach(
                                    Array(Set(DelayValues.fixed + [fixedDuration])).sorted(),
                                    id: \.self
                                ) { value in
                                    Text(value.longDuration).tag(value)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                            .mascotHoverTarget()
                            .accessibilityIdentifier("plan-fixed-duration")
                        }
                        DurationPicker(
                            "Wait for a break",
                            selection: $breakDelay,
                            values: DelayValues.access
                        )
                        .accessibilityIdentifier("plan-break-delay")
                        DurationPicker(
                            "Break length",
                            selection: $breakDuration,
                            values: DelayValues.breaks
                        )
                        .accessibilityIdentifier("plan-break-duration")
                    }
                    DurationPicker(
                        "Wait to end the plan",
                        selection: $fullUnlockDelay,
                        values: DelayValues.access
                    )
                    .accessibilityIdentifier("plan-full-unlock-delay")
                }
                Text(
                    protectionMode.allowsBreaks && hasFixedDuration
                        ? "Ends automatically after \(fixedDuration.longDuration) of recorded active time."
                        : "Stays active until you request to end it and the waiting period finishes."
                )
                .font(.caption)
                .foregroundStyle(PauseTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            }

            if !applications.isEmpty {
                Label(
                    "Selected apps close when the plan starts. Save your work first.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.callout)
                .foregroundStyle(PauseTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var standalonePatterns: [String] {
        let covered = Set(domains.map { "*.\($0)" })
        return urlPatterns.filter { !covered.contains($0) }
    }

    private func protectionModeCard(_ mode: ProtectionMode) -> some View {
        let isSelected = protectionMode == mode
        return Button {
            protectionMode = mode
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(mode.displayName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(PauseTheme.ink)
                    Text(mode.shortDetail)
                        .font(.caption)
                        .foregroundStyle(PauseTheme.muted)
                }
                Spacer(minLength: 8)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? PauseTheme.coral : PauseTheme.muted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(
                isSelected ? PauseTheme.coral.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isSelected ? PauseTheme.coral.opacity(0.65) : PauseTheme.stroke, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .mascotHoverTarget()
        .accessibilityLabel("\(mode.displayName). \(mode.shortDetail)")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityIdentifier(mode.accessibilityIdentifier)
    }

    private var reviewWebsites: [WebsiteRulePresentation] {
        WebsiteRulePresentation.rows(domains: domains, patterns: urlPatterns)
    }

    private var reviewTargetSummary: String {
        let sites = reviewWebsites.count
        return
            "\(sites) website\(sites == 1 ? "" : "s") · \(applications.count) app\(applications.count == 1 ? "" : "s")"
    }

    private var planRuleReview: some View {
        VStack(alignment: .leading, spacing: 8) {
            if domains.isEmpty && urlPatterns.isEmpty {
                Text("No websites").foregroundStyle(PauseTheme.muted)
            } else {
                Text("Websites").font(.body.weight(.semibold))
                PagedPlanRules(reviewWebsites) { website in
                    WebsiteRuleSummaryRow(website: website)
                }
            }

            if !allowedDomains.isEmpty {
                Text("Allowed websites").font(.body.weight(.semibold)).padding(.top, 4)
                PagedPlanRules(allowedDomains) { domain in
                    Text(domain).textSelection(.enabled)
                }
            }

            Text("Adult websites").font(.body.weight(.semibold)).padding(.top, 4)
            Text(blocksAdultWebsites ? "Block adult websites" : "Do not block adult websites")
                .foregroundStyle(PauseTheme.muted)

            if applications.isEmpty {
                Text("No applications").foregroundStyle(PauseTheme.muted)
            } else {
                Text("Applications").font(.body.weight(.semibold)).padding(.top, 4)
                PagedPlanRules(applications) { application in
                    Text(application.displayName).textSelection(.enabled)
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if step == .commitment && !isReadOnly {
                Text("Starting fixes these rules and waiting periods. You can add rules later.")
                    .font(.caption)
                    .foregroundStyle(PauseTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityFocused($errorFocused)
            } else if step == .boundaries && !canContinue {
                Text("Add a plan name and at least one website or app to continue.")
                    .font(.caption)
                    .foregroundStyle(PauseTheme.muted)
            }
            HStack(spacing: 10) {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                if isSubmitting {
                    ProgressView(block == nil ? "Saving plan…" : "Saving changes…")
                        .controlSize(.small)
                        .foregroundStyle(PauseTheme.muted)
                }

                Spacer()

                if isReadOnly {
                    Button("Save added rules") { saveAddedRules() }
                        .buttonStyle(PauseButtonStyle(primary: true))
                        .disabled(!model.canRequestUnlock || !hasAddedRules)
                } else {
                    if step != availableSteps.first {
                        Button("Back", action: goBack)
                    }

                    if step == .commitment {
                        if block == nil {
                            Button("Save for later") { save(startNow: false) }
                                .disabled(!canWrite)
                            Button("Start plan") { save(startNow: true) }
                                .buttonStyle(PauseButtonStyle(primary: true))
                                .disabled(!canWrite)
                                .keyboardShortcut(.return, modifiers: .command)
                        } else {
                            Button("Save changes") { save(startNow: false) }
                                .buttonStyle(PauseButtonStyle(primary: true))
                                .disabled(!canWrite)
                                .keyboardShortcut(.defaultAction)
                        }
                    } else {
                        Button("Continue", action: advance)
                            .buttonStyle(PauseButtonStyle(primary: true))
                            .disabled(!canContinue)
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
            .disabled(isSubmitting || model.isBusy)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var canContinue: Bool {
        switch step {
        case .intention:
            return intention != nil
        case .boundaries:
            let hasName = !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasPendingWebsite = !domainInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return hasName && (hasRules || hasPendingWebsite)
        case .commitment:
            return false
        }
    }

    private var canWrite: Bool {
        model.canChangeBlocks && !isSubmitting && !model.isBusy
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && hasRules
    }

    private var hasRules: Bool {
        !domains.isEmpty || !urlPatterns.isEmpty || !applications.isEmpty || blocksAdultWebsites
    }

    private var hasAddedRules: Bool {
        !addedDomains.isEmpty || !addedURLPatterns.isEmpty || !addedApplications.isEmpty
            || enableAdultWebsites || !domainInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func editorSection<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(PauseFont.display(18, relativeTo: .headline))
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .settingsPanel()
    }

    private func selectIntention(_ option: PlanIntention) {
        guard intention != option else { return }
        let previousSuggestedName = intention?.suggestedName
        if name.isEmpty || name == previousSuggestedName {
            name = option.suggestedName
        }
        intention = option
        validationMessage = nil

        switch option {
        case .focus:
            breakDelay = 300
            fullUnlockDelay = 900
            breakDuration = 300
            hasFixedDuration = true
            fixedDuration = 3_600
        case .lessTime:
            breakDelay = 900
            fullUnlockDelay = 86_400
            breakDuration = 900
            hasFixedDuration = false
            fixedDuration = 86_400
        case .stayAway:
            breakDelay = 86_400
            fullUnlockDelay = 604_800
            breakDuration = 900
            hasFixedDuration = false
            fixedDuration = 86_400
        case .custom:
            breakDelay = 3_600
            fullUnlockDelay = 86_400
            breakDuration = 900
            hasFixedDuration = false
            fixedDuration = 86_400
        }
    }

    private func advance() {
        validationMessage = nil
        switch step {
        case .intention:
            guard intention != nil else {
                validationMessage = "Choose a starting point."
                return
            }
            withAnimation(.easeInOut(duration: 0.18)) { step = .boundaries }
        case .boundaries:
            guard commitPendingWebsite() else { return }
            do {
                _ = try validatedDraft()
                withAnimation(.easeInOut(duration: 0.18)) { step = .commitment }
            } catch {
                validationMessage = planValidationMessage(for: error)
            }
        case .commitment:
            break
        }
    }

    private func goBack() {
        validationMessage = nil
        switch step {
        case .intention:
            break
        case .boundaries:
            if block == nil {
                withAnimation(.easeInOut(duration: 0.18)) { step = .intention }
            }
        case .commitment:
            withAnimation(.easeInOut(duration: 0.18)) { step = .boundaries }
        }
    }

    @discardableResult
    private func addDomain() -> Bool {
        let input = domainInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return true }
        let website: ClassifiedWebsite
        do {
            guard let classified = try classifyWebsite(input) else {
                validationMessage =
                    "Enter a website or pattern such as example.com, example.com/page, or *.example.com."
                return false
            }
            website = classified
        } catch {
            validationMessage = "Website rules are temporarily unavailable. Try again."
            return false
        }
        switch website {
        case .domain(let domain, let wildcard):
            if !domains.contains(domain) {
                domains.append(domain)
                if let wildcard, !urlPatterns.contains(wildcard) {
                    urlPatterns.append(wildcard)
                }
            }
        case .pattern(let pattern):
            if !urlPatterns.contains(pattern) { urlPatterns.append(pattern) }
        }
        domainInput = ""
        validationMessage = nil
        return true
    }

    @discardableResult
    private func addAllowedDomain() -> Bool {
        let input = allowedInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return true }
        do {
            guard let domain = try ProtectedPolicy.normalizeDomainChecked(input),
                !DomainRule.isLiteralIPAddress(domain)
            else {
                validationMessage = "Enter a whole website domain, such as example.com."
                return false
            }
            if !allowedDomains.contains(domain) { allowedDomains.append(domain) }
            allowedInput = ""
            validationMessage = nil
            return true
        } catch {
            validationMessage = "Website rules are temporarily unavailable. Try again."
            return false
        }
    }

    @discardableResult
    private func addActiveWebsite() -> Bool {
        guard let block else { return false }
        let input = domainInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return true }
        let website: ClassifiedWebsite
        do {
            guard let classified = try classifyWebsite(input) else {
                validationMessage =
                    "Enter a website or pattern such as example.com, example.com/page, or *.example.com."
                return false
            }
            website = classified
        } catch {
            validationMessage = "Website rules are temporarily unavailable. Try again."
            return false
        }
        switch website {
        case .domain(let domain, let wildcard):
            if !block.draft.rules.blockedDomains.contains(domain), !addedDomains.contains(domain) {
                addedDomains.append(domain)
            }
            if let wildcard,
                !block.draft.rules.blockedURLPatterns.contains(wildcard),
                !addedURLPatterns.contains(wildcard)
            {
                addedURLPatterns.append(wildcard)
            }
        case .pattern(let pattern):
            if !block.draft.rules.blockedURLPatterns.contains(pattern),
                !addedURLPatterns.contains(pattern)
            {
                addedURLPatterns.append(pattern)
            }
        }
        domainInput = ""
        validationMessage = nil
        return true
    }

    private enum ClassifiedWebsite {
        case domain(String, wildcard: String?)
        case pattern(String)
    }

    private func classifyWebsite(_ input: String) throws -> ClassifiedWebsite? {
        if let domain = try URLPatternRule.exactDomainChecked(from: input) {
            return .domain(domain, wildcard: try URLPatternRule.normalizeChecked("*.\(domain)"))
        }
        return try URLPatternRule.normalizeChecked(input).map(ClassifiedWebsite.pattern)
    }

    private func commitPendingWebsite() -> Bool {
        let input = domainInput.trimmingCharacters(in: .whitespacesAndNewlines)
        return (input.isEmpty || addDomain()) && addAllowedDomain()
    }

    private func addPreset(_ preset: SitePreset) {
        for domain in preset.domains {
            if !domains.contains(domain) {
                domains.append(domain)
            }
            let wildcard = "*.\(domain)"
            if !urlPatterns.contains(wildcard) {
                urlPatterns.append(wildcard)
            }
        }
        validationMessage = nil
    }

    private func validatedDraft() throws -> ProtectedBlockDraft {
        try ProtectedBlockDraft(
            name: name,
            rules: ProtectedRules(
                blockedDomains: domains,
                allowedDomains: allowedDomains,
                blockedApplications: applications,
                blocksStarterAdultSites: false,
                blockedURLPatterns: urlPatterns,
                blocksAdultWebsites: blocksAdultWebsites
            ),
            protectionMode: protectionMode,
            breakDelay: breakDelay,
            fullUnlockDelay: fullUnlockDelay,
            breakDuration: breakDuration,
            elapsedDuration: protectionMode.allowsBreaks && hasFixedDuration ? fixedDuration : nil
        ).validatedForMutation()
    }

    private func planValidationMessage(for error: Error) -> String {
        let message = error.localizedDescription
        return
            message
            .replacingOccurrences(of: "block name", with: "plan name")
            .replacingOccurrences(of: "The block", with: "The plan")
    }

    private func save(startNow: Bool) {
        guard !isReadOnly, !isSubmitting, !model.isBusy else { return }
        guard commitPendingWebsite() else { return }
        do {
            let draft = try validatedDraft()
            isSubmitting = true
            validationMessage = nil
            Task {
                let saved: Bool
                if let block {
                    saved = await model.update(
                        id: block.id,
                        expectedRevision: block.revision,
                        draft: draft
                    )
                } else if startNow {
                    saved = await model.createAndActivate(draft)
                } else {
                    saved = await model.create(draft)
                }
                isSubmitting = false
                if saved { dismiss() }
            }
        } catch {
            validationMessage = planValidationMessage(for: error)
        }
    }

    private func saveAddedRules() {
        guard isReadOnly, !isSubmitting, !model.isBusy, let block else { return }
        guard addActiveWebsite() else { return }
        let current = block.draft
        let rules = current.rules.adding(
            domains: addedDomains,
            urlPatterns: addedURLPatterns,
            applications: addedApplications,
            adultWebsites: enableAdultWebsites
        )
        guard rules != current.rules else {
            validationMessage = "Add at least one new website, application, or adult-site rule."
            return
        }
        do {
            let draft = try ProtectedBlockDraft(
                name: current.name,
                rules: rules,
                protectionMode: current.protectionMode,
                breakDelay: current.breakDelay,
                fullUnlockDelay: current.fullUnlockDelay,
                breakDuration: current.breakDuration,
                elapsedDuration: current.elapsedDuration
            ).validatedForMutation()
            isSubmitting = true
            validationMessage = nil
            Task {
                let saved = await model.update(
                    id: block.id,
                    expectedRevision: block.revision,
                    draft: draft
                )
                isSubmitting = false
                if saved { dismiss() }
            }
        } catch {
            validationMessage = planValidationMessage(for: error)
        }
    }
}

/// Keep large imported plans usable without measuring thousands of rows in a sheet.
private struct PagedPlanRules<Item, Row: View>: View {
    let items: [Item]
    @ViewBuilder let row: (Item) -> Row
    @State private var page = 0
    private let pageSize = 30

    init(_ items: [Item], @ViewBuilder row: @escaping (Item) -> Row) {
        self.items = items
        self.row = row
    }

    private var lastPage: Int { max(0, (items.count - 1) / pageSize) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(items.dropFirst(page * pageSize).prefix(pageSize).enumerated()), id: \.offset) { _, item in
                row(item)
            }
            if items.count > pageSize {
                HStack {
                    Text("\(page * pageSize + 1)–\(min(items.count, (page + 1) * pageSize)) of \(items.count)")
                        .font(.caption)
                        .foregroundStyle(PauseTheme.muted)
                    Spacer()
                    Button("Previous") { page -= 1 }.disabled(page == 0)
                    Button("Next") { page += 1 }.disabled(page >= lastPage)
                }
                .buttonStyle(PauseButtonStyle(compact: true))
            }
        }
        .onChange(of: items.count) { _, _ in page = min(page, lastPage) }
    }
}

private struct PlanWizardStepIndicator: View {
    let steps: [PlanWizardStep]
    let current: PlanWizardStep

    var body: some View {
        HStack(spacing: 16) {
            ForEach(Array(steps.enumerated()), id: \.element) { index, step in
                let isCurrent = step == current
                let isComplete = step.rawValue < current.rawValue
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: isComplete ? "checkmark.circle.fill" : "\(index + 1).circle.fill")
                            .font(.system(size: 18, weight: .medium))
                        Text(step.title)
                            .font(.system(size: 14, weight: isCurrent ? .semibold : .regular))
                    }
                    .foregroundStyle(isCurrent || isComplete ? PauseTheme.ink : PauseTheme.muted)
                    Capsule()
                        .fill(isCurrent || isComplete ? PauseTheme.coral : PauseTheme.stroke.opacity(0.55))
                        .frame(height: 3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Step \(index + 1): \(step.title)")
                .accessibilityValue(isCurrent ? "Current step" : (isComplete ? "Completed" : "Not completed"))
            }
        }
        .padding(.vertical, 8)
    }
}

private enum SitePreset: String, CaseIterable, Identifiable {
    case social = "Social"
    case video = "Video"
    case news = "News"

    var id: String { rawValue }

    var domains: [String] {
        switch self {
        case .social:
            return [
                "facebook.com", "instagram.com", "tiktok.com", "x.com",
            ]
        case .video:
            return [
                "netflix.com", "twitch.tv", "youtube.com",
            ]
        case .news:
            return [
                "cnn.com", "news.google.com", "reddit.com",
            ]
        }
    }
}

private enum DelayValues {
    static let access: [TimeInterval] = [300, 900, 3_600, 21_600, 86_400, 259_200, 604_800]
    static let breaks: [TimeInterval] = [300, 900, 1_800, 3_600]
    static let fixed: [TimeInterval] = [3_600, 21_600, 86_400, 259_200, 604_800]
}

private struct DurationPicker: View {
    let title: String
    @Binding var selection: TimeInterval
    let values: [TimeInterval]

    init(_ title: String, selection: Binding<TimeInterval>, values: [TimeInterval]) {
        self.title = title
        _selection = selection
        self.values = values
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Picker(title, selection: $selection) {
                ForEach(Array(Set(values + [selection])).sorted(), id: \.self) { seconds in
                    Text(seconds.longDuration).tag(seconds)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 170, alignment: .trailing)
            .mascotHoverTarget()
        }
    }
}

private struct WebsiteRuleSummaryRow: View {
    let website: WebsiteRulePresentation

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(website.title).textSelection(.enabled)
            Spacer(minLength: 16)
            if website.includesSubdomains {
                Text("Includes subdomains")
                    .font(.caption)
                    .foregroundStyle(PauseTheme.muted)
            }
        }
    }
}

private struct FixedRulesView: View {
    let draft: ProtectedBlockDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Websites").font(.body.weight(.semibold))
                let websites = WebsiteRulePresentation.rows(
                    domains: draft.rules.allBlockedDomains, patterns: draft.rules.blockedURLPatterns)
                if websites.isEmpty {
                    Text("None").foregroundStyle(PauseTheme.muted)
                }
                if draft.rules.blocksStarterAdultSites {
                    Text("Adult website starter list").foregroundStyle(PauseTheme.muted)
                }
                PagedPlanRules(websites) { website in
                    WebsiteRuleSummaryRow(website: website)
                }
            }
            if !draft.rules.allowedDomains.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Allowed websites").font(.body.weight(.semibold))
                    ForEach(draft.rules.allowedDomains, id: \.self) { domain in
                        Text(domain).foregroundStyle(PauseTheme.muted)
                    }
                }
            }
            Text("Adult websites").font(.body.weight(.semibold)).padding(.top, 4)
            Text(draft.rules.blocksAdultWebsites ? "Block adult websites" : "Do not block adult websites")
                .foregroundStyle(PauseTheme.muted)
            if !draft.rules.blockedApplications.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Applications").font(.body.weight(.semibold))
                    ForEach(draft.rules.blockedApplications) { application in
                        Text(application.displayName).foregroundStyle(PauseTheme.muted)
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                RuleSummaryLine(title: "Plan type", value: draft.protectionMode.displayName)
                if draft.protectionMode.allowsBreaks {
                    RuleSummaryLine(title: "Wait for a break", value: draft.breakDelay.longDuration)
                }
                RuleSummaryLine(title: "Wait to end the plan", value: draft.fullUnlockDelay.longDuration)
                if draft.protectionMode.allowsBreaks {
                    RuleSummaryLine(title: "Break length", value: draft.breakDuration.longDuration)
                    RuleSummaryLine(
                        title: "Ends automatically",
                        value: draft.elapsedDuration?.longDuration ?? "No"
                    )
                }
            }
        }
    }
}

private struct RuleSummaryLine: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer(minLength: 20)
            Text(value)
                .foregroundStyle(PauseTheme.muted)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

private struct RemovableRule: View {
    let title: String
    let symbol: String
    var detail: String? = nil
    var includesSubdomains: Binding<Bool>? = nil
    let remove: () -> Void

    var body: some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).textSelection(.enabled)
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: symbol).foregroundStyle(.secondary)
            }
            Spacer()
            if let includesSubdomains {
                Toggle("Include subdomains", isOn: includesSubdomains)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .fixedSize()
                    .accessibilityLabel("Include subdomains for \(title)")
                    .help("Also block subdomains of \(title)")
                    .mascotHoverTarget()
            }
            Button(action: remove) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .mascotHoverTarget()
                .accessibilityLabel("Remove \(title)")
                .help("Remove \(title)")
        }
    }
}

private struct MandatorySetupView: View {
    @EnvironmentObject private var model: AppModel

    private enum NextStep {
        case service
        case browser(BrowserSetupState)
        case login
        case complete
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    PauseSeed(mood: .resting, size: 82)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Set up Hard Pause")
                            .font(PauseFont.display(26, relativeTo: .title))
                        Text("A few local steps before your first plan.")
                            .foregroundStyle(PauseTheme.muted)
                    }
                }

                if case .checking = model.setupState {
                    ProgressView("Checking local setup…")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                        .background(PauseTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                } else {
                    progressSummary
                    nextStepCard
                    completedRequirements
                }
            }
            .frame(maxWidth: 600, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(LowLightBackground())
        .task { await model.refreshSetup() }
    }

    private var progressSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Getting ready")
                    .font(PauseFont.display(18, relativeTo: .headline))
                Spacer()
                Text("\(completedCount) of 3")
                    .font(.caption)
                    .foregroundStyle(PauseTheme.muted)
            }
            ProgressView(value: Double(completedCount), total: 3)
                .tint(PauseTheme.coral)
        }
    }

    private var nextStepCard: some View {
        Group {
            switch nextStep {
            case .service:
                SetupActionCard(
                    eyebrow: "Step 1 of 3",
                    title: model.needsServiceUpdate ? "Update protection" : "Install protection",
                    detail: model.serviceCanUpdateWithoutApproval
                        ? "Hard Pause can update protection with the approval you gave during setup."
                        : "Hard Pause needs one macOS administrator approval to protect this Mac.",
                    systemImage: "lock.shield",
                    actionTitle: model.needsServiceUpdate ? "Update protection" : "Install protection",
                    isBusy: model.isInstallingService,
                    busyTitle: "Installing protection…"
                ) {
                    Task { await model.installService() }
                }
            case .browser(let browser):
                SetupActionCard(
                    eyebrow: "Step 2 of 3",
                    title: "Allow \(browser.name)",
                    detail: model.browserConnectionMessages[browser.id]
                        ?? "Keep the browser open. Approve the macOS request so Hard Pause can check tab addresses.",
                    systemImage: "globe",
                    actionTitle: "Allow access",
                    isBusy: model.connectingBrowserID != nil,
                    busyTitle: "Waiting for macOS approval…"
                ) {
                    Task { await model.connectBrowser(browser.id) }
                }
            case .login:
                SetupActionCard(
                    eyebrow: "Step 3 of 3",
                    title: "Start at login",
                    detail: "Keep protection available when you sign in to this Mac.",
                    systemImage: "power",
                    actionTitle: "Enable"
                ) {
                    model.enableLoginStart()
                }
            case .complete:
                SetupActionCard(
                    eyebrow: "Ready",
                    title: "Hard Pause is ready",
                    detail: "You can create your first plan now.",
                    systemImage: "checkmark.shield",
                    actionTitle: nil,
                    isBusy: false,
                    busyTitle: nil,
                    action: nil
                )
            }
        }
    }

    private var completedRequirements: some View {
        HStack(spacing: 8) {
            SetupRequirementChip(title: "Protection", isComplete: model.setupServiceReady)
            SetupRequirementChip(title: "Browsers", isComplete: browsersReady)
            SetupRequirementChip(title: "Start at login", isComplete: model.startsAtLogin)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var nextStep: NextStep {
        guard model.setupServiceReady else { return .service }
        if let browser = model.browserReadiness.first(where: { $0.isInstalled && !$0.isReady }) {
            return .browser(browser)
        }
        guard !model.startsAtLogin else { return .complete }
        return .login
    }

    private var browsersReady: Bool {
        model.browserReadiness.allSatisfy(\.isReady)
    }

    private var completedCount: Int {
        [model.setupServiceReady, browsersReady, model.startsAtLogin].filter { $0 }.count
    }
}

private struct SetupActionCard: View {
    let eyebrow: String
    let title: String
    let detail: String
    let systemImage: String
    let actionTitle: String?
    var isBusy = false
    let busyTitle: String?
    let action: (() -> Void)?

    init(
        eyebrow: String,
        title: String,
        detail: String,
        systemImage: String,
        actionTitle: String?,
        isBusy: Bool = false,
        busyTitle: String? = nil,
        action: (() -> Void)?
    ) {
        self.eyebrow = eyebrow
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.actionTitle = actionTitle
        self.isBusy = isBusy
        self.busyTitle = busyTitle
        self.action = action
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(PauseTheme.coral)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 7) {
                Text(eyebrow.uppercased())
                    .font(.caption)
                    .foregroundStyle(PauseTheme.muted)
                Text(title)
                    .font(PauseFont.display(20, relativeTo: .title2))
                Text(detail)
                    .foregroundStyle(PauseTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if isBusy, let busyTitle {
                    ProgressView(busyTitle)
                } else if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .buttonStyle(PauseButtonStyle(primary: true))
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PauseTheme.coral.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(PauseTheme.coral.opacity(0.28), lineWidth: 1)
        }
    }
}

private struct SetupRequirementChip: View {
    let title: String
    let isComplete: Bool

    var body: some View {
        Label(title, systemImage: isComplete ? "checkmark" : "circle")
            .font(.caption)
            .foregroundStyle(isComplete ? PauseTheme.coral : PauseTheme.muted)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(PauseTheme.surface.opacity(0.85), in: Capsule())
    }
}

private struct SetupChecklistView: View {
    @EnvironmentObject private var model: AppModel
    var showsService = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if case .checking = model.setupState {
                ProgressView("Checking local setup…")
            } else {
                if showsService {
                    serviceStep
                }
                browserSteps
                loginStep
            }
        }
        .settingsPanel()
        .task { await model.refreshSetup() }
    }

    private var serviceStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Protection service", systemImage: "lock.shield")
                    .font(PauseFont.display(18, relativeTo: .headline))
                Spacer()
                if model.setupServiceReady {
                    setupReadyLabel
                }
            }
            if !model.setupServiceReady {
                Text(
                    model.serviceCanUpdateWithoutApproval
                        ? "Protection can update with your existing approval."
                        : "One macOS administrator approval is required."
                )
                .foregroundStyle(PauseTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
                if model.isInstallingService {
                    ProgressView("Installing protection…")
                } else {
                    Button(model.needsServiceUpdate ? "Update protection" : "Install protection") {
                        Task { await model.installService() }
                    }
                    .buttonStyle(PauseButtonStyle(primary: true))
                }
            }
        }
    }

    private var browserSteps: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Browser access")
                .font(PauseFont.display(18, relativeTo: .headline))
            ForEach(model.browserReadiness) { browser in
                HStack(alignment: .top, spacing: 10) {
                    Label(browser.name, systemImage: "globe")
                    Spacer()
                    if !browser.isInstalled {
                        Text("Not installed")
                            .font(.caption)
                            .foregroundStyle(PauseTheme.muted)
                    } else if browser.isReady {
                        setupReadyLabel
                    } else {
                        Button("Allow access") {
                            Task { await model.connectBrowser(browser.id) }
                        }
                        .buttonStyle(PauseButtonStyle())
                        .controlSize(.large)
                    }
                }
            }
        }
    }

    private var loginStep: some View {
        HStack(alignment: .top, spacing: 10) {
            Label("Start at login", systemImage: "power")
            Spacer()
            if model.startsAtLogin {
                setupReadyLabel
            } else {
                Button("Enable") { model.enableLoginStart() }
                    .buttonStyle(PauseButtonStyle())
                    .controlSize(.large)
            }
        }
    }

    private var setupReadyLabel: some View {
        Label("Ready", systemImage: "checkmark")
            .foregroundStyle(PauseTheme.coral)
    }
}

private struct ProtectionSettingsPane: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Settings")
                    .font(PauseFont.display(26, relativeTo: .title))
                Text(
                    model.setupReady
                        ? "Everything is ready on this Mac."
                        : model.serviceUpdateIsOnlySetupGap
                            ? "Your active plan is protected. Update protection before starting a new plan."
                            : "Finish setup before starting a new plan."
                )
                .foregroundStyle(PauseTheme.muted)

                SetupChecklistView(showsService: !model.setupServiceReady)

                AppleProtectionCard(model: model.appleProtection)
                    .settingsPanel()

                ScreenTimeWebsitesCard(model: model.appleProtection)
                    .settingsPanel()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Adult website database")
                        .font(PauseFont.display(18, relativeTo: .headline))
                    Text(model.adultDatabaseStatus)
                        .foregroundStyle(PauseTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Update website list") {
                        Task { await model.refreshAdultDatabase() }
                    }
                    .disabled(model.isBusy)
                    ForEach(model.browserReadiness.filter(\.isInstalled)) { browser in
                        if let status = model.browserStatuses[browser.id] {
                            Text("\(browser.name): \(status)")
                                .font(.caption)
                                .foregroundStyle(PauseTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Text(
                        "Chrome and Safari RTA checks need Allow JavaScript from Apple Events. Firefox cannot read RTA labels. Detected pages are cached on this device for 24 hours."
                    )
                    .font(.caption)
                    .foregroundStyle(PauseTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .settingsPanel()

                DisclosureGroup("Developer details") {
                    serviceReadyPanel
                        .padding(.top, 8)
                }
                .settingsPanel()
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var serviceReadyPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Service connected", systemImage: "checkmark.shield.fill")
                .font(PauseFont.display(18, relativeTo: .headline))
                .foregroundStyle(PauseTheme.coral)
            if let protection = model.snapshot?.protection {
                LabeledContent(
                    "Service version",
                    value: protection.releaseVersion.map { "\($0) (\(protection.releaseBuild ?? "?"))" } ?? "Unknown"
                )
                LabeledContent("Active plans", value: "\(model.activeBlocks.count)")
                LabeledContent(
                    "Network and app rules",
                    value: model.snapshot?.effectiveRestrictions.blockedDomains.isEmpty == true
                        && model.snapshot?.effectiveRestrictions.blockedApplications.isEmpty == true
                        ? "None" : (protection.isEnforcing ? "Applied" : "Needs attention")
                )
                if let lastAppliedAt = protection.lastAppliedAt {
                    LabeledContent("Last applied", value: lastAppliedAt.formatted(date: .abbreviated, time: .standard))
                }
                ForEach(protection.issues) { issue in
                    Label(issue.message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if !protection.recentApplicationClosures.isEmpty {
                    Divider()
                    Text("Recent app closures").font(PauseFont.display(18, relativeTo: .headline))
                    ForEach(protection.recentApplicationClosures) { notice in
                        Label {
                            Text(
                                "\(notice.applicationName) · \(notice.blockNames.joined(separator: ", "))"
                            )
                        } icon: {
                            Image(systemName: "xmark.app")
                        }
                    }
                }
            }
            Button("Check service now") { Task { await model.refresh() } }
                .disabled(model.isBusy)
        }
    }
}

private struct ServiceSetupPanel: View {
    var body: some View {
        SetupChecklistView()
    }
}

private struct LowLightBackground: View {
    var body: some View {
        LinearGradient(
            colors: [PauseTheme.background, PauseTheme.surface.opacity(0.62), PauseTheme.background],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

private struct SettingsPanelModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct PauseButtonStyle: ButtonStyle {
    var primary = false
    var compact = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(PauseFont.body(compact ? 12 : 13))
            .foregroundStyle(isEnabled ? (primary ? PauseTheme.background : PauseTheme.ink) : PauseTheme.muted)
            .padding(.horizontal, compact ? 11 : 13)
            .frame(height: compact ? 26 : 32)
            .background(
                (isEnabled && primary ? PauseTheme.coral : PauseTheme.stroke)
                    .opacity(configuration.isPressed ? 0.78 : 1),
                in: Capsule()
            )
            .opacity(isEnabled ? 1 : 0.68)
            .mascotHoverTarget()
    }
}

private struct MascotHoverActionKey: EnvironmentKey {
    static let defaultValue: (CGPoint?) -> Void = { _ in }
}

extension EnvironmentValues {
    fileprivate var mascotHoverChanged: (CGPoint?) -> Void {
        get { self[MascotHoverActionKey.self] }
        set { self[MascotHoverActionKey.self] = newValue }
    }
}

private struct MascotHoverTarget: ViewModifier {
    @Environment(\.mascotHoverChanged) private var hoverChanged
    @Environment(\.isEnabled) private var isEnabled
    // Position changes during scrolling must not invalidate the control's view.
    private final class TrackingState {
        var frame = CGRect.zero
        var isHovering = false
    }
    @State private var tracking = TrackingState()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .global)
            } action: {
                tracking.frame = $0
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    guard isEnabled else { return }
                    tracking.isHovering = true
                    hoverChanged(CGPoint(x: tracking.frame.minX + point.x, y: tracking.frame.minY + point.y))
                case .ended:
                    endHover()
                }
            }
            .onDisappear(perform: endHover)
            .onChange(of: isEnabled) { _, enabled in
                if !enabled { endHover() }
            }
    }

    private func endHover() {
        guard tracking.isHovering else { return }
        tracking.isHovering = false
        hoverChanged(nil)
    }

}

extension View {
    fileprivate func mascotHoverTarget() -> some View { modifier(MascotHoverTarget()) }
    fileprivate func settingsPanel() -> some View { modifier(SettingsPanelModifier()) }
}

extension ProtectedBlockSnapshot {
    fileprivate var ruleSummary: String {
        let sites = WebsiteRulePresentation.rows(
            domains: draft.rules.allBlockedDomains, patterns: draft.rules.blockedURLPatterns
        ).count
        let apps = draft.rules.blockedApplications.count
        return [
            draft.protectionMode.displayName,
            sites > 0 ? "\(sites) site\(sites == 1 ? "" : "s")" : nil,
            apps > 0 ? "\(apps) app\(apps == 1 ? "" : "s")" : nil,
            draft.rules.blocksAdultWebsites ? "Adult websites" : nil,
        ].compactMap { $0 }.joined(separator: " · ")
    }

    fileprivate var activationConfirmation: String {
        var parts = ["Rules stay fixed while this plan is active."]
        if draft.protectionMode.allowsBreaks {
            parts.append(
                "A break requires \(draft.breakDelay.longDuration). Ending the plan requires \(draft.fullUnlockDelay.longDuration)."
            )
        } else {
            parts.append(
                "Hard Pause does not allow breaks. Ending the plan requires \(draft.fullUnlockDelay.longDuration)."
            )
        }
        if !draft.rules.blockedApplications.isEmpty {
            parts.append("Selected apps will close, which can lose unsaved work.")
        }
        if let duration = draft.elapsedDuration {
            parts.append("The plan ends automatically after \(duration.longDuration) of recorded active time.")
        }
        return parts.joined(separator: " ")
    }

    fileprivate var canRequestBreak: Bool {
        draft.protectionMode.allowsBreaks && phase.canRequestBreak
    }

    fileprivate var canCancelBreak: Bool {
        draft.protectionMode.allowsBreaks && phase.canCancelBreak
    }

    fileprivate var canRequestFullEnd: Bool {
        if draft.protectionMode.allowsBreaks { return phase.canRequestFullEnd }
        if case .active = phase { return true }
        return false
    }
}

extension ProtectionMode {
    fileprivate var displayName: String {
        switch self {
        case .softLock: return "Pause"
        case .lockdown: return "Hard Pause"
        }
    }

    fileprivate var shortDetail: String {
        switch self {
        case .softLock: return "Breaks allowed"
        case .lockdown: return "No breaks"
        }
    }

    fileprivate var accessibilityIdentifier: String {
        switch self {
        case .softLock: return "plan-type-pause"
        case .lockdown: return "plan-type-hard-pause"
        }
    }
}

extension ProtectedBlockPhase {
    fileprivate var canRequestBreak: Bool {
        if case .active = self { return true }
        return false
    }

    fileprivate var canRequestFullEnd: Bool {
        if case .breakActive(_, let fullUnlockRemaining, _) = self {
            return fullUnlockRemaining == nil
        }
        return false
    }

    fileprivate var symbol: String {
        switch self {
        case .inactive: return "circle"
        case .active: return "shield.fill"
        case .waitingForBreak, .waitingForFullUnlock: return "hourglass"
        case .breakActive: return "cup.and.saucer.fill"
        }
    }

    fileprivate func statusText(elapsed: TimeInterval) -> String {
        switch self {
        case .inactive:
            return "Ready to start"
        case .active:
            return "Active"
        case .waitingForBreak(let remaining, _):
            return "Break in \(max(0, remaining - elapsed).countdown)"
        case .waitingForFullUnlock(let remaining, _):
            return "Plan ends in \(max(0, remaining - elapsed).countdown)"
        case .breakActive(let remaining, let fullUnlockRemaining, _):
            if let fullUnlockRemaining {
                return "Break active · plan ends in \(max(0, fullUnlockRemaining - elapsed).countdown)"
            }
            return "Break active · \(max(0, remaining - elapsed).countdown) left"
        }
    }

    fileprivate func detailText(elapsed: TimeInterval) -> String? {
        let naturalEnd: TimeInterval?
        switch self {
        case .inactive:
            naturalEnd = nil
        case .active(let remaining),
            .waitingForBreak(_, let remaining),
            .waitingForFullUnlock(_, let remaining),
            .breakActive(_, _, let remaining):
            naturalEnd = remaining
        }
        guard let naturalEnd else { return nil }
        return "Fixed end in \(max(0, naturalEnd - elapsed).countdown)"
    }
}

extension TimeInterval {
    fileprivate var longDuration: String {
        let minutes = max(1, Int(self / 60))
        if minutes.isMultiple(of: 1_440) {
            let days = minutes / 1_440
            return "\(days) day\(days == 1 ? "" : "s")"
        }
        if minutes.isMultiple(of: 60) {
            let hours = minutes / 60
            return "\(hours) hour\(hours == 1 ? "" : "s")"
        }
        return "\(minutes) minute\(minutes == 1 ? "" : "s")"
    }

    fileprivate var countdown: String {
        let seconds = max(0, Int(rounded(.up)))
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainder = seconds % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return String(format: "%dh %02dm", hours, minutes) }
        return String(format: "%dm %02ds", minutes, remainder)
    }
}
