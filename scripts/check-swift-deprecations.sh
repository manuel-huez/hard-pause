#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if rg -n --glob '*.swift' \
    '\b(kSecUseAuthenticationUI[A-Za-z]*|SecKeychainCopyDomainDefault|SecKeychainOpen)\b' \
    core ios macos; then
    echo 'Deprecated Keychain API in Swift source.' >&2
    exit 1
fi
