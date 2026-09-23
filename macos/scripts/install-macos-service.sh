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
Usage: sudo install-macos-service.sh [--update | --reenroll]

--update replaces the installed service and CLI while preserving the enrolled
user and approved code requirements. Every block must be inactive.
--reenroll replaces the enrolled user and pinned GUI/CLI code requirements.
For an existing installation, it also requires every block to be inactive.
EOF
    exit 64
}

reenroll=0
update_existing=0
case "${1:-}" in
    "") ;;
    --reenroll) reenroll=1 ;;
    --update) update_existing=1 ;;
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
if [[ ${update_existing} -eq 1 && ${managed_install} -ne 1 ]]; then
    fail "--update requires an existing managed enrollment"
fi
if [[ ${managed_install} -eq 1 && ${reenroll} -ne 1 && ${update_existing} -ne 1 ]]; then
    fail "an enrollment already exists; use --update to update code or --reenroll to replace it"
fi
if [[ ${managed_install} -eq 1 ]]; then
    /bin/cat "${guidance_source}" >&2
fi

existing_enrolled_uid=""
existing_requirements=()
if [[ ${managed_install} -eq 1 ]]; then
    existing_schema_version=$(/usr/bin/plutil -extract schemaVersion raw -expect integer -o - \
        "${enrollment_destination}" 2>/dev/null) \
        || fail "the existing enrollment schema cannot be read"
    [[ "${existing_schema_version}" == 1 ]] \
        || fail "the existing enrollment schema is unsupported"
    existing_enrolled_uid=$(/usr/bin/plutil -extract enrolledUID raw -expect integer -o - \
        "${enrollment_destination}" 2>/dev/null) \
        || fail "the enrolled user cannot be read from the existing enrollment"
    [[ "${existing_enrolled_uid}" =~ ^[0-9]+$ && "${existing_enrolled_uid}" -gt 0 ]] \
        || fail "the existing enrollment contains an invalid user"
    if [[ ${update_existing} -eq 1 ]]; then
        [[ "${existing_enrolled_uid}" == "${sudo_uid}" ]] \
            || fail "the existing enrollment belongs to a different user"
    fi

    /usr/bin/plutil -extract approvedClientRequirements xml1 -expect array -o /dev/null \
        "${enrollment_destination}" >/dev/null 2>&1 \
        || fail "the existing enrollment has an invalid code-requirements list"
    for requirement_index in 0 1 2 3 4 5 6 7; do
        if requirement=$(/usr/bin/plutil -extract "approvedClientRequirements.${requirement_index}" raw -expect string -o - \
            "${enrollment_destination}" 2>/dev/null); then
            [[ -n "${requirement}" ]] || fail "the existing enrollment contains an empty code requirement"
            existing_requirements+=("${requirement}")
        else
            break
        fi
    done
    [[ ${#existing_requirements[@]} -ge 1 ]] \
        || fail "the existing enrollment has no approved code requirements"
    if /usr/bin/plutil -extract "approvedClientRequirements.8" raw -expect string -o - "${enrollment_destination}" \
        >/dev/null 2>&1; then
        fail "the existing enrollment has too many approved code requirements"
    fi
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
update_gate_cleanup_needed=0
update_gate_token=""
update_gate_token_path="${stage}/update-gate-token"
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

release_update_gate() {
    [[ ${update_gate_cleanup_needed} -eq 1 ]] || return 0
    if /bin/launchctl print "system/${label}" >/dev/null 2>&1 \
        && /bin/launchctl asuser "${existing_enrolled_uid}" /usr/bin/sudo -u "#${existing_enrolled_uid}" \
            "${cli_source}" cancel-update "${update_gate_token}" \
            >"${stage}/cancel-update.json" 2>"${stage}/cancel-update.stderr"; then
        update_gate_cleanup_needed=0
        return 0
    fi
    preserve_stage=1
    echo "hard-pause installer: the service update gate could not be cancelled." >&2
    echo "hard-pause installer: the recovery token is retained at ${update_gate_token_path}." >&2
    return 1
}

finish_install() {
    local installer_exit_code=$?
    trap - EXIT
    if [[ ${installer_exit_code} -ne 0 && ${rollback_armed} -eq 1 ]]; then
        rollback_install
    fi
    if [[ ${installer_exit_code} -ne 0 && ${update_gate_cleanup_needed} -eq 1 ]]; then
        release_update_gate || true
    fi
    if [[ ${preserve_stage} -eq 0 ]]; then
        /bin/rm -rf -- "${stage}"
    fi
    exit "${installer_exit_code}"
}
trap finish_install EXIT

verify_inactive_snapshot() {
    local snapshot=$1
    local plist_snapshot="${snapshot}.plist"
    local index=0
    local phase
    local inactive_keys
    local is_enforcing
    local issue_count
    local contributor_count
    /usr/bin/sed -E 's/:[[:space:]]*null([,}])/: ""\1/g' "${snapshot}" >"${plist_snapshot}" \
        || fail "the installed CLI returned an unreadable protected-state list"
    /usr/bin/plutil -extract blocks xml1 -expect array -o /dev/null "${plist_snapshot}" >/dev/null 2>&1 \
        || fail "the installed CLI returned an unreadable protected-state list"
    is_enforcing=$(/usr/bin/plutil -extract protection.isEnforcing raw -expect bool -o - "${plist_snapshot}" 2>/dev/null) \
        || fail "the installed CLI returned an unreadable protection status"
    [[ "${is_enforcing}" == true ]] \
        || fail "the installed CLI reports protection is not enforcing; update stopped"
    issue_count=$(/usr/bin/plutil -extract protection.issues raw -expect array -o - "${plist_snapshot}" 2>/dev/null) \
        || fail "the installed CLI returned an unreadable protection issue list"
    [[ "${issue_count}" == 0 ]] \
        || fail "the installed CLI reports protection issues; update stopped"
    contributor_count=$(
        /usr/bin/plutil -extract effectiveRestrictions.contributingBlockIDs raw -expect array -o - \
            "${plist_snapshot}" 2>/dev/null
    ) || fail "the installed CLI returned an unreadable restriction ownership list"
    [[ "${contributor_count}" == 0 ]] \
        || fail "the installed CLI reports enforced restrictions; update stopped"
    while [[ ${index} -lt 128 ]]; do
        if phase=$(
            /usr/bin/plutil -extract "blocks.${index}.phase" raw -expect dictionary -o - "${plist_snapshot}" \
                2>/dev/null
        ); then
            [[ "${phase}" == inactive ]] \
                || fail "the installed CLI reports an active or unknown block; update stopped"
            inactive_keys=$(/usr/bin/plutil -extract "blocks.${index}.phase.inactive" raw -expect dictionary -o - \
                "${plist_snapshot}" 2>/dev/null) \
                || fail "the installed CLI returned an invalid inactive block phase"
            [[ -z "${inactive_keys}" ]] \
                || fail "the installed CLI returned an invalid inactive block phase"
        elif /usr/bin/plutil -extract "blocks.${index}" xml1 -o /dev/null "${plist_snapshot}" >/dev/null 2>&1; then
            fail "the installed CLI returned a block with an unreadable phase"
        else
            return 0
        fi
        index=$((index + 1))
    done
    if /usr/bin/plutil -extract "blocks.${index}" xml1 -o /dev/null "${plist_snapshot}" >/dev/null 2>&1; then
        fail "the installed CLI returned too many blocks to verify safely"
    fi
}

verify_staged_requirement() {
    local role=$1
    local path=$2
    local requirement
    for requirement in "${existing_requirements[@]}"; do
        if /usr/bin/codesign --verify --strict -R="${requirement}" "${path}" >/dev/null 2>&1; then
            return 0
        fi
    done
    fail "the staged ${role} does not satisfy any enrolled code requirement"
}

verify_existing_inactive_blocks() {
    local snapshot=$1
    [[ -x "${cli_destination}" && ! -L "${cli_destination}" ]] \
        || fail "--update requires the existing installed CLI"
    /bin/launchctl print "system/${label}" >/dev/null 2>&1 \
        || fail "--update requires the existing service to be running"
    local existing_health="${stage}/${snapshot}"
    /bin/launchctl asuser "${existing_enrolled_uid}" /usr/bin/sudo -u "#${existing_enrolled_uid}" \
        "${cli_destination}" list >"${existing_health}" 2>"${stage}/${snapshot}.stderr" \
        || fail "the installed CLI could not authenticate and list protected state; update stopped"
    verify_inactive_snapshot "${existing_health}"
    if [[ ${reenroll} -eq 1 ]]; then
        /bin/launchctl asuser "${existing_enrolled_uid}" /usr/bin/sudo -u "#${existing_enrolled_uid}" \
            "${cli_destination}" can-uninstall >"${stage}/existing-can-uninstall.txt" \
            2>"${stage}/existing-can-uninstall.stderr" \
            || fail "the installed service reports protection that prevents reenrollment"
    fi
}

if [[ ${managed_install} -eq 1 ]]; then
    verify_existing_inactive_blocks "existing-health-check.json"
fi

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
if [[ ${update_existing} -eq 1 ]]; then
    verify_staged_requirement "GUI" "${app_bundle}"
    verify_staged_requirement "CLI" "${stage}/hard-pause"
else
    enrollment_stage="${stage}/enrollment-v1.json"
    /usr/bin/plutil -create xml1 "${enrollment_stage}"
    /usr/bin/plutil -insert schemaVersion -integer 1 "${enrollment_stage}"
    /usr/bin/plutil -insert enrolledUID -integer "${sudo_uid}" "${enrollment_stage}"
    /usr/bin/plutil -insert approvedClientRequirements -array "${enrollment_stage}"
    /usr/bin/plutil -insert approvedClientRequirements.0 -string "${gui_requirement}" "${enrollment_stage}"
    /usr/bin/plutil -insert approvedClientRequirements.1 -string "${cli_requirement}" "${enrollment_stage}"
    /usr/bin/plutil -convert json "${enrollment_stage}"
    /bin/chmod 0600 "${enrollment_stage}"
fi

/usr/bin/install -d -m 0700 "${stage}/rollback"
for index in "${!managed_destinations[@]}"; do
    if [[ -e "${managed_destinations[${index}]}" ]]; then
        /bin/cp -p "${managed_destinations[${index}]}" \
            "${stage}/rollback/${backup_names[${index}]}"
        had_previous[index]=1
    fi
done

if [[ ${update_existing} -eq 1 ]]; then
    update_gate_token=$(/usr/bin/uuidgen) || fail "could not create an update gate token"
    /usr/bin/printf '%s\n' "${update_gate_token}" >"${update_gate_token_path}"
    /bin/chmod 0600 "${update_gate_token_path}"
    update_gate_cleanup_needed=1
    /bin/launchctl asuser "${existing_enrolled_uid}" /usr/bin/sudo -u "#${existing_enrolled_uid}" \
        "${cli_source}" prepare-update "${update_gate_token}" \
        >"${stage}/update-gate-health-check.json" 2>"${stage}/update-gate-health-check.stderr" \
        || fail "the installed service could not prepare safely for the update"
    verify_inactive_snapshot "${stage}/update-gate-health-check.json"
fi

if /bin/launchctl print "system/${label}" >/dev/null 2>&1; then
    [[ ${managed_install} -eq 1 ]] \
        || fail "a launchd job already uses ${label}, but Hard Pause does not own this installation"
    /bin/launchctl bootout "system/${label}" >/dev/null 2>&1 \
        || fail "the existing service could not be stopped; no files were changed"
    previous_service_loaded=1
fi
rollback_armed=1
if [[ ${managed_install} -eq 1 && ${reenroll} -eq 1 ]]; then
    "${service_destination}" --verify-uninstall-offline \
        || fail "durable protection changed before reenrollment; the previous service will be restarted"
fi

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
if [[ ${update_existing} -eq 0 ]]; then
    /usr/bin/install -o root -g wheel -m 0600 "${enrollment_stage}" "${enrollment_destination}"
fi
/usr/bin/install -o root -g wheel -m 0644 "${stage}/AGENTS.md" "${guidance_destination}"
/usr/bin/install -o root -g wheel -m 0600 "${stage}/AGENTS.md" "${state_guidance_destination}"

/bin/launchctl bootstrap system "${plist_destination}" \
    || fail "launchd could not bootstrap ${label}"
/bin/launchctl enable "system/${label}" \
    || fail "launchd could not enable ${label}"
/bin/launchctl kickstart -k "system/${label}" \
    || fail "launchd could not start ${label}"
if [[ ${update_existing} -eq 1 ]]; then
    rollback_armed=0
    /bin/launchctl asuser "${sudo_uid}" /usr/bin/sudo -u "#${sudo_uid}" \
        "${cli_destination}" cancel-update "${update_gate_token}" >"${stage}/health-check.json" \
        || fail "the installed service did not release its update gate"
    verify_inactive_snapshot "${stage}/health-check.json"
    update_gate_cleanup_needed=0
else
    /bin/launchctl asuser "${sudo_uid}" /usr/bin/sudo -u "#${sudo_uid}" \
        "${cli_destination}" list >"${stage}/health-check.json" \
        || fail "the installed service did not pass its authenticated health check"
    if [[ ${managed_install} -eq 1 ]]; then
        verify_inactive_snapshot "${stage}/health-check.json"
    fi
    rollback_armed=0
fi

echo "Hard Pause enrolled user ${sudo_user} (${sudo_uid}) and started ${label}."
echo "Installed CLI: ${cli_destination}"
echo "Agent maintenance guidance: ${guidance_destination}"
