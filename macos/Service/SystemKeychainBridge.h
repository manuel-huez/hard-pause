#ifndef HARD_PAUSE_SYSTEM_KEYCHAIN_BRIDGE_H
#define HARD_PAUSE_SYSTEM_KEYCHAIN_BRIDGE_H

#include <Security/Security.h>
#include "../../core/rust/include/hard_pause_core.h"

// TN3137 requires the file-based System Keychain for a launchd daemon.
static inline OSStatus HPCopySystemKeychain(SecKeychainRef *keychain) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    OSStatus status = SecKeychainCopyDomainDefault(kSecPreferencesDomainSystem, keychain);
#pragma clang diagnostic pop
    return status;
}

#endif
