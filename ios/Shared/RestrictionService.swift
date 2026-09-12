import ManagedSettings

protocol RestrictionApplying {
    func apply(_ collection: LockCollection)
}

protocol RestrictionStoreApplying {
    func apply(_ state: LockState?, toSlot slot: Int)
    func clearLegacyStore()
}

struct RestrictionService: RestrictionApplying {
    private let stores: any RestrictionStoreApplying

    init(stores: any RestrictionStoreApplying = ManagedRestrictionStoreBackend()) {
        self.stores = stores
    }

    func apply(_ collection: LockCollection) {
        let activeBySlot = Dictionary(
            uniqueKeysWithValues: collection.activeBlocks.compactMap { block in
                block.state.storeSlot.map { ($0, block.state) }
            }
        )

        // Apply every active session first so moving away from v1 never creates a gap.
        for slot in activeBySlot.keys.sorted() {
            stores.apply(activeBySlot[slot], toSlot: slot)
        }
        stores.clearLegacyStore()
        for slot in 0..<LockCollection.maximumActiveBlocks where activeBySlot[slot] == nil {
            stores.apply(nil, toSlot: slot)
        }
    }
}

struct ManagedRestrictionStoreBackend: RestrictionStoreApplying {
    func apply(_ state: LockState?, toSlot slot: Int) {
        let store = ManagedSettingsStore(named: HardPauseConstants.settingsStoreName(for: slot))
        guard let state, state.isActive else {
            store.clearAllSettings()
            return
        }

        applyProtectionSettings(state.policy, to: store)
        guard state.blocksTargets else {
            clearBlockedTargets(in: store)
            return
        }

        let selection = state.policy.selection
        store.shield.applications =
            selection.applicationTokens.isEmpty
            ? nil
            : selection.applicationTokens
        store.shield.applicationCategories =
            selection.categoryTokens.isEmpty
            ? nil
            : .specific(selection.categoryTokens)
        store.shield.webDomains =
            selection.webDomainTokens.isEmpty
            ? nil
            : selection.webDomainTokens
        store.shield.webDomainCategories =
            selection.categoryTokens.isEmpty
            ? nil
            : .specific(selection.categoryTokens)

        let manualDomains = Set(state.policy.manualDomains.map(WebDomain.init(domain:)))
        if state.policy.blocksAdultWebsites {
            store.webContent.blockedByFilter = .auto(manualDomains)
        } else if !manualDomains.isEmpty {
            store.webContent.blockedByFilter = .specific(manualDomains)
        } else {
            store.webContent.blockedByFilter = nil
        }
    }

    func clearLegacyStore() {
        ManagedSettingsStore(named: HardPauseConstants.legacySettingsStoreName).clearAllSettings()
    }

    private func applyProtectionSettings(
        _ policy: LockPolicy,
        to store: ManagedSettingsStore
    ) {
        // Named stores combine restrictions. These booleans therefore have OR behavior.
        store.application.denyAppRemoval = policy.preventsAppRemoval ? true : nil
        store.dateAndTime.requireAutomaticDateAndTime =
            policy.requiresAutomaticDateAndTime
            ? true
            : nil
    }

    private func clearBlockedTargets(in store: ManagedSettingsStore) {
        store.shield.applications = nil
        store.shield.applicationCategories = nil
        store.shield.webDomains = nil
        store.shield.webDomainCategories = nil
        store.webContent.blockedByFilter = nil
    }
}
