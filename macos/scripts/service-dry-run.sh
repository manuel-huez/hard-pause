#!/bin/bash
set -euo pipefail

label="org.hardpause.service"
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
app_bundle=$(CDPATH='' cd -- "${script_dir}/../.." && pwd -P)

fail() {
    echo "hard-pause dry run: $*" >&2
    exit 1
}

[[ "${app_bundle}" == *.app ]] || fail "run this script from HardPause.app/Contents/Resources"
for name in hard-pause-service hard-pause "${label}.plist" install-macos-service.sh uninstall-macos-service.sh AGENTS.md; do
    [[ -f "${script_dir}/${name}" && ! -L "${script_dir}/${name}" ]] \
        || fail "missing or unsafe bundled file: ${name}"
done
worker_bundle="${script_dir}/HardPauseBrowserWorker.app"
[[ -d "${worker_bundle}" && ! -L "${worker_bundle}" ]] \
    || fail "missing or unsafe browser worker bundle"
/usr/bin/plutil -lint "${script_dir}/${label}.plist" >/dev/null
/usr/bin/codesign --verify --strict "${app_bundle}"
/usr/bin/codesign --verify --strict "${script_dir}/hard-pause-service"
/usr/bin/codesign --verify --strict "${script_dir}/hard-pause"
/usr/bin/codesign --verify --strict --deep "${worker_bundle}"

gui_requirement=$(/usr/bin/codesign --display --requirements - "${app_bundle}" 2>&1 \
    | /usr/bin/sed -n -e 's/^# designated => //p' -e 's/^designated => //p' \
    | /usr/bin/tail -n 1)
cli_requirement=$(/usr/bin/codesign --display --requirements - "${script_dir}/hard-pause" 2>&1 \
    | /usr/bin/sed -n -e 's/^# designated => //p' -e 's/^designated => //p' \
    | /usr/bin/tail -n 1)
[[ -n "${gui_requirement}" && -n "${cli_requirement}" ]] \
    || fail "the GUI or CLI has no designated code requirement"

cat <<EOF
Bundle validation passed.
App: ${app_bundle}
Service source: ${script_dir}/hard-pause-service
CLI source: ${script_dir}/hard-pause
Browser worker source: ${worker_bundle}
Launchd label: ${label}
No launchd, hosts, PF, state, application, or installation change was made.
EOF
