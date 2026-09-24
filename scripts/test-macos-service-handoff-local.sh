#!/bin/bash
set -euo pipefail

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)

# The fixture uses separate service names, root storage, Keychain items, hosts
# markers, and PF anchors. The existing Hard Pause installation is not changed.
macos_major="$(sw_vers -productVersion)"
macos_major="${macos_major%%.*}"
[[ "$macos_major" =~ ^[0-9]+$ && "$macos_major" -ge 26 ]] \
    || { echo "service handoff fixture: macOS 26 or later is required" >&2; exit 1; }
[[ "$(id -u)" -ne 0 && "$(/usr/bin/stat -f '%u' /dev/console)" == "$(id -u)" ]] \
    || { echo "service handoff fixture: run as the logged-in Mac account" >&2; exit 1; }
[[ "$(pwd -P)" == "$repo_root" ]] \
    || { echo "service handoff fixture: run from the repository root" >&2; exit 1; }

artifact_dir="$repo_root/build/handoff-local-artifacts"
mkdir -p "$artifact_dir" "$repo_root/build"
build_root=$(/usr/bin/mktemp -d "$repo_root/build/handoff-local.XXXXXX")
fixture_hosts_file="$build_root/hosts"
/bin/cp /etc/hosts "$fixture_hosts_file"
exec > >(tee "$artifact_dir/fixture.log") 2>&1

fail() {
    echo "service handoff fixture: $*" >&2
    exit 1
}

for command_name in xcodegen xcodebuild codesign security openssl python3 rsync sudo; do
    command -v "$command_name" >/dev/null 2>&1 || fail "required command is missing: $command_name"
done

helper_dir="/Library/PrivilegedHelperTools/HardPauseHandoffFixture"
support_dir="/Library/Application Support/HardPauseHandoffFixture"
service_label="org.hardpause.fixture.service"
standby_label="org.hardpause.fixture.service.standby"
main_anchor="com.apple/hard-pause-fixture"
standby_anchor="com.apple/hard-pause-fixture-standby"
blocked_domain="handoff-fixture.example"
blocked_ip="192.0.2.123"

[[ ! -e "$helper_dir" && ! -e "$support_dir" ]] \
    || fail "an earlier fixture installation exists; inspect it before retrying"
for label in "$service_label" "$standby_label"; do
    if /bin/launchctl print "system/$label" >/dev/null 2>&1; then
        fail "launchd already has system/$label"
    fi
done
for worker_plist in /Library/LaunchAgents/org.hardpause.fixture.browser-worker*.plist; do
    [[ ! -e "$worker_plist" && ! -L "$worker_plist" ]] \
        || fail "a browser worker launch agent already exists: $worker_plist"
done
/usr/bin/grep -Fq 'BEGIN HARD PAUSE FIXTURE' /etc/hosts \
    && fail "/etc/hosts already contains fixture rules"

cat >"$artifact_dir/proof-limits.txt" <<'EOF'
This fixture tests a version-8-to-version-8 live service update. It does not
test migration from the installed version-2 service.

The v8 baseline and v9 app-build successor use separate fixture service names,
root storage, Keychain items, hosts markers, and PF anchors on this Mac. The
successor app build number is higher so the signed build check runs.

All bundles use this Mac's Apple Development identity. The test checks stable
designated requirements and a changed service CDHash. It does not prove
Developer ID identity, notarization, or release signing.

The test checks actual launchd jobs and primary and standby PF anchors. Hosts
sections use a separate copy of /etc/hosts to avoid writing the installed
service's active rules. A 200 ms observer samples continuity while the installer
runs; the injected failure hook checks both enforcement paths immediately
before rollback. This does not prove an absence of every sub-200 ms gap or
external network behavior.

The fixture browser worker skips browser consent checks. This proves its
process and service handoff checks, not real browser permission continuity.
EOF

umask 077
signing_identity="${HARD_PAUSE_SIGN_IDENTITY:-}"
if [[ -z "$signing_identity" ]]; then
    signing_identity=$(/usr/bin/security find-identity -v -p codesigning \
        | /usr/bin/sed -nE 's/^[[:space:]]*[0-9]+\) [[:xdigit:]]{40} "(Apple Development: [^"]+)".*$/\1/p')
fi
[[ -n "$signing_identity" && "$signing_identity" != *$'\n'* ]] \
    || fail "set HARD_PAUSE_SIGN_IDENTITY to one Apple Development identity"
sparkle_public_key=$(/usr/bin/openssl rand -base64 32 | tr -d '\n')
echo "Using local Apple Development signing identity."

copy_source() {
    mkdir -p "$1"
    /usr/bin/rsync -a --delete \
        --exclude .git --exclude .codedb --exclude build --exclude dist --exclude node_modules \
        "$repo_root/" "$1/"
    python3 - "$1/macos" "$fixture_hosts_file" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
fixture_hosts_file = sys.argv[2]
replacements = (
    ('/Library/Application Support/HardPause', '/Library/Application Support/HardPauseHandoffFixture'),
    ('/Library/PrivilegedHelperTools/HardPause', '/Library/PrivilegedHelperTools/HardPauseHandoffFixture'),
    ('com.apple/hard-pause', 'com.apple/hard-pause-fixture'),
    ('BEGIN HARD PAUSE', 'BEGIN HARD PAUSE FIXTURE'),
    ('END HARD PAUSE', 'END HARD PAUSE FIXTURE'),
    ('org.hardpause.', 'org.hardpause.fixture.'),
)
for path in root.rglob('*'):
    if not path.is_file() or path.suffix not in {'.swift', '.sh', '.plist', '.yml'}:
        continue
    text = path.read_text()
    updated = text
    for old, new in replacements:
        updated = updated.replace(old, new)
    if updated != text:
        path.write_text(updated)

    if re.search(r'org\.hardpause\.(?!fixture\.)', updated):
        raise SystemExit(f'unisolated service identifier: {path}')
    if re.search(r'com\.apple/hard-pause(?!-fixture)', updated):
        raise SystemExit(f'unisolated PF anchor: {path}')
    if re.search(r'/Library/(?:Application Support|PrivilegedHelperTools)/HardPause(?!HandoffFixture)', updated):
        raise SystemExit(f'unisolated root path: {path}')

(root / 'scripts/org.hardpause.service.plist').rename(
    root / 'scripts/org.hardpause.fixture.service.plist'
)

path = root / 'Service/HostsEnforcer.swift'
text = path.read_text()
needle = 'POSIXManagedTextFile(path: "/etc/hosts")'
assert text.count(needle) == 1
text = text.replace(needle, f'POSIXManagedTextFile(path: "{fixture_hosts_file}")')
path.write_text(text)

path = root / 'App/BrowserWorkerIPC.swift'
text = path.read_text()
assert text.count('!installed || permission == "granted"') == 1
text = text.replace('!installed || permission == "granted"', 'true')
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
        -clonedSourcePackagesDirPath "$build_root/packages" \
        CODE_SIGN_STYLE=Manual \
        DEVELOPMENT_TEAM=ZBX6C7BJ5X \
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
        "$BUILT_APP/Contents/Resources/org.hardpause.fixture.service.plist" \
        "$BUILT_APP/Contents/Resources/HardPauseBrowserWorker.app"; do
        [[ -e "$path" ]] || fail "the app bundle is missing $path"
    done
    /usr/bin/codesign --verify --deep --strict "$BUILT_APP"
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
        "$BUILT_APP/Contents/Info.plist")" == org.hardpause.fixture.app ]] \
        || fail "fixture app bundle ID was not isolated"
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
patch_source_once "$live_successor_source/macos/Service/ServiceSupport.swift" \
    'org.hardpause.fixture.service.privileged-update' \
    'org.hardpause.fixture.service.privileged-update.successor'
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
assert "active" in phase, phase
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
    /usr/bin/grep -Fq 'BEGIN HARD PAUSE FIXTURE' "$fixture_hosts_file" \
        && fail "an owned hosts section remained after normal removal"
    for anchor in "$main_anchor" "$standby_anchor"; do
        rules=$(sudo -n /sbin/pfctl -a "$anchor" -sr 2>/dev/null) \
            || fail "cannot inspect PF anchor $anchor after normal removal"
        [[ -z "$rules" ]] || fail "PF anchor $anchor retained rules after normal removal"
    done
}

echo "Requesting one administrator approval for the local fixture."
sudo -v
sudo_keepalive_stop="$build_root/stop-sudo-keepalive"
(
    while [[ ! -e "$sudo_keepalive_stop" ]]; do
        sudo -n -v || exit 1
        /bin/sleep 30
    done
) &
sudo_keepalive_pid=$!
stop_sudo_keepalive() {
    : >"$sudo_keepalive_stop"
    wait "$sudo_keepalive_pid" || true
}
trap stop_sudo_keepalive EXIT
for anchor in "$main_anchor" "$standby_anchor"; do
    rules=$(sudo -n /sbin/pfctl -a "$anchor" -sr 2>/dev/null) \
        || fail "cannot inspect fixture PF anchor $anchor"
    [[ -z "$rules" ]] || fail "fixture PF anchor $anchor already has rules"
done

echo "Installing the active v8 handoff primary."
sudo -n "$live_primary_app/Contents/Resources/install-macos-service.sh"
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

hosts_path = Path(sys.argv[1])
domain = "handoff-fixture.example"
ip = "192.0.2.123"
markers = (
    ("# BEGIN HARD PAUSE FIXTURE — exact domains managed by org.hardpause.fixture.service", "# END HARD PAUSE FIXTURE"),
    ("# BEGIN HARD PAUSE FIXTURE STANDBY — org.hardpause.fixture.service.standby", "# END HARD PAUSE FIXTURE STANDBY"),
)
anchors = ("com.apple/hard-pause-fixture", "com.apple/hard-pause-fixture-standby")

def inspect():
    hosts = hosts_path.read_text(encoding="utf-8")
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
    for label in ("org.hardpause.fixture.service", "org.hardpause.fixture.service.standby"):
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

mode = sys.argv[2]
if mode == "watch":
    stop_path, output_path = map(Path, sys.argv[3:5])
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
    Path(sys.argv[3]).write_text(json.dumps(result, indent=2, sort_keys=True) + "\n",
                                 encoding="utf-8")
    print(json.dumps(result, sort_keys=True))
else:
    raise SystemExit(f"unknown mode: {mode}")
PY

sudo -n /usr/bin/python3 "$observer" "$fixture_hosts_file" main
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
trap 'stop_watcher; stop_sudo_keepalive' EXIT
sudo -n /usr/bin/python3 "$observer" "$fixture_hosts_file" watch "$watch_stop" "$watch_log" &
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
        /usr/bin/python3 "$HARD_PAUSE_FIXTURE_OBSERVER" "$HARD_PAUSE_FIXTURE_HOSTS" overlap "$HARD_PAUSE_FIXTURE_OVERLAP_REPORT" \\
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
    HARD_PAUSE_FIXTURE_HOSTS="$fixture_hosts_file" \
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
if /usr/bin/grep -Fq '# BEGIN HARD PAUSE FIXTURE STANDBY' "$fixture_hosts_file"; then
    fail "rollback did not retire the standby hosts section"
fi
[[ $(shasum -a 256 "$helper_dir/hard-pause-service" | awk '{ print $1 }') \
    == $(shasum -a 256 "$primary_service" | awk '{ print $1 }') ]] \
    || fail "rollback did not restore the prior primary service binary"
sudo -n /usr/bin/python3 "$observer" "$fixture_hosts_file" main
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
if /usr/bin/grep -Fq '# BEGIN HARD PAUSE FIXTURE STANDBY' "$fixture_hosts_file"; then
    fail "successful handoff left the standby hosts section"
fi
sudo -n /usr/bin/python3 "$observer" "$fixture_hosts_file" main
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
sudo -n "$installed_uninstaller"
assert_installation_empty
stop_sudo_keepalive
trap - EXIT

echo "Native service handoff fixture passed on macOS $(sw_vers -productVersion)."
echo "Proof limits: $artifact_dir/proof-limits.txt"
