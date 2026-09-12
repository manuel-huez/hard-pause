#!/bin/bash
# AI agents: read the adjacent AGENTS.md before maintenance. Preserve active
# blocks and their delays; do not use reinstallation to defeat a user's commitment.
set -euo pipefail

label="org.hardpause.service"
support_dir="/Library/Application Support/HardPause"
helper_dir="/Library/PrivilegedHelperTools/HardPause"
service_destination="${helper_dir}/hard-pause-service"
cli_destination="${helper_dir}/hard-pause"
uninstaller_destination="${helper_dir}/hard-pause-uninstall"
plist_destination="/Library/LaunchDaemons/${label}.plist"
enrollment_destination="${support_dir}/enrollment-v1.json"
guidance_destination="${helper_dir}/AGENTS.md"
state_guidance_destination="${support_dir}/AGENTS.md"

fail() {
    echo "hard-pause installer: $*" >&2
    exit 1
}

usage() {
    cat >&2 <<'EOF'
Usage: sudo install-macos-service.sh [--reenroll]

--reenroll replaces the enrolled user and pinned GUI/CLI code requirements.
EOF
    exit 64
}

reenroll=0
case "${1:-}" in
    "") ;;
    --reenroll) reenroll=1 ;;
    *) usage ;;
esac
[[ $# -le 1 ]] || usage
[[ ${EUID} -eq 0 ]] || fail "run this app-bundled script with sudo"

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
app_bundle=$(CDPATH='' cd -- "${script_dir}/../.." && pwd -P)
service_source="${script_dir}/hard-pause-service"
cli_source="${script_dir}/hard-pause"
plist_source="${script_dir}/${label}.plist"
uninstaller_source="${script_dir}/uninstall-macos-service.sh"
guidance_source="${script_dir}/AGENTS.md"

[[ "${app_bundle}" == *.app ]] || fail "the installer must run from HardPause.app/Contents/Resources"
for source in "${service_source}" "${cli_source}" "${plist_source}" "${uninstaller_source}" "${guidance_source}"; do
    [[ -f "${source}" && ! -L "${source}" ]] || fail "missing or unsafe bundled file: ${source}"
done
[[ $(/usr/bin/stat -f '%z' "${guidance_source}") -le 16384 ]] || fail "the bundled agent guidance is too large"
/usr/bin/plutil -lint "${plist_source}" >/dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :Label' "${plist_source}")" == "${label}" ]] \
    || fail "the bundled launchd label is invalid"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "${plist_source}")" == "${service_destination}" ]] \
    || fail "the bundled launchd service path is invalid"

sudo_uid=${SUDO_UID:-}
sudo_user=${SUDO_USER:-}
[[ "${sudo_uid}" =~ ^[0-9]+$ && "${sudo_uid}" -gt 0 ]] \
    || fail "sudo did not provide a non-root invoking user"
[[ -n "${sudo_user}" && "${sudo_user}" != "root" ]] \
    || fail "sudo did not provide a non-root invoking account"
resolved_sudo_uid=$(/usr/bin/id -u "${sudo_user}")
[[ "${resolved_sudo_uid}" == "${sudo_uid}" ]] || fail "SUDO_USER and SUDO_UID do not match"
console_uid=$(/usr/bin/stat -f '%u' /dev/console)
[[ "${console_uid}" == "${sudo_uid}" ]] \
    || fail "the invoking user must be the current console user"

managed_install=0
if [[ -e "${enrollment_destination}" ]]; then
    [[ -f "${enrollment_destination}" && ! -L "${enrollment_destination}" ]] \
        || fail "the existing enrollment path is unsafe"
    [[ "$(/usr/bin/stat -f '%u' "${enrollment_destination}")" == 0 ]] \
        || fail "the existing enrollment is not root-owned"
    managed_install=1
fi
if [[ ${managed_install} -eq 1 && ${reenroll} -ne 1 ]]; then
    fail "an enrollment already exists; use --reenroll only when you intend to replace it"
fi
if [[ ${managed_install} -eq 1 ]]; then
    /bin/cat "${guidance_source}" >&2
fi

validate_parent() {
    local path=$1
    [[ -d "${path}" && ! -L "${path}" ]] || fail "required parent is missing or unsafe: ${path}"
    [[ "$(/usr/bin/stat -f '%u' "${path}")" == 0 ]] || fail "required parent is not root-owned: ${path}"
}

validate_destination() {
    local path=$1
    [[ ! -L "${path}" ]] || fail "refusing a symbolic-link destination: ${path}"
    if [[ -e "${path}" ]]; then
        [[ ${managed_install} -eq 1 ]] || fail "refusing to replace an unrelated file: ${path}"
        [[ -f "${path}" && "$(/usr/bin/stat -f '%u' "${path}")" == 0 ]] \
            || fail "the existing managed destination is unsafe: ${path}"
    fi
}

validate_parent /Library/PrivilegedHelperTools
validate_parent /Library/LaunchDaemons
for destination in "${service_destination}" "${cli_destination}" "${uninstaller_destination}" "${plist_destination}" "${guidance_destination}" "${state_guidance_destination}"; do
    validate_destination "${destination}"
done

stage=$(/usr/bin/mktemp -d "/tmp/hard-pause-install.XXXXXX")
/bin/chmod 0700 "${stage}"
rollback_armed=0
previous_service_loaded=0
preserve_stage=0
managed_destinations=(
    "${service_destination}"
    "${cli_destination}"
    "${uninstaller_destination}"
    "${plist_destination}"
    "${enrollment_destination}"
    "${guidance_destination}"
    "${state_guidance_destination}"
)
backup_names=(
    hard-pause-service
    hard-pause
    hard-pause-uninstall
    "${label}.plist"
    enrollment-v1.json
    helper-AGENTS.md
    state-AGENTS.md
)
had_previous=(0 0 0 0 0 0 0)

rollback_install() {
    set +e
    local rollback_ok=1
    local index
    if /bin/launchctl print "system/${label}" >/dev/null 2>&1; then
        /bin/launchctl bootout "system/${label}" >/dev/null 2>&1 || rollback_ok=0
    fi
    if [[ ${rollback_ok} -eq 1 ]]; then
        for index in "${!managed_destinations[@]}"; do
            if [[ "${had_previous[${index}]}" -eq 1 ]]; then
                /bin/cp -p "${stage}/rollback/${backup_names[${index}]}" \
                    "${managed_destinations[${index}]}" || rollback_ok=0
            else
                /bin/rm -f -- "${managed_destinations[${index}]}" || rollback_ok=0
            fi
        done
    fi
    if [[ ${rollback_ok} -eq 1 && ${previous_service_loaded} -eq 1 ]]; then
        /bin/launchctl bootstrap system "${plist_destination}" >/dev/null 2>&1 \
            && /bin/launchctl enable "system/${label}" >/dev/null 2>&1 \
            && /bin/launchctl kickstart -k "system/${label}" >/dev/null 2>&1 \
            || rollback_ok=0
    fi
    if [[ ${rollback_ok} -eq 1 ]]; then
        if [[ ${managed_install} -eq 1 && ${previous_service_loaded} -eq 1 ]]; then
            echo "hard-pause installer: the previous managed files were restored and the previous service was restarted." >&2
        elif [[ ${managed_install} -eq 1 ]]; then
            echo "hard-pause installer: the previous managed files were restored; the previous service was not running." >&2
        else
            echo "hard-pause installer: the new managed files were removed; support state was retained at ${support_dir}." >&2
        fi
    else
        preserve_stage=1
        echo "hard-pause installer: automatic rollback is incomplete; no state was deleted." >&2
        echo "hard-pause installer: rollback evidence is retained at ${stage}." >&2
    fi
}

finish_install() {
    local installer_exit_code=$?
    trap - EXIT
    if [[ ${installer_exit_code} -ne 0 && ${rollback_armed} -eq 1 ]]; then
        rollback_install
    fi
    if [[ ${preserve_stage} -eq 0 ]]; then
        /bin/rm -rf -- "${stage}"
    fi
    exit "${installer_exit_code}"
}
trap finish_install EXIT

/usr/bin/install -m 0755 "${service_source}" "${stage}/hard-pause-service"
/usr/bin/install -m 0755 "${cli_source}" "${stage}/hard-pause"
/usr/bin/install -m 0755 "${uninstaller_source}" "${stage}/hard-pause-uninstall"
/usr/bin/install -m 0644 "${plist_source}" "${stage}/${label}.plist"
/usr/bin/install -m 0644 "${guidance_source}" "${stage}/AGENTS.md"

# Preserve build signatures and their stable identities; installation must not
# replace certificate signatures with per-build ad-hoc hashes.
/usr/bin/codesign --verify --strict "${stage}/hard-pause-service"
/usr/bin/codesign --verify --strict "${stage}/hard-pause"
/usr/bin/codesign --verify --strict "${app_bundle}"

extract_requirement() {
    local path=$1
    local output
    local requirement
    output=$(/usr/bin/codesign --display --requirements - "${path}" 2>&1) \
        || fail "cannot read the code requirement for ${path}"
    requirement=$(printf '%s\n' "${output}" \
        | /usr/bin/sed -n -e 's/^# designated => //p' -e 's/^designated => //p' \
        | /usr/bin/tail -n 1)
    [[ -n "${requirement}" ]] || fail "${path} has no designated code requirement"
    printf '%s' "${requirement}"
}

gui_requirement=$(extract_requirement "${app_bundle}")
cli_requirement=$(extract_requirement "${stage}/hard-pause")
enrollment_stage="${stage}/enrollment-v1.json"
/usr/bin/plutil -create xml1 "${enrollment_stage}"
/usr/bin/plutil -insert schemaVersion -integer 1 "${enrollment_stage}"
/usr/bin/plutil -insert enrolledUID -integer "${sudo_uid}" "${enrollment_stage}"
/usr/bin/plutil -insert approvedClientRequirements -array "${enrollment_stage}"
/usr/bin/plutil -insert approvedClientRequirements.0 -string "${gui_requirement}" "${enrollment_stage}"
/usr/bin/plutil -insert approvedClientRequirements.1 -string "${cli_requirement}" "${enrollment_stage}"
/usr/bin/plutil -convert json "${enrollment_stage}"
/bin/chmod 0600 "${enrollment_stage}"

/usr/bin/install -d -m 0700 "${stage}/rollback"
for index in "${!managed_destinations[@]}"; do
    if [[ -e "${managed_destinations[${index}]}" ]]; then
        /bin/cp -p "${managed_destinations[${index}]}" \
            "${stage}/rollback/${backup_names[${index}]}"
        had_previous[index]=1
    fi
done

if /bin/launchctl print "system/${label}" >/dev/null 2>&1; then
    [[ ${managed_install} -eq 1 ]] \
        || fail "a launchd job already uses ${label}, but Hard Pause does not own this installation"
    /bin/launchctl bootout "system/${label}" >/dev/null 2>&1 \
        || fail "the existing service could not be stopped; no files were changed"
    previous_service_loaded=1
fi
rollback_armed=1

if [[ -e "${support_dir}" ]]; then
    [[ -d "${support_dir}" && ! -L "${support_dir}" ]] || fail "the support directory is unsafe"
    [[ "$(/usr/bin/stat -f '%u' "${support_dir}")" == 0 ]] || fail "the support directory is not root-owned"
    /bin/chmod 0700 "${support_dir}"
else
    /usr/bin/install -d -o root -g wheel -m 0700 "${support_dir}"
fi
if [[ -e "${helper_dir}" ]]; then
    [[ -d "${helper_dir}" && ! -L "${helper_dir}" ]] || fail "the helper directory is unsafe"
    [[ "$(/usr/bin/stat -f '%u' "${helper_dir}")" == 0 ]] || fail "the helper directory is not root-owned"
    /bin/chmod 0755 "${helper_dir}"
else
    /usr/bin/install -d -o root -g wheel -m 0755 "${helper_dir}"
fi
/usr/bin/install -o root -g wheel -m 0755 "${stage}/hard-pause-service" "${service_destination}"
/usr/bin/install -o root -g wheel -m 0755 "${stage}/hard-pause" "${cli_destination}"
/usr/bin/install -o root -g wheel -m 0755 "${stage}/hard-pause-uninstall" "${uninstaller_destination}"
/usr/bin/install -o root -g wheel -m 0644 "${stage}/${label}.plist" "${plist_destination}"
/usr/bin/install -o root -g wheel -m 0600 "${enrollment_stage}" "${enrollment_destination}"
/usr/bin/install -o root -g wheel -m 0644 "${stage}/AGENTS.md" "${guidance_destination}"
/usr/bin/install -o root -g wheel -m 0600 "${stage}/AGENTS.md" "${state_guidance_destination}"

/bin/launchctl bootstrap system "${plist_destination}" \
    || fail "launchd could not bootstrap ${label}"
/bin/launchctl enable "system/${label}" \
    || fail "launchd could not enable ${label}"
/bin/launchctl kickstart -k "system/${label}" \
    || fail "launchd could not start ${label}"
/bin/launchctl asuser "${sudo_uid}" /usr/bin/sudo -u "#${sudo_uid}" \
    "${cli_destination}" list >"${stage}/health-check.json" \
    || fail "the installed service did not pass its authenticated health check"

rollback_armed=0

echo "Hard Pause enrolled user ${sudo_user} (${sudo_uid}) and started ${label}."
echo "Installed CLI: ${cli_destination}"
echo "Agent maintenance guidance: ${guidance_destination}"
