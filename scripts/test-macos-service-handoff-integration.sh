#!/bin/bash
set -euo pipefail

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)

# This fixture installs a privileged launch daemon and changes /etc/hosts and
# PF. Refuse every environment except the disposable hosted macOS 26 runner.
[[ "$GITHUB_ACTIONS" == true \
    && "$RUNNER_OS" == macOS \
    && "$GITHUB_EVENT_NAME" != pull_request \
    && "$GITHUB_REPOSITORY" == manuel-huez/hard-pause \
    && "$(id -un)" == runner \
    && "$HOME" == /Users/runner ]] \
    || { echo "service handoff fixture: only the official GitHub hosted runner may run this" >&2; exit 1; }
[[ "$(sw_vers -productVersion)" == 26.* ]] \
    || { echo "service handoff fixture: macOS 26 is required" >&2; exit 1; }
[[ "$(id -u)" -ne 0 && "$(/usr/bin/stat -f '%u' /dev/console)" == "$(id -u)" ]] \
    || { echo "service handoff fixture: run as the logged-in runner account" >&2; exit 1; }
[[ "$(pwd -P)" == "$repo_root" && "$GITHUB_WORKSPACE" == "$repo_root" ]] \
    || { echo "service handoff fixture: checkout and GitHub workspace differ" >&2; exit 1; }

artifact_dir="$repo_root/build/handoff-artifacts"
build_root="$RUNNER_TEMP/hard-pause-service-handoff-build"
mkdir -p "$artifact_dir" "$build_root"
exec > >(tee "$artifact_dir/fixture.log") 2>&1

fail() {
    echo "service handoff fixture: $*" >&2
    exit 1
}

for command_name in xcodegen xcodebuild codesign security openssl python3 rsync sudo; do
    command -v "$command_name" >/dev/null 2>&1 || fail "required command is missing: $command_name"
done

helper_dir="/Library/PrivilegedHelperTools/HardPause"
support_dir="/Library/Application Support/HardPause"
service_label="org.hardpause.service"
standby_label="org.hardpause.service.standby"
main_anchor="com.apple/hard-pause"
standby_anchor="com.apple/hard-pause-standby"
blocked_domain="handoff-fixture.example"
blocked_ip="192.0.2.123"

[[ ! -e "$helper_dir" && ! -e "$support_dir" ]] \
    || fail "Hard Pause is already installed; refusing to touch an existing installation"
for label in "$service_label" "$standby_label"; do
    if /bin/launchctl print "system/$label" >/dev/null 2>&1; then
        fail "launchd already has system/$label"
    fi
done
for worker_plist in /Library/LaunchAgents/org.hardpause.browser-worker*.plist; do
    [[ ! -e "$worker_plist" && ! -L "$worker_plist" ]] \
        || fail "a browser worker launch agent already exists: $worker_plist"
done
/usr/bin/grep -Fq 'BEGIN HARD PAUSE' /etc/hosts \
    && fail "/etc/hosts already contains Hard Pause rules"
for anchor in "$main_anchor" "$standby_anchor"; do
    rules=$(sudo -n /sbin/pfctl -a "$anchor" -sr 2>/dev/null) \
        || fail "cannot verify that PF anchor $anchor is empty"
    [[ -z "$rules" ]] || fail "PF anchor $anchor already has rules"
done

cat >"$artifact_dir/proof-limits.txt" <<'EOF'
The inactive migration baseline is a synthetic service-version 7 build from
the current checkout. This does not prove the exact behavior or provenance of
a historical installed v2 binary.

The active v8 baseline and v9 app-build successor enable the handoff gate only
in temporary source copies. The successor app build number is higher so the
installer's signed build monotonicity check runs.

All bundles use one short-lived, self-signed code-signing certificate. The test
checks stable designated requirements and a changed service CDHash. It does
not prove Apple Development or Developer ID Team ID identity, notarization, or
release signing.

The test checks actual launchd jobs, owned hosts sections, and primary and
standby PF anchors. A 200 ms observer samples continuity while the installer
runs; the injected failure hook checks both enforcement paths immediately
before rollback. This does not prove an absence of every sub-200 ms gap or
external network behavior.

The temporary browser worker accepts the fixture certificate and skips browser
consent checks. This fixture proves its process and service handoff checks, not
real Safari, Chrome, or Firefox permission continuity.
EOF

umask 077
certificate_dir="$build_root/certificate"
mkdir -m 0700 "$certificate_dir"
keychain="$build_root/handoff-fixture.keychain-db"
keychain_password=$(/usr/bin/openssl rand -hex 24)
p12_password=$(/usr/bin/openssl rand -hex 24)
/usr/bin/openssl req -x509 -newkey rsa:3072 -sha256 -days 2 -nodes \
    -subj "/CN=Hard Pause Handoff Integration Fixture" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=codeSigning" \
    -keyout "$certificate_dir/private.pem" \
    -out "$certificate_dir/certificate.pem" >/dev/null 2>&1
/usr/bin/openssl pkcs12 -export \
    -inkey "$certificate_dir/private.pem" \
    -in "$certificate_dir/certificate.pem" \
    -name "Hard Pause Handoff Integration Fixture" \
    -out "$certificate_dir/certificate.p12" \
    -passout "pass:$p12_password"
/usr/bin/security create-keychain -p "$keychain_password" "$keychain"
/usr/bin/security set-keychain-settings -lut 3600 "$keychain"
/usr/bin/security unlock-keychain -p "$keychain_password" "$keychain"
/usr/bin/security import "$certificate_dir/certificate.p12" -k "$keychain" \
    -P "$p12_password" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
/usr/bin/security add-trusted-cert -r trustRoot -p codeSigning \
    -k "$keychain" "$certificate_dir/certificate.pem" >/dev/null
/usr/bin/security set-key-partition-list \
    -S apple-tool:,apple:,codesign: -s - -k "$keychain_password" "$keychain" >/dev/null
/usr/bin/security list-keychains -d user -s "$keychain"
signing_identity=$(/usr/bin/security find-identity -v -p codesigning "$keychain" \
    | /usr/bin/awk '/Hard Pause Handoff Integration Fixture/ { print $2; exit }')
[[ "$signing_identity" =~ ^[0-9A-Fa-f]{40}$ ]] \
    || fail "the temporary code-signing identity is unavailable"
sparkle_public_key=$(/usr/bin/openssl rand -base64 32 | tr -d '\n')
printf 'Temporary signing identity SHA-1: %s\n' "$signing_identity" \
    >"$artifact_dir/signing-proof.txt"

copy_source() {
    mkdir -p "$1"
    /usr/bin/rsync -a --delete \
        --exclude .git --exclude .codedb --exclude build --exclude dist --exclude node_modules \
        "$repo_root/" "$1/"
    python3 - "$1/macos/App/BrowserWorkerIPC.swift" "$signing_identity" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
assert text.count('anchor apple generic and identifier ') == 2
assert text.count('and certificate leaf[subject.OU] = "ZBX6C7BJ5X"') == 2
text = text.replace('anchor apple generic and identifier ', 'identifier ')
text = text.replace(
    'and certificate leaf[subject.OU] = "ZBX6C7BJ5X"',
    f'and certificate leaf = H"{sys.argv[2]}"',
)
assert text.count('return !installed || permission == "granted"') == 1
text = text.replace('return !installed || permission == "granted"', 'return true')
path.write_text(text)
PY
}

patch_source_once() {
    python3 - "$1" "$2" "$3" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
old, new = sys.argv[2], sys.argv[3]
if text.count(old) != 1:
    raise SystemExit(f"expected one fixture patch target in {path}")
path.write_text(text.replace(old, new, 1))
PY
}

build_app() {
    local source=$1
    local derived=$2
    local build_number=$3
    (
        cd "$source/macos"
        xcodegen generate --spec project.yml
    )
    xcodebuild -quiet \
        -project "$source/macos/HardPause.xcodeproj" \
        -scheme HardPause \
        -configuration Release \
        -destination 'generic/platform=macOS' \
        -derivedDataPath "$derived" \
        -clonedSourcePackagesDirPath "$derived/packages" \
        CODE_SIGN_STYLE=Manual \
        DEVELOPMENT_TEAM= \
        CODE_SIGN_IDENTITY="$signing_identity" \
        CODE_SIGNING_ALLOWED=YES \
        CURRENT_PROJECT_VERSION="$build_number" \
        SPARKLE_EDDSA_PUBLIC_KEY="$sparkle_public_key" \
        build
    BUILT_APP="$derived/Build/Products/Release/HardPause.app"
    [[ -d "$BUILT_APP" ]] || fail "Xcode did not produce $BUILT_APP"
    for path in \
        "$BUILT_APP/Contents/Resources/hard-pause-service" \
        "$BUILT_APP/Contents/Resources/hard-pause" \
        "$BUILT_APP/Contents/Resources/install-macos-service.sh" \
        "$BUILT_APP/Contents/Resources/uninstall-macos-service.sh" \
        "$BUILT_APP/Contents/Resources/org.hardpause.service.plist" \
        "$BUILT_APP/Contents/Resources/HardPauseBrowserWorker.app"; do
        [[ -e "$path" ]] || fail "the app bundle is missing $path"
    done
    /usr/bin/codesign --verify --deep --strict "$BUILT_APP"
}

code_requirement() {
    /usr/bin/codesign --display --requirements - "$1" 2>&1 \
        | /usr/bin/sed -n -e 's/^# designated => //p' -e 's/^designated => //p' \
        | /usr/bin/tail -n 1
}

code_cdhash() {
    /usr/bin/codesign --display --verbose=4 "$1" 2>&1 \
        | /usr/bin/sed -n 's/^CDHash=//p' | /usr/bin/tail -n 1
}

assert_same_requirement() {
    local before=$1
    local after=$2
    local name=$3
    local before_requirement
    local after_requirement
    before_requirement=$(code_requirement "$before")
    after_requirement=$(code_requirement "$after")
    [[ -n "$before_requirement" && "$before_requirement" == "$after_requirement" ]] \
        || fail "$name designated requirement changed between installed and staged builds"
    /usr/bin/codesign --verify --strict -R="$before_requirement" "$after"
    printf '%s: %s\n' "$name" "$before_requirement" >>"$artifact_dir/signing-proof.txt"
}

echo "Building a temporary signed service-version 7 source for inactive migration."
migration_v7_source="$build_root/source-migration-v7"
copy_source "$migration_v7_source"
patch_source_once "$migration_v7_source/macos/Core/ProtectedServiceIPC.swift" \
    'static let serviceVersion = "8"' 'static let serviceVersion = "7"'
build_app "$migration_v7_source" "$build_root/derived-migration-v7" 7
migration_v7_app=$BUILT_APP

echo "Building the checked-in v8 source for migration and use as live successor."
production_source="$build_root/source-production"
copy_source "$production_source"
build_app "$production_source" "$build_root/derived-migration-v8" 8
migration_v8_app=$BUILT_APP
for component in hard-pause-service hard-pause; do
    assert_same_requirement \
        "$migration_v7_app/Contents/Resources/$component" \
        "$migration_v8_app/Contents/Resources/$component" \
        "migration $component"
done
[[ $(code_cdhash "$migration_v7_app/Contents/Resources/hard-pause-service") \
    != $(code_cdhash "$migration_v8_app/Contents/Resources/hard-pause-service") ]] \
    || fail "the migration fixture did not produce a distinct v8 service binary"

echo "Building the temporary v8 live-handoff primary with the test-only gate enabled."
live_primary_source="$build_root/source-live-primary"
copy_source "$live_primary_source"
patch_source_once "$live_primary_source/macos/Core/ProtectedServiceIPC.swift" \
    'static let liveServiceHandoffEnabled = false' \
    'static let liveServiceHandoffEnabled = true'
build_app "$live_primary_source" "$build_root/derived-live-primary" 8
live_primary_app=$BUILT_APP

echo "Building the gate-enabled v8 successor with a higher signed app build number."
live_successor_source="$build_root/source-live-successor"
copy_source "$live_successor_source"
patch_source_once "$live_successor_source/macos/Core/ProtectedServiceIPC.swift" \
    'static let liveServiceHandoffEnabled = false' \
    'static let liveServiceHandoffEnabled = true'
build_app "$live_successor_source" "$build_root/derived-live-successor" 9
live_successor_app=$BUILT_APP

for component in \
    Contents/Resources/hard-pause-service \
    Contents/Resources/hard-pause \
    Contents/Resources/HardPauseBrowserWorker.app; do
    assert_same_requirement "$live_primary_app/$component" "$live_successor_app/$component" \
        "live successor $component"
done
primary_service="$live_primary_app/Contents/Resources/hard-pause-service"
successor_service="$live_successor_app/Contents/Resources/hard-pause-service"
primary_cdhash=$(code_cdhash "$primary_service")
successor_cdhash=$(code_cdhash "$successor_service")
[[ -n "$primary_cdhash" && -n "$successor_cdhash" && "$primary_cdhash" != "$successor_cdhash" ]] \
    || fail "the signed successor must keep the enrolled requirement and have a different CDHash"
printf 'installed-candidate CDHash: %s\nsuccessor CDHash: %s\n' \
    "$primary_cdhash" "$successor_cdhash" >>"$artifact_dir/signing-proof.txt"

installed_cli="$helper_dir/hard-pause"
installed_uninstaller="$helper_dir/hard-pause-uninstall"
run_cli() { "$installed_cli" "$@"; }

assert_snapshot() {
    python3 - "$1" "$2" "$3" "$4" <<'PY'
import json
import sys

snapshot = json.load(open(sys.argv[1], encoding="utf-8"))
assert snapshot["protection"]["serviceVersion"] == sys.argv[2]
assert snapshot["protection"]["isEnforcing"] is True
assert snapshot["protection"]["issues"] == []
block = next(item for item in snapshot["blocks"] if item["id"] == sys.argv[3])
phase = block["phase"]
assert isinstance(phase, dict) and len(phase) == 1, phase
assert ("inactive" in phase) == (sys.argv[4] == "inactive"), phase
if sys.argv[4] == "inactive":
    assert block["draft"]["rules"]["blockedDomains"] == ["migration-fixture.example"]
PY
}

assert_installation_empty() {
    [[ ! -e "$helper_dir" && ! -e "$support_dir" ]] \
        || fail "the previous fixture installation was not removed"
    for label in "$service_label" "$standby_label"; do
        if /bin/launchctl print "system/$label" >/dev/null 2>&1; then
            fail "system/$label remained loaded after normal removal"
        fi
    done
    /usr/bin/grep -Fq 'BEGIN HARD PAUSE' /etc/hosts \
        && fail "an owned hosts section remained after normal removal"
    for anchor in "$main_anchor" "$standby_anchor"; do
        rules=$(sudo -n /sbin/pfctl -a "$anchor" -sr 2>/dev/null) \
            || fail "cannot inspect PF anchor $anchor after normal removal"
        [[ -z "$rules" ]] || fail "PF anchor $anchor retained rules after normal removal"
    done
}

echo "Testing inactive-only migration through the bundled installer."
sudo "$migration_v7_app/Contents/Resources/install-macos-service.sh"
cat >"$build_root/migration-request.json" <<'JSON'
{
  "draft": {
    "name": "Inactive migration fixture",
    "rules": {
      "blockedDomains": ["migration-fixture.example"],
      "blockedApplications": [],
      "blockedAdultDomains": [],
      "adultRulesVersion": null,
      "blockedURLPatterns": [],
      "blocksAdultWebsites": false
    },
    "protectionMode": "softLock",
    "breakDelay": 60,
    "fullUnlockDelay": 60,
    "breakDuration": 60,
    "elapsedDuration": null
  }
}
JSON
run_cli create "$build_root/migration-request.json" >"$artifact_dir/migration-created.json"
migration_block_id=$(python3 -c \
    'import json,sys; print(json.load(open(sys.argv[1]))["blocks"][0]["id"])' \
    "$artifact_dir/migration-created.json")
run_cli list >"$artifact_dir/migration-before.json"
assert_snapshot "$artifact_dir/migration-before.json" "7" "$migration_block_id" inactive
sudo "$migration_v8_app/Contents/Resources/install-macos-service.sh" --update
run_cli list >"$artifact_dir/migration-after.json"
assert_snapshot "$artifact_dir/migration-after.json" "8" "$migration_block_id" inactive
run_cli can-uninstall
sudo "$installed_uninstaller"
assert_installation_empty
echo "Inactive migration passed: the inactive block survived the synthetic version-7-to-8 path."

echo "Installing the active v8 handoff primary."
sudo "$live_primary_app/Contents/Resources/install-macos-service.sh"
cat >"$build_root/active-request.json" <<JSON
{
  "draft": {
    "name": "Active handoff fixture",
    "rules": {
      "blockedDomains": ["$blocked_domain", "$blocked_ip"],
      "blockedApplications": [],
      "blockedAdultDomains": [],
      "adultRulesVersion": null,
      "blockedURLPatterns": [],
      "blocksAdultWebsites": false
    },
    "protectionMode": "softLock",
    "breakDelay": 60,
    "fullUnlockDelay": 60,
    "breakDuration": 60,
    "elapsedDuration": 1800
  }
}
JSON
run_cli create "$build_root/active-request.json" >"$artifact_dir/active-created.json"
active_block_id=$(python3 -c \
    'import json,sys; print(json.load(open(sys.argv[1]))["blocks"][0]["id"])' \
    "$artifact_dir/active-created.json")
run_cli activate "$active_block_id" 1 >"$artifact_dir/active-started.json"
run_cli list >"$artifact_dir/active-before-handoff.json"
assert_snapshot "$artifact_dir/active-before-handoff.json" "8" "$active_block_id" active

observer="$build_root/handoff-observer.py"
cat >"$observer" <<'PY'
from datetime import datetime, timezone
from pathlib import Path
import json
import subprocess
import sys
import time

domain = "handoff-fixture.example"
ip = "192.0.2.123"
markers = (
    ("# BEGIN HARD PAUSE — exact domains managed by org.hardpause.service", "# END HARD PAUSE"),
    ("# BEGIN HARD PAUSE STANDBY — org.hardpause.service.standby", "# END HARD PAUSE STANDBY"),
)
anchors = ("com.apple/hard-pause", "com.apple/hard-pause-standby")

def inspect():
    hosts = Path("/etc/hosts").read_text(encoding="utf-8")
    def has_section(pair):
        try:
            return domain in hosts.split(pair[0], 1)[1].split(pair[1], 1)[0]
        except IndexError:
            return False
    def has_pf(anchor):
        result = subprocess.run(["/sbin/pfctl", "-a", anchor, "-sr"],
                                capture_output=True, text=True, check=False)
        return result.returncode == 0 and ip in result.stdout
    jobs = {}
    for label in ("org.hardpause.service", "org.hardpause.service.standby"):
        result = subprocess.run(["/bin/launchctl", "print", f"system/{label}"],
                                capture_output=True, text=True, check=False)
        jobs[label] = result.returncode == 0
    return {
        "main_hosts": has_section(markers[0]),
        "standby_hosts": has_section(markers[1]),
        "main_pf": has_pf(anchors[0]),
        "standby_pf": has_pf(anchors[1]),
        "launchd": jobs,
    }

mode = sys.argv[1]
if mode == "watch":
    stop_path, output_path = map(Path, sys.argv[2:4])
    with output_path.open("a", encoding="utf-8") as output:
        while not stop_path.exists():
            try:
                result = inspect()
                result["time"] = datetime.now(timezone.utc).isoformat()
                result["gap"] = not (result["main_hosts"] or result["standby_hosts"]) \
                    or not (result["main_pf"] or result["standby_pf"])
                result["overlap"] = result["main_hosts"] and result["standby_hosts"] \
                    and result["main_pf"] and result["standby_pf"]
            except Exception as error:
                result = {"observer_error": str(error)}
            output.write(json.dumps(result, sort_keys=True) + "\n")
            output.flush()
            time.sleep(0.2)
elif mode == "main":
    result = inspect()
    assert result["main_hosts"] and result["main_pf"], result
    assert not result["standby_hosts"] and not result["standby_pf"], result
    print(json.dumps(result, sort_keys=True))
elif mode == "overlap":
    result = inspect()
    result["checkpoint"] = "new-primary-ready-before-finalize"
    assert result["main_hosts"] and result["standby_hosts"], result
    assert result["main_pf"] and result["standby_pf"], result
    assert all(result["launchd"].values()), result
    Path(sys.argv[2]).write_text(json.dumps(result, indent=2, sort_keys=True) + "\n",
                                 encoding="utf-8")
    print(json.dumps(result, sort_keys=True))
else:
    raise SystemExit(f"unknown mode: {mode}")
PY

sudo -n /usr/bin/python3 "$observer" main
watch_stop="$build_root/stop-enforcement-watch"
watch_log="$artifact_dir/enforcement-watch.jsonl"
watch_pid=""
stop_watcher() {
    if [[ -n "$watch_pid" ]]; then
        : >"$watch_stop"
        wait "$watch_pid" || true
        watch_pid=""
    fi
}
trap stop_watcher EXIT
sudo -n /usr/bin/python3 "$observer" watch "$watch_stop" "$watch_log" &
watch_pid=$!

echo "Creating a successor app with a temporary pre-finalize installer failure."
failure_app="$build_root/HardPause-Failure.app"
/usr/bin/ditto "$live_successor_app" "$failure_app"
python3 - "$failure_app/Contents/Resources/install-macos-service.sh" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
needle = '''    # A timeout after this call may mean the new service already owns state.
    # Recovery must not start the old service once finalization was attempted.
    live_finalization_started=1
'''
hook = '''    if [[ "$HARD_PAUSE_FIXTURE_INJECT_PRE_FINALIZE" == 1 ]]; then
        /usr/bin/python3 "$HARD_PAUSE_FIXTURE_OBSERVER" overlap "$HARD_PAUSE_FIXTURE_OVERLAP_REPORT" \\
            || fail "fixture did not observe launchd, hosts, and PF overlap"
        fail "fixture injected failure before live-update finalization"
    fi
'''
if text.count(needle) != 1:
    raise SystemExit("expected exactly one pre-finalize installer injection point")
path.write_text(text.replace(needle, hook + needle, 1))
PY
/usr/bin/codesign --force --sign "$signing_identity" --timestamp=none \
    --options runtime "$failure_app"
/usr/bin/codesign --verify --deep --strict "$failure_app"

echo "Injecting failure after new-primary readiness and before finalization."
failure_log="$artifact_dir/injected-rollback-installer.log"
    if sudo -n /usr/bin/env \
    HARD_PAUSE_FIXTURE_INJECT_PRE_FINALIZE=1 \
    HARD_PAUSE_FIXTURE_OBSERVER="$observer" \
    HARD_PAUSE_FIXTURE_OVERLAP_REPORT="$artifact_dir/injected-overlap.json" \
    "$failure_app/Contents/Resources/install-macos-service.sh" --live-update \
    2>&1 | /usr/bin/tee "$failure_log" >/dev/null; then
    fail "the injected pre-finalize failure unexpectedly returned success"
fi
/bin/cat "$failure_log"
/usr/bin/grep -Fq "fixture injected failure before live-update finalization" "$failure_log" \
    || fail "the installer did not reach the injected failure point"
[[ -s "$artifact_dir/injected-overlap.json" ]] \
    || fail "the injected failure did not record simultaneous launchd, hosts, and PF evidence"
run_cli list >"$artifact_dir/after-rollback.json"
assert_snapshot "$artifact_dir/after-rollback.json" "8" "$active_block_id" active
if /bin/launchctl print "system/$standby_label" >/dev/null 2>&1; then
    fail "rollback left the standby launch daemon loaded"
fi
if /usr/bin/grep -Fq '# BEGIN HARD PAUSE STANDBY' /etc/hosts; then
    fail "rollback did not retire the standby hosts section"
fi
[[ $(shasum -a 256 "$helper_dir/hard-pause-service" | awk '{ print $1 }') \
    == $(shasum -a 256 "$primary_service" | awk '{ print $1 }') ]] \
    || fail "rollback did not restore the prior primary service binary"
sudo -n /usr/bin/python3 "$observer" main
echo "Injected rollback passed: the previous v8 primary resumed with active rules."

echo "Requesting the successful v8 active handoff from the signed successor app."
/usr/bin/open -n -a "$live_successor_app"
successor_sha=$(shasum -a 256 "$successor_service" | awk '{ print $1 }')
updated=0
for _ in {1..180}; do
    if [[ -f "$helper_dir/hard-pause-service" \
        && $(shasum -a 256 "$helper_dir/hard-pause-service" | awk '{ print $1 }') == "$successor_sha" ]]; then
        updated=1
        break
    fi
    /bin/sleep 1
done
if [[ "$updated" -ne 1 ]]; then
    sudo -n /bin/ls -la "$support_dir/service-updates" 2>&1 \
        | /usr/bin/tee "$artifact_dir/update-stage.txt" >/dev/null || true
    fail "the app did not complete its no-password service update"
fi
run_cli list >"$artifact_dir/after-successful-handoff.json"
assert_snapshot "$artifact_dir/after-successful-handoff.json" "8" "$active_block_id" active
[[ $(shasum -a 256 "$helper_dir/hard-pause-service" | awk '{ print $1 }') \
    == "$successor_sha" ]] \
    || fail "the successful handoff did not install the signed successor binary"
if /bin/launchctl print "system/$standby_label" >/dev/null 2>&1; then
    fail "successful handoff left the standby launch daemon loaded"
fi
if /usr/bin/grep -Fq '# BEGIN HARD PAUSE STANDBY' /etc/hosts; then
    fail "successful handoff left the standby hosts section"
fi
sudo -n /usr/bin/python3 "$observer" main
stop_watcher
python3 - "$watch_log" <<'PY'
import json
import sys

records = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
assert len(records) >= 4, f"too few continuity samples: {len(records)}"
assert not any(record.get("observer_error") for record in records), records
assert not any(record.get("gap") for record in records), records
print(f"Continuity observer passed: {len(records)} samples, no sampled gap.")
PY

echo "Completing the full-unlock delay and normal service removal."
run_cli end "$active_block_id" >"$artifact_dir/full-unlock-requested.json"
/bin/sleep 65
run_cli end "$active_block_id" >"$artifact_dir/full-unlock-completed.json"
run_cli can-uninstall
sudo "$installed_uninstaller"
assert_installation_empty
/usr/bin/security delete-keychain "$keychain"
/bin/rm -f "$certificate_dir/private.pem" "$certificate_dir/certificate.pem" \
    "$certificate_dir/certificate.p12"

echo "Native service handoff fixture passed on macOS $(sw_vers -productVersion)."
echo "Proof limits: $artifact_dir/proof-limits.txt"
