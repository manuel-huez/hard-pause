import FamilyControls
import SwiftUI

struct PlanEditorPresentation: Identifiable {
    let id = UUID()
    let blockID: UUID?
}

private enum PlanEditorStep: Int, CaseIterable, Hashable {
    case intention
    case boundaries
    case commitment

    var title: String {
        switch self {
        case .intention: "Intention"
        case .boundaries: "Boundaries"
        case .commitment: "Commitment"
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
        case .focus: "Focus for a while"
        case .lessTime: "Spend less time"
        case .stayAway: "Stay away"
        case .custom: "Set it up myself"
        }
    }

    var detail: String {
        switch self {
        case .focus: "A one-hour plan with the shortest iOS waiting periods."
        case .lessTime: "An ongoing plan with a one-day wait before it can end."
        case .stayAway: "An ongoing plan with a one-week wait before it can end."
        case .custom: "Choose the rules and waiting periods yourself."
        }
    }

    var symbol: String {
        switch self {
        case .focus: "scope"
        case .lessTime: "clock.arrow.circlepath"
        case .stayAway: "shield.lefthalf.filled"
        case .custom: "slider.horizontal.3"
        }
    }

    var suggestedName: String {
        switch self {
        case .focus: "Focus time"
        case .lessTime: "Less time"
        case .stayAway: "Stay away"
        case .custom: ""
        }
    }
}

private enum IOSSitePreset: String, CaseIterable, Identifiable {
    case social = "Social"
    case video = "Video"
    case news = "News"

    var id: String { rawValue }

    var domains: [String] {
        switch self {
        case .social: ["facebook.com", "instagram.com", "tiktok.com", "x.com"]
        case .video: ["netflix.com", "twitch.tv", "youtube.com"]
        case .news: ["cnn.com", "news.google.com", "reddit.com"]
        }
    }
}

struct PlanEditorView: View {
    @ObservedObject var controller: LockController
    let presentation: PlanEditorPresentation

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var step: PlanEditorStep
    @State private var intention: PlanIntention?
    @State private var name: String
    @State private var policy: LockPolicy
    @State private var domainInput = ""
    @State private var showsPicker = false
    @State private var validationMessage: String?
    @State private var confirmsStart = false

    private let waitOptions: [TimeInterval] = [3_600, 14_400, 86_400, 259_200, 604_800]
    private let breakOptions: [TimeInterval] = [900, 1_800, 3_600, 7_200]
    private let fixedDurationOptions: [TimeInterval?] = [nil, 3_600, 14_400, 86_400, 259_200, 604_800]

    init(controller: LockController, presentation: PlanEditorPresentation) {
        self.controller = controller
        self.presentation = presentation
        let block = presentation.blockID.flatMap(controller.collection.block)
        _step = State(initialValue: block == nil ? .intention : .boundaries)
        _intention = State(initialValue: nil)
        _name = State(initialValue: block?.name ?? "")
        var initialPolicy = block?.draftPolicy ?? LockPolicy()
        if block == nil {
            initialPolicy.blocksAdultWebsites = true
            initialPolicy.preventsAppRemoval = true
            initialPolicy.requiresAutomaticDateAndTime = true
        }
        _policy = State(initialValue: initialPolicy)
    }

    private var isEditing: Bool { presentation.blockID != nil }

    private var availableSteps: [PlanEditorStep] {
        isEditing ? [.boundaries, .commitment] : PlanEditorStep.allCases
    }

    var body: some View {
        NavigationStack {
            ZStack {
                PauseTheme.background.ignoresSafeArea()
                VStack(spacing: 0) {
                    editorHeader
                    stepIndicator
                    Divider().overlay(PauseTheme.stroke)
                    ScrollView {
                        Group {
                            switch step {
                            case .intention: intentionStep
                            case .boundaries: boundariesStep
                            case .commitment: commitmentStep
                            }
                        }
                        .frame(maxWidth: 620)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 18)
                    }
                    Divider().overlay(PauseTheme.stroke)
                    footer
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .font(PauseFont.body(17, relativeTo: .headline))
                        .accessibilityIdentifier("editor.cancel")
                }
            }
        }
        .interactiveDismissDisabled(false)
        .foregroundStyle(PauseTheme.ink)
        .tint(PauseTheme.coral)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showsPicker) {
            NavigationStack {
                FamilyActivityPicker(
                    headerText: "Choose what this plan blocks",
                    footerText: "Your choices stay on this device.",
                    selection: $policy.selection
                )
                .navigationTitle("Apps & websites")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showsPicker = false }
                            .font(PauseFont.body(17, relativeTo: .headline))
                    }
                }
            }
        }
        .alert("Start \(displayName)?", isPresented: $confirmsStart) {
            Button("Keep editing", role: .cancel) {}
            Button("Start plan") { save(startNow: true) }
        } message: {
            Text(activationConfirmation)
        }
    }

    private var editorHeader: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(isEditing ? "Edit plan" : "Create a plan")
                    .font(PauseFont.display(29))
                    .accessibilityIdentifier("editor.screen")
                Text(headerDetail)
                    .font(.subheadline)
                    .foregroundStyle(PauseTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if !dynamicTypeSize.isAccessibilitySize {
                PauseSeed(mood: .resting, size: 86)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var headerDetail: String {
        switch step {
        case .intention: "Start with a suggestion that fits what you want to change."
        case .boundaries: "Name the plan and choose the apps and websites it will block."
        case .commitment: "Review the fixed rules and choose when access can return."
        }
    }

    private var stepIndicator: some View {
        HStack(spacing: 8) {
            ForEach(availableSteps, id: \.self) { item in
                VStack(spacing: 5) {
                    Capsule()
                        .fill(item.rawValue <= step.rawValue ? PauseTheme.coral : PauseTheme.stroke)
                        .frame(height: 4)
                    Text(item.title)
                        .font(.caption2)
                        .foregroundStyle(item == step ? PauseTheme.ink : PauseTheme.muted)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(item.title) step")
                .accessibilityValue(item == step ? "Current" : "")
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private var intentionStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What would you like help with?")
                .font(PauseFont.display(22, relativeTo: .title2))
            Text("Each choice is a starting point. You can change every setting before the plan starts.")
                .foregroundStyle(PauseTheme.muted)
            ForEach(PlanIntention.allCases) { option in
                Button {
                    selectIntention(option)
                } label: {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: option.symbol)
                            .font(.title2)
                            .foregroundStyle(PauseTheme.coral)
                            .frame(width: 30)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(option.title).font(PauseFont.body(17, relativeTo: .headline))
                            Text(option.detail)
                                .font(.subheadline)
                                .foregroundStyle(PauseTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: intention == option ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(intention == option ? PauseTheme.coral : PauseTheme.muted)
                    }
                    .padding(16)
                    .background(intention == option ? PauseTheme.surface : PauseTheme.surface.opacity(0.55))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(
                                intention == option ? PauseTheme.coral.opacity(0.7) : PauseTheme.stroke, lineWidth: 1)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityValue(intention == option ? "Selected" : "Not selected")
                .accessibilityIdentifier("editor.intention.\(option.rawValue)")
            }
        }
    }

    private var boundariesStep: some View {
        VStack(spacing: 16) {
            editorSection(icon: "character.cursor.ibeam", title: "Plan name") {
                TextField("e.g. Focus time", text: $name)
                    .textInputAutocapitalization(.sentences)
                    .padding(13)
                    .background(PauseTheme.background)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityIdentifier("editor.name")
            }

            editorSection(icon: "app.badge.checkmark", title: "Apps & websites") {
                Button {
                    showsPicker = true
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Choose with Screen Time").font(PauseFont.body(17, relativeTo: .headline))
                            Text(selectionSummary)
                                .font(.subheadline)
                                .foregroundStyle(PauseTheme.muted)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                    .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
            }

            editorSection(icon: "globe", title: "Website domains") {
                HStack(spacing: 10) {
                    TextField("example.com", text: $domainInput)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .onSubmit(addDomain)
                        .padding(13)
                        .background(PauseTheme.background)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    Button("Add", action: addDomain)
                        .font(PauseFont.body(16, relativeTo: .headline))
                        .frame(minWidth: 52, minHeight: 44)
                        .disabled(domainInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("Add whole domains. Apple’s Screen Time APIs do not expose path-level website rules here.")
                    .font(.caption)
                    .foregroundStyle(PauseTheme.muted)
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        Text("Quick add").font(.caption).foregroundStyle(PauseTheme.muted)
                        ForEach(IOSSitePreset.allCases) { preset in
                            Button(preset.rawValue) { addPreset(preset) }
                                .buttonStyle(.glass)
                                .font(PauseFont.body(15, relativeTo: .headline))
                        }
                    }
                }
                if !policy.manualDomains.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(policy.manualDomains, id: \.self) { domain in
                            HStack(spacing: 10) {
                                Image(systemName: "globe")
                                    .foregroundStyle(PauseTheme.muted)
                                Text(domain)
                                Spacer()
                                Button {
                                    policy.manualDomains.removeAll { $0 == domain }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .accessibilityLabel("Remove \(domain)")
                                .frame(minWidth: 44, minHeight: 44)
                            }
                            if domain != policy.manualDomains.last {
                                Divider().overlay(PauseTheme.stroke)
                            }
                        }
                    }
                }
            }

            editorSection(icon: "safari.fill", title: "Adult websites") {
                Toggle("Block adult websites", isOn: $policy.blocksAdultWebsites)
                Text("Uses Apple’s automatic web filter. Apple controls its classification and coverage.")
                    .font(.caption)
                    .foregroundStyle(PauseTheme.muted)
            }
        }
    }

    private var commitmentStep: some View {
        VStack(spacing: 16) {
            editorSection(icon: "list.bullet", title: displayName) {
                StatusLine(label: "Mode", value: policy.protectionMode.displayName)
                StatusLine(label: "Screen Time selections", value: "\(screenTimeSelectionCount)")
                StatusLine(label: "Website domains", value: "\(policy.manualDomains.count)")
                StatusLine(label: "Adult website filter", value: policy.blocksAdultWebsites ? "On" : "Off")
            }

            editorSection(icon: "shield.lefthalf.filled", title: "Protection mode") {
                ForEach(ProtectionMode.allCases, id: \.self) { mode in
                    Button {
                        selectProtectionMode(mode)
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: mode.systemImage)
                                .font(.title3)
                                .foregroundStyle(PauseTheme.coral)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(mode.displayName)
                                    .font(PauseFont.body(17, relativeTo: .headline))
                                Text(mode.detail)
                                    .font(.caption)
                                    .foregroundStyle(PauseTheme.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: policy.protectionMode == mode ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(policy.protectionMode == mode ? PauseTheme.coral : PauseTheme.muted)
                        }
                        .padding(14)
                        .background(
                            policy.protectionMode == mode ? PauseTheme.background : PauseTheme.background.opacity(0.45)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(policy.protectionMode == mode ? "Selected" : "Not selected")
                    .accessibilityIdentifier("editor.mode.\(mode.rawValue)")
                }
            }

            editorSection(
                icon: "timer",
                title: "Waiting periods",
                accessibilityIdentifier: "editor.waitingPeriods"
            ) {
                if policy.protectionMode.allowsBreaks {
                    DurationOptionPicker(
                        title: "Wait for a break",
                        detail: "Blocking continues during this wait",
                        selection: $policy.waitDuration,
                        options: waitOptions
                    )
                    .accessibilityIdentifier("editor.breakWait")
                    Divider().overlay(PauseTheme.stroke)
                    DurationOptionPicker(
                        title: "Break length",
                        detail: "Blocking returns automatically",
                        selection: $policy.breakDuration,
                        options: breakOptions
                    )
                    .accessibilityIdentifier("editor.breakLength")
                    Divider().overlay(PauseTheme.stroke)
                } else {
                    Label("Hard Pause has no breaks or automatic end.", systemImage: "hand.raised.fill")
                        .font(.subheadline)
                        .foregroundStyle(PauseTheme.coral)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider().overlay(PauseTheme.stroke)
                }
                DurationOptionPicker(
                    title: "Wait to end the plan",
                    detail: "Blocking continues during this wait",
                    selection: fullUnlockDelay,
                    options: waitOptions
                )
                .accessibilityIdentifier("editor.fullUnlockWait")
                if policy.protectionMode.allowsBreaks {
                    Divider().overlay(PauseTheme.stroke)
                    OptionalDurationOptionPicker(
                        title: "Plan duration",
                        detail: "Optional automatic end using recorded active time",
                        selection: $policy.fixedDuration,
                        options: fixedDurationOptions
                    )
                    .accessibilityIdentifier("editor.fixedDuration")
                }
                Text("Time while this device is off does not reduce these waits.")
                    .font(.caption)
                    .foregroundStyle(PauseTheme.muted)
            }

            editorSection(
                icon: "shield.lefthalf.filled",
                title: "Device protection",
                accessibilityIdentifier: "editor.deviceProtection"
            ) {
                if policy.protectionMode == .lockdown {
                    StatusLine(label: "App deletion", value: "Prevented device-wide")
                    Divider().overlay(PauseTheme.stroke)
                    StatusLine(label: "Automatic date & time", value: "Required")
                    Text("Hard Pause fixes both device settings until the full unlock wait finishes.")
                        .font(.caption)
                        .foregroundStyle(PauseTheme.muted)
                } else {
                    Toggle(isOn: $policy.preventsAppRemoval) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Prevent app deletion")
                            Text(
                                "While this plan is active, iOS prevents deletion of every app on this device. This plan keeps the setting on during a break and releases it after the plan ends."
                            )
                            .font(.caption)
                            .foregroundStyle(PauseTheme.muted)
                        }
                    }
                    .accessibilityIdentifier("editor.preventAppRemoval")
                    Divider().overlay(PauseTheme.stroke)
                    Toggle(isOn: $policy.requiresAutomaticDateAndTime) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Require automatic date & time")
                            Text(
                                "While this plan is active, iOS requires automatic date and time for the whole device."
                            )
                            .font(.caption)
                            .foregroundStyle(PauseTheme.muted)
                        }
                    }
                    .accessibilityIdentifier("editor.requireAutomaticTime")
                    Text("These choices become fixed when the plan starts.")
                        .font(.caption)
                        .foregroundStyle(PauseTheme.muted)
                }
            }

            editorSection(icon: "exclamationmark.shield.fill", title: "Screen Time permission protection") {
                Label("Not verified by this iPhone app", systemImage: "questionmark.circle")
                    .foregroundStyle(.orange)
                Text(
                    "This iPhone app cannot set or verify the protection code. Complete the separate Mac setup, then verify the protection on this iPhone."
                )
                .font(.caption)
                .foregroundStyle(PauseTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityIdentifier("editor.permissionProtectionStatus")

            Label(
                "Starting fixes these rules and waiting periods until the plan ends.",
                systemImage: "lock.fill"
            )
            .font(.subheadline)
            .foregroundStyle(PauseTheme.coral)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                if step != availableSteps.first {
                    Button("Back", action: goBack)
                        .buttonStyle(.glass)
                        .font(PauseFont.body(17, relativeTo: .headline))
                }
                Spacer()
                if step == .commitment {
                    if isEditing {
                        Button("Save changes") { save(startNow: false) }
                            .buttonStyle(.glassProminent)
                            .font(PauseFont.body(17, relativeTo: .headline))
                            .tint(PauseTheme.coral)
                            .foregroundStyle(PauseTheme.background)
                    } else {
                        Button("Save for later") { save(startNow: false) }
                            .buttonStyle(.glass)
                            .font(PauseFont.body(17, relativeTo: .headline))
                        Button("Start plan") {
                            validationMessage = validate(activating: true)
                            if validationMessage == nil { confirmsStart = true }
                        }
                        .buttonStyle(.glassProminent)
                        .font(PauseFont.body(17, relativeTo: .headline))
                        .tint(PauseTheme.coral)
                        .foregroundStyle(PauseTheme.background)
                    }
                } else {
                    Button("Continue", action: advance)
                        .buttonStyle(.glassProminent)
                        .font(PauseFont.body(17, relativeTo: .headline))
                        .tint(PauseTheme.coral)
                        .foregroundStyle(canContinue ? PauseTheme.background : PauseTheme.muted)
                        .disabled(!canContinue)
                        .opacity(canContinue ? 1 : 0.45)
                        .accessibilityIdentifier("editor.continue")
                }
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(PauseTheme.surface.opacity(0.92))
    }

    private func editorSection<Content: View>(
        icon: String,
        title: String,
        accessibilityIdentifier: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        PauseCard {
            VStack(alignment: .leading, spacing: 14) {
                Group {
                    if let accessibilityIdentifier {
                        Label(title, systemImage: icon)
                            .accessibilityIdentifier(accessibilityIdentifier)
                    } else {
                        Label(title, systemImage: icon)
                    }
                }
                .font(PauseFont.display(20, relativeTo: .title3))
                content()
            }
        }
    }

    private var canContinue: Bool {
        switch step {
        case .intention:
            intention != nil
        case .boundaries:
            validate(activating: false) == nil
        case .commitment:
            false
        }
    }

    private var displayName: String {
        let normalized = LockBlock.normalizedName(name)
        return normalized.isEmpty ? "This plan" : normalized
    }

    private var screenTimeSelectionCount: Int {
        policy.selectedItemCount - policy.manualDomains.count
    }

    private var selectionSummary: String {
        let count = screenTimeSelectionCount
        return count == 0 ? "Nothing selected yet" : "\(count) selection\(count == 1 ? "" : "s")"
    }

    private var fullUnlockDelay: Binding<TimeInterval> {
        Binding(
            get: { policy.fullUnlockDelay ?? policy.waitDuration },
            set: { policy.fullUnlockDelay = $0 }
        )
    }

    private var activationConfirmation: String {
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

    private func selectIntention(_ option: PlanIntention) {
        let previousSuggestedName = intention?.suggestedName
        if name.isEmpty || name == previousSuggestedName { name = option.suggestedName }
        intention = option
        validationMessage = nil
        switch option {
        case .focus:
            policy.waitDuration = 3_600
            policy.fullUnlockDelay = 3_600
            policy.breakDuration = 900
            policy.fixedDuration = 3_600
        case .lessTime:
            policy.waitDuration = 3_600
            policy.fullUnlockDelay = 86_400
            policy.breakDuration = 900
            policy.fixedDuration = nil
        case .stayAway:
            policy.waitDuration = 86_400
            policy.fullUnlockDelay = 604_800
            policy.breakDuration = 900
            policy.fixedDuration = nil
        case .custom:
            policy.waitDuration = 3_600
            policy.fullUnlockDelay = 86_400
            policy.breakDuration = 900
            policy.fixedDuration = nil
        }
    }

    private func selectProtectionMode(_ mode: ProtectionMode) {
        policy.protectionMode = mode
        if mode == .lockdown {
            policy.fixedDuration = nil
            policy.preventsAppRemoval = true
            policy.requiresAutomaticDateAndTime = true
        }
        validationMessage = nil
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
            if !domainInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                addDomain()
                guard validationMessage == nil else { return }
            }
            validationMessage = validate(activating: false)
            guard validationMessage == nil else { return }
            withAnimation(.easeInOut(duration: 0.18)) { step = .commitment }
        case .commitment:
            break
        }
    }

    private func goBack() {
        validationMessage = nil
        switch step {
        case .intention: break
        case .boundaries:
            if !isEditing {
                withAnimation(.easeInOut(duration: 0.18)) { step = .intention }
            }
        case .commitment:
            withAnimation(.easeInOut(duration: 0.18)) { step = .boundaries }
        }
    }

    private func addDomain() {
        guard let domain = LockPolicy.newManualDomain(domainInput) else {
            validationMessage =
                "Enter a whole domain such as example.com. Paths, ports, query text, and wildcards are not supported."
            return
        }
        guard policy.manualDomains.contains(domain) || policy.manualDomains.count < LockPolicy.maximumManagedWebDomains
        else {
            validationMessage = "You can add no more than 50 website domains."
            return
        }
        if !policy.manualDomains.contains(domain) {
            policy.manualDomains.append(domain)
            policy.manualDomains.sort()
        }
        domainInput = ""
        validationMessage = nil
    }

    private func addPreset(_ preset: IOSSitePreset) {
        let additions = preset.domains.filter { !policy.manualDomains.contains($0) }
        guard policy.manualDomains.count + additions.count <= LockPolicy.maximumManagedWebDomains else {
            validationMessage = "You can add no more than 50 website domains."
            return
        }
        policy.manualDomains.append(contentsOf: additions)
        policy.manualDomains.sort()
        validationMessage = nil
    }

    private func validate(activating: Bool) -> String? {
        controller.draftValidationMessage(name: name, policy: policy, activating: activating)
    }

    private func save(startNow: Bool) {
        validationMessage = validate(activating: startNow)
        guard validationMessage == nil else { return }
        let saved: Bool
        if let blockID = presentation.blockID {
            saved = controller.updateBlock(id: blockID, name: name, policy: policy)
        } else {
            saved = controller.createBlock(name: name, policy: policy, activate: startNow) != nil
        }
        if saved { dismiss() }
    }
}

private struct DurationOptionPicker: View {
    let title: String
    let detail: String
    @Binding var selection: TimeInterval
    let options: [TimeInterval]
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout =
            dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        layout {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(PauseTheme.muted)
            }
            Spacer(minLength: 0)
            Picker(title, selection: $selection) {
                ForEach(options, id: \.self) { value in
                    Text(value.hardPauseDurationLabel).tag(value)
                }
            }
            .labelsHidden()
        }
    }
}

private struct OptionalDurationOptionPicker: View {
    let title: String
    let detail: String
    @Binding var selection: TimeInterval?
    let options: [TimeInterval?]
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout =
            dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        layout {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(PauseTheme.muted)
            }
            Spacer(minLength: 0)
            Picker(title, selection: $selection) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, value in
                    Text(value?.hardPauseDurationLabel ?? "Until I end it").tag(value)
                }
            }
            .labelsHidden()
        }
    }
}

private struct StatusLine: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(PauseTheme.muted)
            Spacer()
            Text(value).fontWeight(.semibold).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}

extension ProtectionMode {
    var displayName: String {
        switch self {
        case .softLock: "Pause"
        case .lockdown: "Hard Pause"
        }
    }

    fileprivate var detail: String {
        switch self {
        case .softLock: "Breaks allowed after the wait you choose."
        case .lockdown: "No breaks. Full unlock is the only way to end it."
        }
    }

    fileprivate var systemImage: String {
        switch self {
        case .softLock: "cup.and.saucer.fill"
        case .lockdown: "lock.shield.fill"
        }
    }
}
