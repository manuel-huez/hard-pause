import FamilyControls
import Foundation
import ManagedSettings

struct LockPolicy: Codable, Equatable {
    static let maximumManagedWebDomains = 50

    private struct CoreValues: Encodable {
        let protectionMode: ProtectionMode
        let waitDuration: String
        let fullUnlockDelay: String?
        let breakDuration: String
        let fixedDuration: String?
        let preventsAppRemoval: Bool
        let requiresAutomaticDateAndTime: Bool

        init(_ policy: LockPolicy) {
            protectionMode = policy.protectionMode
            waitDuration = String(policy.waitDuration)
            fullUnlockDelay = policy.fullUnlockDelay.map { String($0) }
            breakDuration = String(policy.breakDuration)
            fixedDuration = policy.fixedDuration.map { String($0) }
            preventsAppRemoval = policy.preventsAppRemoval
            requiresAutomaticDateAndTime = policy.requiresAutomaticDateAndTime
        }
    }

    private struct NormalizedValues: Decodable {
        let waitDuration: TimeInterval
        let fullUnlockDelay: TimeInterval
        let breakDuration: TimeInterval
        let fixedDuration: TimeInterval?
        let preventsAppRemoval: Bool
        let requiresAutomaticDateAndTime: Bool
    }

    private struct TargetCounts: Encodable {
        let manualDomains: Int
        let selectedWebDomains: Int
        let selectedApplications: Int
        let selectedCategories: Int
        let blocksAdultWebsites: Bool
        let requireTarget: Bool
    }

    private struct EmptyResult: Decodable {}

    var protectionMode: ProtectionMode = .softLock
    var selection = FamilyActivitySelection()
    var manualDomains: [String] = []
    var blocksAdultWebsites = true
    var waitDuration: TimeInterval = 3_600
    // Nil is the v1 representation: full unlock used the same delay as a timeout.
    var fullUnlockDelay: TimeInterval?
    var breakDuration: TimeInterval = 900
    var fixedDuration: TimeInterval?
    var preventsAppRemoval = true
    var requiresAutomaticDateAndTime = true

    init() {}

    private enum CodingKeys: String, CodingKey {
        case protectionMode
        case selection
        case manualDomains
        case blocksAdultWebsites
        case waitDuration
        case fullUnlockDelay
        case breakDuration
        case fixedDuration
        case preventsAppRemoval
        case requiresAutomaticDateAndTime
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.protectionMode) {
            protectionMode = try container.decode(ProtectionMode.self, forKey: .protectionMode)
        } else {
            protectionMode = .softLock
        }
        selection = try container.decode(FamilyActivitySelection.self, forKey: .selection)
        manualDomains = try container.decode([String].self, forKey: .manualDomains)
        blocksAdultWebsites = try container.decode(Bool.self, forKey: .blocksAdultWebsites)
        waitDuration = try container.decode(TimeInterval.self, forKey: .waitDuration)
        fullUnlockDelay = try container.decodeIfPresent(TimeInterval.self, forKey: .fullUnlockDelay)
        breakDuration = try container.decode(TimeInterval.self, forKey: .breakDuration)
        fixedDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .fixedDuration)
        preventsAppRemoval = try container.decode(Bool.self, forKey: .preventsAppRemoval)
        requiresAutomaticDateAndTime = try container.decode(
            Bool.self,
            forKey: .requiresAutomaticDateAndTime
        )

        do {
            try validateStoredModeRequirements()
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .protectionMode,
                in: container,
                debugDescription: error.localizedDescription
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protectionMode, forKey: .protectionMode)
        try container.encode(selection, forKey: .selection)
        try container.encode(manualDomains, forKey: .manualDomains)
        try container.encode(blocksAdultWebsites, forKey: .blocksAdultWebsites)
        try container.encode(waitDuration, forKey: .waitDuration)
        try container.encodeIfPresent(fullUnlockDelay, forKey: .fullUnlockDelay)
        try container.encode(breakDuration, forKey: .breakDuration)
        try container.encodeIfPresent(fixedDuration, forKey: .fixedDuration)
        try container.encode(preventsAppRemoval, forKey: .preventsAppRemoval)
        try container.encode(requiresAutomaticDateAndTime, forKey: .requiresAutomaticDateAndTime)
    }

    var selectedItemCount: Int {
        selection.applicationTokens.count
            + selection.categoryTokens.count
            + selection.webDomainTokens.count
            + manualDomains.count
    }

    var hasBlockingTarget: Bool {
        selectedItemCount > 0 || blocksAdultWebsites
    }

    func validateDurations() throws {
        try validateCoreValues("ios.validate_durations")
    }

    mutating func normalize() throws {
        let values: NormalizedValues
        do {
            values = try RustCoreBridge.call("ios.normalize_policy", CoreValues(self))
        } catch {
            throw Self.corePolicyError(error)
        }
        manualDomains = Self.normalizedDomains(manualDomains)
        waitDuration = values.waitDuration
        fullUnlockDelay = values.fullUnlockDelay
        breakDuration = values.breakDuration
        fixedDuration = values.fixedDuration
        preventsAppRemoval = values.preventsAppRemoval
        requiresAutomaticDateAndTime = values.requiresAutomaticDateAndTime
    }

    private func validateStoredModeRequirements() throws {
        try validateCoreValues("ios.validate_stored_policy")
    }

    private func validateCoreValues(_ operation: String) throws {
        do {
            let _: EmptyResult = try RustCoreBridge.call(operation, CoreValues(self))
        } catch {
            throw Self.corePolicyError(error)
        }
    }

    func validateManagedSettingsLimits() throws {
        try Self.validateManagedSettingsDomainCounts(
            manual: manualDomains.count,
            selected: selection.webDomainTokens.count
        )
    }

    static func validateManagedSettingsDomainCounts(manual: Int, selected: Int) throws {
        try validateTargets(
            TargetCounts(
                manualDomains: manual, selectedWebDomains: selected, selectedApplications: 0,
                selectedCategories: 0, blocksAdultWebsites: false, requireTarget: false
            ))
    }

    func validateActivationTargets() throws {
        try Self.validateTargets(
            TargetCounts(
                manualDomains: manualDomains.count,
                selectedWebDomains: selection.webDomainTokens.count,
                selectedApplications: selection.applicationTokens.count,
                selectedCategories: selection.categoryTokens.count,
                blocksAdultWebsites: blocksAdultWebsites,
                requireTarget: true
            ))
    }

    private static func validateTargets(_ counts: TargetCounts) throws {
        do {
            let _: EmptyResult = try RustCoreBridge.call("ios.validate_targets", counts)
        } catch RustCoreBridge.Failure.rejected(let code) {
            switch code {
            case "too_many_manual_domains": throw LockStateError.tooManyManualDomains
            case "too_many_selected_domains": throw LockStateError.tooManySelectedWebDomains
            case "no_blocking_target": throw LockStateError.noBlockingTarget
            default: throw LockStateError.coreUnavailable
            }
        } catch {
            throw LockStateError.coreUnavailable
        }
    }

    private static func corePolicyError(_ error: Error) -> LockPolicyError {
        guard case RustCoreBridge.Failure.rejected(let code) = error else { return .coreUnavailable }
        switch code {
        case "invalid_duration": return .invalidDuration
        case "fixed_duration_unavailable": return .fixedDurationUnavailableInLockdown
        case "device_protection_required": return .lockdownRequiresDeviceProtection
        default: return .coreUnavailable
        }
    }

    static func normalizedDomain(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }

        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var host = URLComponents(string: candidate)?.host else { return nil }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if host.hasPrefix("www.") {
            host.removeFirst(4)
        }

        guard host.contains("."), !host.contains(" ") else { return nil }
        return host
    }

    /// New entries must describe a whole domain. Keep legacy normalization unchanged.
    static func newManualDomain(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let components = URLComponents(string: candidate),
            components.scheme == "https" || components.scheme == "http",
            components.user == nil, components.password == nil, components.port == nil,
            components.path.isEmpty || components.path == "/",
            components.query == nil, components.fragment == nil,
            !trimmed.contains("*"),
            let domain = normalizedDomain(trimmed), domain.utf8.count <= 253
        else { return nil }
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard
            labels.allSatisfy({
                !$0.isEmpty && $0.utf8.count <= 63 && !$0.hasPrefix("-") && !$0.hasSuffix("-")
                    && $0.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" }
            })
        else { return nil }
        return domain
    }

    static func normalizedDomains(_ inputs: [String]) -> [String] {
        Array(Set(inputs.compactMap(normalizedDomain))).sorted()
    }
}

enum LockPolicyError: LocalizedError, Equatable {
    case invalidDuration
    case fixedDurationUnavailableInLockdown
    case lockdownRequiresDeviceProtection
    case coreUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidDuration:
            "Enter a valid waiting period and break length."
        case .fixedDurationUnavailableInLockdown:
            "Hard Pause cannot end automatically. Request a full unlock and complete its wait."
        case .lockdownRequiresDeviceProtection:
            "Hard Pause must prevent app deletion and require automatic date and time."
        case .coreUnavailable:
            "The protection core is unavailable."
        }
    }
}

extension TimeInterval {
    var hardPauseDurationLabel: String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = self >= 86_400 ? [.day, .hour] : [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: self) ?? "\(Int(self)) sec"
    }
}
