import SwiftUI

private enum WorkspacePane: String, CaseIterable, Identifiable {
    case home = "Home"
    case blocks = "Blocks"
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

    var body: some View {
        Group {
            if shouldShowMandatorySetup {
                MandatorySetupView()
            } else {
                NavigationSplitView {
                    List(WorkspacePane.allCases, selection: $selection) { pane in
                        Label(pane.rawValue, systemImage: pane.symbol)
                            .tag(pane)
                            .padding(.vertical, 4)
                    }
                    .listStyle(.sidebar)
                    .tint(PauseTheme.coral)
                    .navigationTitle("Hard Pause")
                    .navigationSplitViewColumnWidth(min: 180, ideal: 205, max: 240)
                    .safeAreaInset(edge: .bottom) {
                        VStack(spacing: 4) {
                            PauseSeed(
                                mood: sidebarMascotMood,
                                size: 120,
                                attention: mascotAttention(caret: caretPosition, frame: sidebarMascotFrame)
                            )
                            .background(
                                GeometryReader { geometry in
                                    Color.clear.preference(
                                        key: MascotFrameKey.self,
                                        value: geometry.frame(in: .global)
                                    )
                                }
                            )
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
                            ToolbarItemGroup(placement: .primaryAction) {
                                ServiceStatusLabel()
                                    .lineLimit(1)
                                if selection == .blocks {
                                    Button {
                                        editor = BlockEditorPresentation(block: nil)
                                    } label: {
                                        Label("New block", systemImage: "plus")
                                    }
                                    .disabled(!model.canChangeBlocks)
                                    .keyboardShortcut("n", modifiers: .command)
                                }
                            }
                            .sharedBackgroundVisibility(.visible)
                        }
                    }
                }
            }
        }
        .onPreferenceChange(MascotFrameKey.self) { sidebarMascotFrame = $0 }
        .foregroundStyle(PauseTheme.ink)
        .tint(PauseTheme.coral)
        .preferredColorScheme(.dark)
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await model.refresh() }
        }
        .sheet(item: $editor) { presentation in
            BlockEditorView(
                block: presentation.block,
                caretPosition: $caretPosition
            )
            .environmentObject(model)
        }
        .sheet(item: $unlockGuidance) { presentation in
            UnlockGuidanceView(blockID: presentation.id)
                .environmentObject(model)
        }
        .alert(
            "Start \(activationTarget?.draft.name ?? "this block")?",
            isPresented: Binding(
                get: { activationTarget != nil },
                set: { if !$0 { activationTarget = nil } }
            ),
            presenting: activationTarget
        ) { block in
            Button("Cancel", role: .cancel) { activationTarget = nil }
            Button("Start block") {
                activationTarget = nil
                Task { _ = await model.activate(block) }
            }
            .keyboardShortcut(.defaultAction)
        } message: { block in
            Text(block.activationConfirmation)
        }
        .alert(
            "Delete \(deletionTarget?.draft.name ?? "this block")?",
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
            Text("This removes the saved block. This action cannot be undone.")
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
        switch model.setupState {
        case .checking, .incomplete:
            return true
        case .ready:
            return false
        }
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
                if !model.activeBlocks.isEmpty && !model.setupReady {
                    SetupIncompleteBanner(showSetup: showSetup)
                }

                if case .unavailable = model.serviceAvailability {
                    ServiceSetupPanel()
                }

                VStack(alignment: .leading, spacing: 18) {
                    Text(model.activeBlocks.isEmpty ? "No blocks are active." : "Your pause is active.")
                        .font(PauseFont.display(26, relativeTo: .title))
                    Text(
                        model.activeBlocks.isEmpty
                            ? "Open Blocks to create one or start a saved block."
                            : "The controls for your active block are below."
                    )
                    .font(PauseFont.body(16))
                    .foregroundStyle(PauseTheme.muted)

                    if model.activeBlocks.isEmpty && model.serviceAvailability == .ready {
                        Button("Go to Blocks", action: showBlocks)
                            .buttonStyle(PausePrimaryButtonStyle())
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
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(PauseTheme.surface.opacity(0.78), in: RoundedRectangle(cornerRadius: 18))
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
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
            HStack(spacing: 12) {
                if block.phase.canRequestBreak {
                    Button("Request a break") {
                        Task { _ = await model.requestBreak(for: block) }
                    }
                    .buttonStyle(PausePrimaryButtonStyle())
                }
                if block.phase.canRequestFullEnd {
                    Button("Request full end") {
                        Task { _ = await model.requestEnd(for: block) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }
            .controlSize(.large)
            .disabled(!model.canRequestUnlock)
        }
        .padding(14)
        .background(PauseTheme.surface.opacity(0.78), in: RoundedRectangle(cornerRadius: 18))
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
                        .frame(maxWidth: 680)
                        .padding(36)
                }
            case .ready where model.blocks.isEmpty:
                ContentUnavailableView {
                    Label("No blocks", systemImage: "shield.lefthalf.filled")
                } description: {
                    Text("Create a block, choose its rules, and start it when you are ready.")
                } actions: {
                    Button("New block", action: addBlock)
                        .buttonStyle(PausePrimaryButtonStyle())
                }
            case .ready:
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(model.blocks) { block in
                            BlockPanel(
                                block: block,
                                edit: { edit(block) },
                                activate: { activate(block) },
                                delete: { delete(block) },
                                showUnlockGuidance: { showUnlockGuidance(block.id) }
                            )
                        }
                    }
                    .frame(maxWidth: 780)
                    .padding(30)
                    .frame(maxWidth: .infinity, alignment: .top)
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
                    .font(.headline)
                Text(
                    "Your active block and its unlock delays remain in place. Complete the missing setup step when you can."
                )
                .foregroundStyle(PauseTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
                Button("Open setup", action: showSetup)
                    .buttonStyle(PausePrimaryButtonStyle())
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

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(block.draft.name)
                        .font(PauseFont.display(23, relativeTo: .title2))
                    Text(block.phase.statusText(elapsed: model.displayElapsed))
                        .foregroundStyle(block.phase == .inactive ? PauseTheme.muted : PauseTheme.coral)
                }
                Spacer()
                Text(block.ruleSummary)
                    .font(.callout)
                    .foregroundStyle(PauseTheme.muted)
            }

            if block.phase != .inactive {
                BlockStatusPanel(
                    block: block,
                    includesName: false,
                    showUnlockGuidance: showUnlockGuidance
                )
            }

            DisclosureGroup(block.phase == .inactive ? "Review rules" : "View fixed rules") {
                FixedRulesView(draft: block.draft)
                    .padding(.top, 8)
            }

            HStack(spacing: 12) {
                if block.phase == .inactive {
                    Button("Start", action: activate)
                        .buttonStyle(PausePrimaryButtonStyle())
                        .accessibilityLabel("Start \(block.draft.name)")
                    Button("Edit", action: edit)
                        .accessibilityLabel("Edit \(block.draft.name)")
                    Button("Delete", role: .destructive, action: delete)
                        .accessibilityLabel("Delete \(block.draft.name)")
                } else if block.phase.canRequestBreak {
                    Button("Request a break") {
                        Task { _ = await model.requestBreak(for: block) }
                    }
                    .buttonStyle(PausePrimaryButtonStyle())
                    .accessibilityLabel("Request a break from \(block.draft.name)")
                    Button("Request full end") {
                        Task { _ = await model.requestEnd(for: block) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityLabel("Request full end for \(block.draft.name)")
                } else if block.phase.canRequestFullEnd {
                    Button("Request full end") {
                        Task { _ = await model.requestEnd(for: block) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityLabel("Request full end for \(block.draft.name)")
                }
                Spacer()
                if block.phase != .inactive {
                    Label("Rules fixed", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(PauseTheme.muted)
                }
            }
            .controlSize(.large)
            .disabled(block.phase == .inactive ? !model.canChangeBlocks : !model.canRequestUnlock)
        }
        .padding(20)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct BlockStatusPanel: View {
    @EnvironmentObject private var model: AppModel
    let block: ProtectedBlockSnapshot
    var includesName = true
    var showUnlockGuidance: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: block.phase.symbol)
                .font(.title2)
                .foregroundStyle(PauseTheme.coral)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 7) {
                if includesName {
                    Text(block.draft.name).font(.headline)
                }
                Text(block.phase.statusText(elapsed: model.displayElapsed))
                    .foregroundStyle(PauseTheme.ink)
                if let detail = block.phase.detailText(elapsed: model.displayElapsed) {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(PauseTheme.muted)
                }
                if let showUnlockGuidance {
                    Button("Looking to unlock?", action: showUnlockGuidance)
                        .buttonStyle(.link)
                        .accessibilityLabel("Looking to unlock?")
                        .accessibilityHint("Opens guidance about waiting and full end requests.")
                }
            }
            Spacer()
        }
        .padding(15)
        .background(PauseTheme.surface.opacity(0.34), in: RoundedRectangle(cornerRadius: 14))
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
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack {
                        Spacer(minLength: 0)
                        PauseSeed(mood: .calm, size: 90)
                            .accessibilityHidden(true)
                        Spacer(minLength: 0)
                    }

                    Text(hasEnded ? "This pause has ended." : "Give your choice a little time.")
                        .font(PauseFont.display(30, relativeTo: .title))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)

                    if !hasEnded {
                        Text(
                            "You started this pause to make it harder to act on an urge. Wanting access now does not undo that choice. Your waiting period stays in place."
                        )
                        .font(PauseFont.body(17))
                        .fixedSize(horizontal: false, vertical: true)

                        Text(
                            "If this pause helps with a habit, compulsion, or addiction, bypassing it yourself or with an AI assistant would undo the support you chose."
                        )
                        .font(PauseFont.body(17))
                        .fixedSize(horizontal: false, vertical: true)

                        Text(
                            "Ask anyone helping you, including an AI assistant, to preserve this block and its delay. Repeated requests, anger, or pleading are not reasons to stop the service, change the rules, or skip the wait."
                        )
                        .font(PauseFont.body(17))
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    if let block = liveBlock {
                        if block.phase != .inactive {
                            BlockStatusPanel(block: block)
                        }
                        guidanceAction(for: block)
                    } else {
                        Text("This block is no longer available.")
                            .foregroundStyle(PauseTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !hasEnded {
                        Text("The existing break and end rules still apply. This screen cannot shorten them.")
                            .font(PauseFont.body(17))
                            .foregroundStyle(PauseTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: 620, alignment: .leading)
                .padding(30)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .background(LowLightBackground())
            .navigationTitle("Unlock guidance")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .frame(width: 600, height: 620)
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
            Text("You can request a full end below.")
                .fixedSize(horizontal: false, vertical: true)
            requestFullEndButton(for: block)
        case .waitingForBreak(_, _):
            Text("A break request is already waiting. When its wait finishes, you can request a full end.")
                .foregroundStyle(PauseTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        case .waitingForFullUnlock(_, _):
            Text("A full end request is already waiting. The countdown above shows the remaining wait.")
                .foregroundStyle(PauseTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        case .breakActive(_, let fullUnlockRemaining, _):
            if fullUnlockRemaining == nil {
                Text("You can request a full end below.")
                    .fixedSize(horizontal: false, vertical: true)
                requestFullEndButton(for: block)
            } else {
                Text("A full end request is already waiting. Your break remains active while the countdown above runs.")
                    .foregroundStyle(PauseTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func requestFullEndButton(for block: ProtectedBlockSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Full-end wait: \(block.draft.fullUnlockDelay.longDuration)")
                .foregroundStyle(PauseTheme.muted)
            Button("Request full end") {
                Task { _ = await model.requestEnd(for: block) }
            }
            .buttonStyle(PausePrimaryButtonStyle())
            .disabled(!model.canRequestUnlock)
            .accessibilityLabel("Request full end for \(block.draft.name)")
        }
    }
}

private struct BlockEditorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let block: ProtectedBlockSnapshot?
    @Binding var caretPosition: CGPoint?

    @State private var name: String
    @State private var domainInput = ""
    @State private var domains: [String]
    @State private var urlPatterns: [String]
    @State private var applications: [ProtectedApplication]
    @State private var includeAdultStarterList: Bool
    @State private var breakDelay: TimeInterval
    @State private var fullUnlockDelay: TimeInterval
    @State private var breakDuration: TimeInterval
    @State private var hasFixedDuration: Bool
    @State private var fixedDuration: TimeInterval
    @State private var validationMessage: String?

    init(block: ProtectedBlockSnapshot?, caretPosition: Binding<CGPoint?>) {
        self.block = block
        _caretPosition = caretPosition
        let draft = block?.draft
        _name = State(initialValue: draft?.name ?? "")
        _domains = State(initialValue: draft?.rules.blockedDomains ?? [])
        _urlPatterns = State(initialValue: draft?.rules.blockedURLPatterns ?? [])
        _applications = State(initialValue: draft?.rules.blockedApplications ?? [])
        _includeAdultStarterList = State(initialValue: draft?.rules.blocksStarterAdultSites ?? false)
        _breakDelay = State(initialValue: draft?.breakDelay ?? 3_600)
        _fullUnlockDelay = State(initialValue: draft?.fullUnlockDelay ?? 86_400)
        _breakDuration = State(initialValue: draft?.breakDuration ?? 900)
        _hasFixedDuration = State(initialValue: draft?.elapsedDuration != nil)
        _fixedDuration = State(initialValue: draft?.elapsedDuration ?? 86_400)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    CaretTrackingTextField(
                        "Block name",
                        text: $name,
                        accessibilityLabel: "Block name",
                        inputMode: .name,
                        onSubmit: save,
                        onCaretChange: { caretPosition = $0 }
                    )
                }

                Section {
                    HStack {
                        CaretTrackingTextField(
                            "example.com, *.xxx, or *.reddit.com/r/example",
                            text: $domainInput,
                            onSubmit: addDomain,
                            onCaretChange: { caretPosition = $0 }
                        )
                        Button("Add", action: addDomain)
                            .disabled(domainInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if !domains.isEmpty {
                        ForEach(domains, id: \.self) { domain in
                            RemovableRule(title: domain, symbol: "globe") {
                                domains.removeAll { $0 == domain }
                            }
                        }
                    }
                    ForEach(urlPatterns, id: \.self) { pattern in
                        RemovableRule(title: pattern, symbol: "link") {
                            urlPatterns.removeAll { $0 == pattern }
                        }
                    }
                    HStack(spacing: 8) {
                        Text("Quick add:").foregroundStyle(.secondary)
                        ForEach(SitePreset.allCases) { preset in
                            Button(preset.rawValue) { addPreset(preset) }
                                .buttonStyle(.bordered)
                        }
                    }
                } header: {
                    Text("Websites and IP addresses")
                } footer: {
                    Text(
                        "Add a whole site, a page path, or a * pattern. Connect your browsers in Settings to enable page redirects."
                    )
                }

                Section {
                    ForEach(applications) { application in
                        RemovableRule(
                            title: application.displayName,
                            symbol: "app",
                            detail: application.bundleIdentifier
                        ) {
                            applications.removeAll { $0.id == application.id }
                        }
                    }
                    Button("Add applications…") {
                        Task {
                            let selected = await model.chooseApplications()
                            for application in selected
                            where !applications.contains(where: { $0.id == application.id }) {
                                applications.append(application)
                            }
                        }
                    }
                } header: {
                    Text("Applications")
                } footer: {
                    Text("Hard Pause closes selected apps while this block is active. Unsaved work can be lost.")
                }

                Section {
                    Toggle("Adult website starter list", isOn: $includeAdultStarterList)
                } footer: {
                    Text("This small local list is incomplete. It is not automatic website classification.")
                }

                Section("Access delays") {
                    DurationPicker("Wait for a break", selection: $breakDelay, values: DelayValues.access)
                    DurationPicker(
                        "Wait for full end",
                        selection: $fullUnlockDelay,
                        values: DelayValues.access
                    )
                    DurationPicker("Break length", selection: $breakDuration, values: DelayValues.breaks)
                }

                Section {
                    Toggle("End after a fixed duration", isOn: $hasFixedDuration)
                    if hasFixedDuration {
                        DurationPicker(
                            "Active duration",
                            selection: $fixedDuration,
                            values: DelayValues.fixed
                        )
                    }
                } footer: {
                    Text("With no fixed duration, the block continues until a full-end request finishes.")
                }

                if let validationMessage {
                    Section {
                        Label(validationMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(LowLightBackground())
            .navigationTitle(block == nil ? "New block" : "Edit block")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .buttonStyle(PausePrimaryButtonStyle())
                        .disabled(!model.canChangeBlocks)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
        .frame(minWidth: 620, idealWidth: 680, minHeight: 650, idealHeight: 760)
        .onDisappear { caretPosition = nil }
    }

    private func addDomain() {
        let input = domainInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if let domain = URLPatternRule.exactDomain(from: input) {
            if !domains.contains(domain) { domains.append(domain) }
        } else if let pattern = URLPatternRule.normalize(input) {
            if !urlPatterns.contains(pattern) { urlPatterns.append(pattern) }
        } else {
            validationMessage =
                "Enter a domain, IP address, or website pattern such as *.reddit.com/r/example or *.xxx."
            return
        }
        domainInput = ""
        validationMessage = nil
    }

    private func addPreset(_ preset: SitePreset) {
        for domain in preset.domains where !domains.contains(domain) {
            domains.append(domain)
        }
    }

    private func save() {
        do {
            let draft = try ProtectedBlockDraft(
                name: name,
                rules: ProtectedRules(
                    blockedDomains: domains,
                    blockedApplications: applications,
                    blocksStarterAdultSites: includeAdultStarterList,
                    blockedURLPatterns: urlPatterns
                ),
                breakDelay: breakDelay,
                fullUnlockDelay: fullUnlockDelay,
                breakDuration: breakDuration,
                elapsedDuration: hasFixedDuration ? fixedDuration : nil
            ).validatedForMutation()
            Task {
                let saved: Bool
                if let block {
                    saved = await model.update(
                        id: block.id,
                        expectedRevision: block.revision,
                        draft: draft
                    )
                } else {
                    saved = await model.create(draft)
                }
                if saved { dismiss() }
            }
        } catch {
            validationMessage = error.localizedDescription
        }
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
                "facebook.com", "www.facebook.com",
                "instagram.com", "www.instagram.com",
                "tiktok.com", "www.tiktok.com",
                "x.com", "www.x.com",
            ]
        case .video:
            return [
                "netflix.com", "www.netflix.com",
                "twitch.tv", "www.twitch.tv",
                "youtube.com", "www.youtube.com",
            ]
        case .news:
            return [
                "cnn.com", "www.cnn.com",
                "news.google.com",
                "reddit.com", "www.reddit.com",
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
        Picker(title, selection: $selection) {
            ForEach(values, id: \.self) { seconds in
                Text(seconds.longDuration).tag(seconds)
            }
        }
    }
}

private struct FixedRulesView: View {
    let draft: ProtectedBlockDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RuleSummaryLine(
                title: "Websites",
                value: (draft.rules.blockedDomains + draft.rules.blockedURLPatterns).isEmpty
                    ? "None" : (draft.rules.blockedDomains + draft.rules.blockedURLPatterns).joined(separator: ", ")
            )
            RuleSummaryLine(
                title: "Applications",
                value: draft.rules.blockedApplications.isEmpty
                    ? "None" : draft.rules.blockedApplications.map(\.displayName).joined(separator: ", ")
            )
            RuleSummaryLine(
                title: "Adult list",
                value: draft.rules.blocksStarterAdultSites ? "Included" : "Not included"
            )
            RuleSummaryLine(title: "Break wait", value: draft.breakDelay.longDuration)
            RuleSummaryLine(title: "Full-end wait", value: draft.fullUnlockDelay.longDuration)
            RuleSummaryLine(title: "Break length", value: draft.breakDuration.longDuration)
            RuleSummaryLine(
                title: "Fixed duration",
                value: draft.elapsedDuration?.longDuration ?? "No fixed duration"
            )
        }
    }
}

private struct RuleSummaryLine: View {
    let title: String
    let value: String

    var body: some View {
        LabeledContent(title) {
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
            Button(action: remove) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
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
                        Text("A few local steps before your first block.")
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
                    .font(.headline)
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
                    title: "Install protection",
                    detail: "Hard Pause needs one macOS administrator approval to protect this Mac.",
                    systemImage: "lock.shield",
                    actionTitle: "Install protection",
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
                    detail: "You can create your first block now.",
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
                    .font(PauseFont.display(23, relativeTo: .title2))
                Text(detail)
                    .foregroundStyle(PauseTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if isBusy, let busyTitle {
                    ProgressView(busyTitle)
                } else if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .buttonStyle(PausePrimaryButtonStyle())
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
                    .font(.headline)
                Spacer()
                if model.setupServiceReady {
                    setupReadyLabel
                }
            }
            if !model.setupServiceReady {
                Text("One macOS administrator approval is required.")
                    .foregroundStyle(PauseTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if model.isInstallingService {
                    ProgressView("Installing protection…")
                } else {
                    Button("Install protection") {
                        Task { await model.installService() }
                    }
                    .buttonStyle(PausePrimaryButtonStyle())
                }
            }
        }
    }

    private var browserSteps: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Browser access")
                .font(.headline)
            ForEach(model.browserReadiness) { browser in
                HStack(alignment: .top, spacing: 10) {
                    Label(browser.name, systemImage: "globe")
                    Spacer()
                    if !browser.isInstalled {
                        Text("Not installed")
                            .font(.caption)
                            .foregroundStyle(PauseTheme.muted)
                    } else if browser.permission == .previouslyGranted {
                        Text("Browser closed · previously approved")
                            .font(.caption)
                            .foregroundStyle(PauseTheme.muted)
                    } else if browser.isReady {
                        setupReadyLabel
                    } else {
                        Button("Allow access") {
                            Task { await model.connectBrowser(browser.id) }
                        }
                        .buttonStyle(.bordered)
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
                    .buttonStyle(.bordered)
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
            VStack(alignment: .leading, spacing: 14) {
                Text("Protection")
                    .font(PauseFont.display(28, relativeTo: .title))
                Text(
                    model.setupReady ? "Everything is ready on this Mac." : "Finish setup before starting a new block."
                )
                .foregroundStyle(PauseTheme.muted)

                SetupChecklistView(showsService: !model.setupServiceReady)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Private by design").font(.headline)
                    Label(
                        "Rules and protection state stay on this Mac.",
                        systemImage: "lock.shield"
                    )
                    Label(
                        "Browser checks read tab addresses only when page protection is active.",
                        systemImage: "eye.slash"
                    )
                    Label(
                        "Hard Pause does not use an account, hosted service, telemetry, or browsing-history log.",
                        systemImage: "antenna.radiowaves.left.and.right.slash"
                    )
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
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private var serviceReadyPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Service connected", systemImage: "checkmark.shield.fill")
                .font(.headline)
                .foregroundStyle(PauseTheme.coral)
            if let protection = model.snapshot?.protection {
                LabeledContent("Service version", value: protection.serviceVersion)
                LabeledContent("Active blocks", value: "\(model.activeBlocks.count)")
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
                    Text("Recent app closures").font(.headline)
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
        .settingsPanel()
    }
}

private struct ServiceSetupPanel: View {
    var body: some View {
        SetupChecklistView()
    }
}

private struct ServiceStatusLabel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        switch model.setupState {
        case .checking:
            Label("Checking setup", systemImage: "ellipsis.circle")
                .foregroundStyle(PauseTheme.muted)
        case .incomplete:
            Label("Finish setup", systemImage: "exclamationmark.shield")
                .foregroundStyle(PauseTheme.coral)
        case .ready:
            if let protection = model.snapshot?.protection,
                !protection.issues.isEmpty || (!protection.isEnforcing && !model.activeBlocks.isEmpty)
            {
                Label("Protection needs attention", systemImage: "exclamationmark.shield")
                    .foregroundStyle(.orange)
            }
        }
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

private struct PausePrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(PauseFont.body(15))
            .foregroundStyle(isEnabled ? PauseTheme.background : PauseTheme.muted)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(minHeight: 38)
            .background(
                (isEnabled ? PauseTheme.coral : PauseTheme.stroke)
                    .opacity(configuration.isPressed ? 0.78 : 1),
                in: Capsule()
            )
            .opacity(isEnabled ? 1 : 0.68)
    }
}

extension View {
    fileprivate func settingsPanel() -> some View { modifier(SettingsPanelModifier()) }
}

extension ProtectedBlockSnapshot {
    fileprivate var ruleSummary: String {
        let sites =
            draft.rules.blockedDomains.count + draft.rules.blockedAdultDomains.count
            + draft.rules.blockedURLPatterns.count
        let apps = draft.rules.blockedApplications.count
        return "\(sites) site\(sites == 1 ? "" : "s") · \(apps) app\(apps == 1 ? "" : "s")"
    }

    fileprivate var activationConfirmation: String {
        var parts = [
            "Rules stay fixed while this block is active.",
            "A break requires \(draft.breakDelay.longDuration). A full end requires \(draft.fullUnlockDelay.longDuration).",
        ]
        if !draft.rules.blockedApplications.isEmpty {
            parts.append("Selected apps will close, which can lose unsaved work.")
        }
        if let duration = draft.elapsedDuration {
            parts.append("The block ends automatically after \(duration.longDuration) of recorded active time.")
        }
        return parts.joined(separator: " ")
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
            return "Full end in \(max(0, remaining - elapsed).countdown)"
        case .breakActive(let remaining, let fullUnlockRemaining, _):
            if let fullUnlockRemaining {
                return "Break active · full end in \(max(0, fullUnlockRemaining - elapsed).countdown)"
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
