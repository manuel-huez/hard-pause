#!/bin/bash
# AI agents: read the adjacent AGENTS.md before maintenance. Preserve active
# blocks and their delays; do not use reinstallation to defeat a user's commitment.
set -euo pipefail

label="org.hardpause.service"
browser_worker_label="org.hardpause.browser-worker"
support_dir="/Library/Application Support/HardPause"
helper_dir="/Library/PrivilegedHelperTools/HardPause"
browser_worker_root="${helper_dir}/BrowserWorker"
service_destination="${helper_dir}/hard-pause-service"
cli_destination="${helper_dir}/hard-pause"
uninstaller_destination="${helper_dir}/hard-pause-uninstall"
plist_destination="/Library/LaunchDaemons/${label}.plist"
browser_worker_plist_destination="/Library/LaunchAgents/${browser_worker_label}.plist"
enrollment_destination="${support_dir}/enrollment-v1.json"
guidance_destination="${helper_dir}/AGENTS.md"
state_guidance_destination="${support_dir}/AGENTS.md"
installed_build_destination="${support_dir}/installed-build-v1"

fail() {
    echo "hard-pause installer: $*" >&2
    exit 1
}

usage() {
    cat >&2 <<'EOF'
Usage: sudo install-macos-service.sh [--update | --live-update | --active-legacy-update | --reenroll]

--update replaces the installed service and CLI while preserving the enrolled
user and approved code requirements. Every block must be inactive.
--live-update transfers an active v8 service to a signed successor while the
browser worker and overlapping service enforcement remain available.
--active-legacy-update migrates an active v2 service when Screen Time protection
is inactive and no applications are blocked. Native rules stay installed while
the new service is checked.
--reenroll replaces the enrolled user and pinned GUI/CLI code requirements.
For an existing installation, it also requires every block to be inactive.
EOF
    exit 64
}

reenroll=0
update_existing=0
live_update=0
active_legacy_migration=0
case "${1:-}" in
    "") ;;
    --reenroll) reenroll=1 ;;
    --update) update_existing=1 ;;
    --live-update) live_update=1 ;;
    --active-legacy-update) update_existing=1; active_legacy_migration=1 ;;
    *) usage ;;
esac
[[ $# -le 1 ]] || usage
[[ ${EUID} -eq 0 ]] || fail "run this app-bundled script with sudo"

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
app_bundle=$(CDPATH='' cd -- "${script_dir}/../.." && pwd -P)
retry_claim_preflight_allowed=0
if [[ ( ${update_existing} -eq 1 || ${live_update} -eq 1 ) \
    && "${app_bundle}" == "${helper_dir}/ServiceUpdates/"*"/HardPause.app" ]]; then
    retry_claim_preflight_allowed=1
fi

release_retry_claim() {
    local suffix ticket marker
    [[ "${app_bundle}" == "${helper_dir}/ServiceUpdates/"*"/HardPause.app" ]] || return 0
    suffix=${app_bundle#"${helper_dir}/ServiceUpdates/"}
    ticket=${suffix%/HardPause.app}
    [[ "${ticket}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || return 1
    marker="${support_dir}/service-updates/active"
    [[ -f "${marker}" && ! -L "${marker}" ]] || return 1
    [[ "$(/usr/bin/stat -f '%u:%Lp' "${marker}")" == "0:600" ]] || return 1
    [[ "$(/bin/cat "${marker}")" == "${ticket}" ]] || return 1
    /bin/rm -f -- "${marker}"
}

finish_preflight() {
    local installer_exit_code=$?
    local stage_path=${stage:-}
    trap - EXIT
    if [[ "${stage_path}" == /tmp/hard-pause-install.* && -d "${stage_path}" && ! -L "${stage_path}" ]]; then
        /bin/rm -rf -- "${stage_path}" \
            || echo "hard-pause installer: could not remove the preflight stage at ${stage_path}." >&2
    fi
    if [[ ${installer_exit_code} -ne 0 && ${retry_claim_preflight_allowed} -eq 1 ]] \
        && release_retry_claim; then
        exit 75
    fi
    exit "${installer_exit_code}"
}

if [[ ${retry_claim_preflight_allowed} -eq 1 ]]; then
    trap finish_preflight EXIT
fi

service_source="${script_dir}/hard-pause-service"
cli_source="${script_dir}/hard-pause"
plist_source="${script_dir}/${label}.plist"
uninstaller_source="${script_dir}/uninstall-macos-service.sh"
guidance_source="${script_dir}/AGENTS.md"
browser_worker_source="${script_dir}/HardPauseBrowserWorker.app"

[[ "${app_bundle}" == *.app ]] || fail "the installer must run from HardPause.app/Contents/Resources"
for source in "${service_source}" "${cli_source}" "${plist_source}" "${uninstaller_source}" "${guidance_source}"; do
    [[ -f "${source}" && ! -L "${source}" ]] || fail "missing or unsafe bundled file: ${source}"
done
[[ -d "${browser_worker_source}" && ! -L "${browser_worker_source}" ]] \
    || fail "missing or unsafe bundled browser worker"
[[ -f "${browser_worker_source}/Contents/MacOS/HardPauseBrowserWorker" ]] \
    || fail "the bundled browser worker executable is missing"
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
if [[ $((update_existing + live_update)) -eq 1 && ${managed_install} -ne 1 ]]; then
    fail "updating requires an existing managed enrollment"
fi
if [[ ${managed_install} -eq 1 && ${reenroll} -ne 1 && ${update_existing} -ne 1 && ${live_update} -ne 1 ]]; then
    fail "an enrollment already exists; use an update mode or --reenroll"
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
    if [[ ${update_existing} -eq 1 || ${live_update} -eq 1 ]]; then
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
validate_parent /Library/LaunchAgents
for destination in "${service_destination}" "${cli_destination}" "${uninstaller_destination}" "${plist_destination}" "${guidance_destination}" "${state_guidance_destination}"; do
    validate_destination "${destination}"
done
validate_destination "${browser_worker_plist_destination}"

stage=$(/usr/bin/mktemp -d "/tmp/hard-pause-install.XXXXXX")
/bin/chmod 0700 "${stage}"
rollback_armed=0
previous_service_loaded=0
preserve_stage=0
install_complete=0
live_stage=""
live_started=0
live_old_stopped=0
live_finalization_started=0
live_success=0
inactive_migration=0
migration_finalization_started=0
migration_stage=""
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
    local safe_update_retry=0
    trap - EXIT
    if [[ ${installer_exit_code} -eq 0 && ${install_complete} -eq 0 ]]; then
        installer_exit_code=1
    fi
    if [[ ${live_update} -eq 1 ]]; then
        if [[ ${installer_exit_code} -ne 0 && ${live_started} -eq 1 && ${live_finalization_started} -eq 0 ]]; then
            if recover_live_update; then
                safe_update_retry=1
            else
                preserve_stage=1
            fi
        elif [[ ${installer_exit_code} -ne 0 && ${live_finalization_started} -eq 1 ]]; then
            preserve_stage=1
            echo "hard-pause installer: finalization may have committed; do not restore the old service." >&2
        elif [[ ${installer_exit_code} -ne 0 && ${live_started} -eq 0 ]]; then
            safe_update_retry=1
        fi
    elif [[ ${installer_exit_code} -ne 0 && ${retry_claim_preflight_allowed} -eq 1 ]]; then
        safe_update_retry=1
    fi
    if [[ ${safe_update_retry} -eq 1 ]] && ! release_retry_claim; then
        safe_update_retry=0
        preserve_stage=1
        echo "hard-pause installer: the safe update claim could not be released." >&2
    fi
    if [[ ${live_update} -eq 1 ]]; then
        if [[ ( ${live_success} -eq 1 || ${live_started} -eq 0 ) \
            && ${preserve_stage} -eq 0 && -n "${live_stage}" ]]; then
            /bin/rm -rf -- "${live_stage}"
        elif [[ -n "${live_stage}" ]]; then
            echo "hard-pause installer: update evidence retained at ${live_stage}." >&2
        fi
    elif [[ ${installer_exit_code} -ne 0 && ${migration_finalization_started} -eq 1 ]]; then
        preserve_stage=1
        echo "hard-pause installer: legacy migration may have committed; do not restore v2." >&2
        echo "hard-pause installer: recovery evidence is retained at ${migration_stage}." >&2
    elif [[ ${installer_exit_code} -ne 0 && ${rollback_armed} -eq 1 ]]; then
        rollback_install
    fi
    if [[ ${live_update} -eq 0 && ${installer_exit_code} -ne 0 && ${update_gate_cleanup_needed} -eq 1 ]]; then
        release_update_gate || true
    fi
    if [[ ${preserve_stage} -eq 0 ]]; then
        /bin/rm -rf -- "${stage}"
        if [[ -n "${migration_stage}" ]]; then
            /bin/rm -rf -- "${migration_stage}"
        fi
    fi
    # The privileged update job may release its claim only when this script
    # either never froze the service or verified that the old service resumed.
    if [[ ${safe_update_retry} -eq 1 ]]; then
        exit 75
    fi
    exit "${installer_exit_code}"
}
trap finish_install EXIT

verify_inactive_snapshot() {
    local snapshot=$1
    local expect_active=${2:-0}
    local plist_snapshot="${snapshot}.plist"
    local index=0
    local active_count=0
    local phase
    local inactive_keys
    local is_enforcing
    local issue_count
    local contributor_count
    local application_count
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
    if [[ ${expect_active} -eq 0 ]]; then
        [[ "${contributor_count}" == 0 ]] \
            || fail "the installed CLI reports enforced restrictions; update stopped"
    else
        application_count=$(/usr/bin/plutil -extract effectiveRestrictions.blockedApplications raw -expect array -o - \
            "${plist_snapshot}" 2>/dev/null) \
            || fail "the installed CLI returned an unreadable application restriction list"
        [[ "${application_count}" == 0 ]] \
            || fail "active legacy migration cannot transfer blocked applications"
    fi
    while [[ ${index} -lt 128 ]]; do
        if phase=$(
            /usr/bin/plutil -extract "blocks.${index}.phase" raw -expect dictionary -o - "${plist_snapshot}" \
                2>/dev/null
        ); then
            if [[ "${phase}" == inactive ]]; then
                inactive_keys=$(/usr/bin/plutil -extract "blocks.${index}.phase.inactive" raw -expect dictionary -o - \
                    "${plist_snapshot}" 2>/dev/null) \
                    || fail "the installed CLI returned an invalid inactive block phase"
                [[ -z "${inactive_keys}" ]] \
                    || fail "the installed CLI returned an invalid inactive block phase"
            elif [[ ${expect_active} -eq 1 && "${phase}" =~ ^(active|waitingForBreak|waitingForFullUnlock|breakActive)$ ]]; then
                active_count=$((active_count + 1))
            else
                fail "the installed CLI reports an active or unknown block; update stopped"
            fi
        elif /usr/bin/plutil -extract "blocks.${index}" xml1 -o /dev/null "${plist_snapshot}" >/dev/null 2>&1; then
            fail "the installed CLI returned a block with an unreadable phase"
        else
            [[ ${expect_active} -eq 0 || ${active_count} -gt 0 ]] \
                || fail "the installed CLI reports no active block for legacy migration"
            return 0
        fi
        index=$((index + 1))
    done
    if /usr/bin/plutil -extract "blocks.${index}" xml1 -o /dev/null "${plist_snapshot}" >/dev/null 2>&1; then
        fail "the installed CLI returned too many blocks to verify safely"
    fi
    [[ ${expect_active} -eq 0 || ${active_count} -gt 0 ]] \
        || fail "the installed CLI reports no active block for legacy migration"
}

verify_same_restrictions() {
    local previous=$1
    local successor=$2
    /usr/bin/plutil -extract effectiveRestrictions json -o "${previous}.restrictions" \
        "${previous}.plist" || fail "the previous restriction list is unreadable"
    /usr/bin/plutil -extract effectiveRestrictions json -o "${successor}.restrictions" \
        "${successor}.plist" || fail "the successor restriction list is unreadable"
    /usr/bin/cmp -s "${previous}.restrictions" "${successor}.restrictions" \
        || fail "the successor did not report the same active restrictions"
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

run_enrolled_cli() {
    local cli=$1
    local output=$2
    shift 2
    /bin/launchctl asuser "${existing_enrolled_uid}" /usr/bin/sudo -u "#${existing_enrolled_uid}" \
        "${cli}" "$@" >"${output}" 2>"${output}.stderr"
}

verify_native_update_compatibility() {
    [[ "${installed_service_version}" -lt 11 ]] || return 0
    local output="${stage}/apple-update-status.json" phase
    run_enrolled_cli "${cli_source}" "${output}" apple-status \
        || fail "Screen Time status could not be checked before the update"
    phase=$(/usr/bin/plutil -extract phase raw -expect string -o - "${output}" 2>/dev/null) \
        || fail "Screen Time status is unreadable"
    [[ "${phase}" == inactive ]] \
        || fail "this upgrade requires older managed Screen Time protection to finish normally first"
}

verify_live_status() {
    local output=$1
    local expected_phase=$2
    local expected_enforcing=${3:-true}
    local phase enforcing issues generation state_digest apple_digest successor_digest
    phase=$(/usr/bin/plutil -extract phase raw -expect string -o - "${output}" 2>/dev/null) \
        || fail "the live-update phase is unreadable"
    [[ "${phase}" == "${expected_phase}" ]] || fail "unexpected live-update phase: ${phase}"
    enforcing=$(/usr/bin/plutil -extract isEnforcing raw -expect bool -o - "${output}" 2>/dev/null) \
        || fail "the live-update enforcement status is unreadable"
    [[ "${enforcing}" == "${expected_enforcing}" ]] \
        || fail "live-update enforcement status does not match ${expected_phase}"
    issues=$(/usr/bin/plutil -extract issues raw -expect array -o - "${output}" 2>/dev/null) \
        || fail "the live-update issue list is unreadable"
    [[ "${issues}" == 0 ]] || fail "live-update protection reports issues"
    generation=$(/usr/bin/plutil -extract generation raw -expect string -o - "${output}" 2>/dev/null) \
        || fail "the live-update generation is unreadable"
    state_digest=$(/usr/bin/plutil -extract stateDigest raw -expect string -o - "${output}" 2>/dev/null) \
        || fail "the live-update state digest is unreadable"
    apple_digest=$(/usr/bin/plutil -extract appleStateDigest raw -expect string -o - "${output}" 2>/dev/null) \
        || fail "the live-update Apple-state digest is unreadable"
    successor_digest=$(/usr/bin/plutil -extract successorDigest raw -expect string -o - "${output}" 2>/dev/null) \
        || fail "the live-update successor digest is unreadable"
    [[ "${generation}" =~ ^[0-9A-Fa-f-]{36}$ \
        && "${state_digest}" =~ ^[0-9a-f]{64}$ \
        && "${apple_digest}" =~ ^[0-9a-f]{64}$ \
        && "${successor_digest}" =~ ^[0-9a-f]{64}$ ]] \
        || fail "the live-update status contains invalid identifiers"
    if [[ -z "${live_generation:-}" ]]; then
        live_generation=${generation}
        live_state_digest=${state_digest}
        live_apple_digest=${apple_digest}
        live_successor_digest=${successor_digest}
    else
        [[ "${generation}" == "${live_generation}" \
            && ( "${expected_phase}" == finalized || "${state_digest}" == "${live_state_digest}" ) \
            && ( "${expected_phase}" == finalized || "${apple_digest}" == "${live_apple_digest}" ) \
            && "${successor_digest}" == "${live_successor_digest}" ]] \
            || fail "the live-update status changed generation or protected state"
    fi
}

probe_installed_browser_worker() {
    local worker_plist worker_label worker_executable
    for worker_plist in /Library/LaunchAgents/org.hardpause.browser-worker*.plist; do
        [[ -e "${worker_plist}" ]] || continue
        [[ -f "${worker_plist}" && ! -L "${worker_plist}" \
            && "$(/usr/bin/stat -f '%u' "${worker_plist}")" == 0 ]] || continue
        worker_label=$(/usr/libexec/PlistBuddy -c 'Print :Label' "${worker_plist}" 2>/dev/null) \
            || continue
        [[ "${worker_label}" == org.hardpause.browser-worker \
            || "${worker_label}" =~ ^org\.hardpause\.browser-worker\.v[0-9]+$ ]] || continue
        worker_executable=$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' \
            "${worker_plist}" 2>/dev/null) || continue
        [[ "${worker_executable}" == "${browser_worker_root}"/*/Contents/MacOS/HardPauseBrowserWorker \
            && -x "${worker_executable}" && ! -L "${worker_executable}" \
            && "$(/usr/bin/stat -f '%u' "${worker_executable}")" == 0 ]] || continue
        /bin/launchctl print "gui/${sudo_uid}/${worker_label}" >/dev/null 2>&1 || continue
        if /bin/launchctl asuser "${sudo_uid}" \
            "${stage}/HardPauseBrowserWorker.app/Contents/MacOS/HardPauseBrowserWorker" \
            --probe-existing "${worker_label}" \
            >"${stage}/browser-worker-probe.json" 2>"${stage}/browser-worker-probe.stderr"; then
            return 0
        fi
    done
    fail "no installed browser worker is ready to maintain active browser rules"
}

verify_existing_inactive_blocks() {
    local snapshot=$1
    local expect_active=${2:-0}
    [[ -x "${cli_destination}" && ! -L "${cli_destination}" ]] \
        || fail "--update requires the existing installed CLI"
    /bin/launchctl print "system/${label}" >/dev/null 2>&1 \
        || fail "--update requires the existing service to be running"
    local existing_health="${stage}/${snapshot}"
    /bin/launchctl asuser "${existing_enrolled_uid}" /usr/bin/sudo -u "#${existing_enrolled_uid}" \
        "${cli_destination}" list >"${existing_health}" 2>"${stage}/${snapshot}.stderr" \
        || fail "the installed CLI could not authenticate and list protected state; update stopped"
    verify_inactive_snapshot "${existing_health}" "${expect_active}"
    installed_service_version=$(/usr/bin/plutil -extract protection.serviceVersion raw -expect string -o - \
        "${existing_health}.plist" 2>/dev/null) \
        || fail "the installed service version is unreadable"
    [[ "${installed_service_version}" =~ ^[0-9]+$ ]] \
        || fail "the installed service version is invalid"
    if [[ ${expect_active} -eq 1 ]]; then
        [[ "${installed_service_version}" == 2 ]] \
            || fail "active legacy migration requires the installed v2 service"
    elif [[ ${update_existing} -eq 1 && ${installed_service_version} -lt 8 ]]; then
        inactive_migration=1
    fi
    if [[ ${reenroll} -eq 1 ]]; then
        /bin/launchctl asuser "${existing_enrolled_uid}" /usr/bin/sudo -u "#${existing_enrolled_uid}" \
            "${cli_destination}" can-uninstall >"${stage}/existing-can-uninstall.txt" \
            2>"${stage}/existing-can-uninstall.stderr" \
            || fail "the installed service reports protection that prevents reenrollment"
    fi
}

if [[ ${managed_install} -eq 1 ]]; then
    if [[ ${live_update} -eq 1 ]]; then
        [[ -x "${cli_destination}" && ! -L "${cli_destination}" ]] \
            || fail "live update requires the installed CLI"
        /bin/launchctl print "system/${label}" >/dev/null 2>&1 \
            || fail "live update requires the installed service"
        /bin/launchctl asuser "${existing_enrolled_uid}" /usr/bin/sudo -u "#${existing_enrolled_uid}" \
            "${cli_destination}" list >"${stage}/existing-health-check.json" \
            2>"${stage}/existing-health-check.stderr" \
            || fail "the installed service health check failed"
        /usr/bin/sed -E 's/:[[:space:]]*null([,}])/: ""\1/g' \
            "${stage}/existing-health-check.json" >"${stage}/existing-health-check.plist"
        installed_service_version=$(/usr/bin/plutil -extract protection.serviceVersion raw -expect string -o - \
            "${stage}/existing-health-check.plist" 2>/dev/null) \
            || fail "the installed service version is unreadable"
        [[ "${installed_service_version}" =~ ^[0-9]+$ && "${installed_service_version}" -ge 8 ]] \
            || fail "live update requires an installed handoff-capable service"
        is_enforcing=$(/usr/bin/plutil -extract protection.isEnforcing raw -expect bool -o - \
            "${stage}/existing-health-check.plist" 2>/dev/null) \
            || fail "the installed protection status is unreadable"
        [[ "${is_enforcing}" == true ]] || fail "the installed service is not enforcing"
        issue_count=$(/usr/bin/plutil -extract protection.issues raw -expect array -o - \
            "${stage}/existing-health-check.plist" 2>/dev/null) \
            || fail "the installed protection issue list is unreadable"
        [[ "${issue_count}" == 0 ]] || fail "the installed service reports protection issues"
    else
        verify_existing_inactive_blocks "existing-health-check.json" "${active_legacy_migration}"
    fi
fi

/usr/bin/install -m 0755 "${service_source}" "${stage}/hard-pause-service"
/usr/bin/install -m 0755 "${cli_source}" "${stage}/hard-pause"
/usr/bin/install -m 0755 "${uninstaller_source}" "${stage}/hard-pause-uninstall"
/usr/bin/install -m 0644 "${plist_source}" "${stage}/${label}.plist"
/usr/bin/install -m 0644 "${guidance_source}" "${stage}/AGENTS.md"
/usr/bin/ditto "${browser_worker_source}" "${stage}/HardPauseBrowserWorker.app"
browser_worker_build=$(
    /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
        "${stage}/HardPauseBrowserWorker.app/Contents/Info.plist"
) || fail "the browser worker build version is unreadable"
browser_worker_bundle_id=$(
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
        "${stage}/HardPauseBrowserWorker.app/Contents/Info.plist"
) || fail "the browser worker bundle identifier is unreadable"
[[ "${browser_worker_bundle_id}" == "${browser_worker_label}" ]] \
    || fail "the browser worker bundle identifier is invalid"
[[ "${browser_worker_build}" =~ ^[0-9]+$ ]] \
    || fail "the browser worker build version is invalid"
browser_worker_job_label="${browser_worker_label}.v${browser_worker_build}"
browser_worker_plist_destination="/Library/LaunchAgents/${browser_worker_job_label}.plist"
validate_destination "${browser_worker_plist_destination}"
browser_worker_destination="${browser_worker_root}/HardPauseBrowserWorker-${browser_worker_build}.app"
browser_worker_executable="${browser_worker_destination}/Contents/MacOS/HardPauseBrowserWorker"

# Preserve build signatures and their stable identities; installation must not
# replace certificate signatures with per-build ad-hoc hashes.
/usr/bin/codesign --verify --strict "${stage}/hard-pause-service"
/usr/bin/codesign --verify --strict "${stage}/hard-pause"
/usr/bin/codesign --verify --strict --deep "${stage}/HardPauseBrowserWorker.app"
/usr/bin/codesign --verify --strict "${app_bundle}"
if [[ ${managed_install} -eq 1 ]]; then
    validate_parent "${support_dir}"
    [[ "$(/usr/bin/stat -f '%Lp' "${support_dir}")" == 700 ]] \
        || fail "the protected support directory has unsafe permissions"
fi
app_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
    "${app_bundle}/Contents/Info.plist") || fail "the signed app build is unreadable"
[[ "${app_build}" =~ ^[1-9][0-9]{0,9}$ ]] || fail "the signed app build is invalid"
installed_build=""
if [[ -e "${installed_build_destination}" || -L "${installed_build_destination}" ]]; then
    [[ -f "${installed_build_destination}" && ! -L "${installed_build_destination}" \
        && "$(/usr/bin/stat -f '%u' "${installed_build_destination}")" == 0 \
        && "$(/usr/bin/stat -f '%Lp' "${installed_build_destination}")" == 600 ]] \
        || fail "the installed build record is unsafe"
    installed_build=$(<"${installed_build_destination}")
    [[ "${installed_build}" =~ ^[1-9][0-9]{0,9}$ ]] \
        || fail "the installed build record is invalid"
fi
if [[ ${live_update} -eq 1 ]]; then
    [[ -n "${installed_build}" && "${app_build}" -gt "${installed_build}" ]] \
        || fail "a live update requires a newer signed app build"
    verify_native_update_compatibility
elif [[ ${update_existing} -eq 1 && -n "${installed_build}" ]]; then
    [[ "${app_build}" -ge "${installed_build}" ]] \
        || fail "the signed app build is older than the installed build"
fi

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
browser_worker_requirement=$(extract_requirement "${stage}/HardPauseBrowserWorker.app")
enrollment_stage="${stage}/enrollment-v1.json"
if [[ ${update_existing} -eq 1 || ${live_update} -eq 1 ]]; then
    verify_staged_requirement "GUI" "${app_bundle}"
    verify_staged_requirement "CLI" "${stage}/hard-pause"
    /bin/cp -p "${enrollment_destination}" "${enrollment_stage}"
    browser_worker_enrolled=0
    for requirement in "${existing_requirements[@]}"; do
        if /usr/bin/codesign --verify --strict -R="${requirement}" \
            "${stage}/HardPauseBrowserWorker.app" >/dev/null 2>&1; then
            browser_worker_enrolled=1
            break
        fi
    done
    if [[ ${live_update} -eq 1 && ${browser_worker_enrolled} -eq 0 ]]; then
        fail "live update requires an already enrolled browser worker"
    fi
    if [[ ${browser_worker_enrolled} -eq 0 ]]; then
        [[ ${#existing_requirements[@]} -lt 8 ]] \
            || fail "the existing enrollment has no room for the browser worker"
        /usr/bin/plutil -convert xml1 "${enrollment_stage}"
        /usr/bin/plutil -insert "approvedClientRequirements.${#existing_requirements[@]}" \
            -string "${browser_worker_requirement}" "${enrollment_stage}"
        /usr/bin/plutil -convert json "${enrollment_stage}"
    fi
else
    /usr/bin/plutil -create xml1 "${enrollment_stage}"
    /usr/bin/plutil -insert schemaVersion -integer 1 "${enrollment_stage}"
    /usr/bin/plutil -insert enrolledUID -integer "${sudo_uid}" "${enrollment_stage}"
    /usr/bin/plutil -insert approvedClientRequirements -array "${enrollment_stage}"
    /usr/bin/plutil -insert approvedClientRequirements.0 -string "${gui_requirement}" "${enrollment_stage}"
    /usr/bin/plutil -insert approvedClientRequirements.1 -string "${cli_requirement}" "${enrollment_stage}"
    /usr/bin/plutil -insert approvedClientRequirements.2 -string "${browser_worker_requirement}" "${enrollment_stage}"
    /usr/bin/plutil -convert json "${enrollment_stage}"
fi
/bin/chmod 0600 "${enrollment_stage}"

/usr/bin/install -d -m 0700 "${stage}/rollback"
for index in "${!managed_destinations[@]}"; do
    if [[ -e "${managed_destinations[${index}]}" ]]; then
        /bin/cp -p "${managed_destinations[${index}]}" \
            "${stage}/rollback/${backup_names[${index}]}"
        had_previous[index]=1
    fi
done

recover_live_update() {
    set +e
    local recovered=1
    if [[ ${live_old_stopped} -eq 1 ]]; then
        if /bin/launchctl print "system/${label}" >/dev/null 2>&1; then
            /bin/launchctl bootout "system/${label}" >/dev/null 2>&1 || recovered=0
        fi
        if [[ ${recovered} -eq 1 ]]; then
            /bin/cp -p "${live_stage}/old/hard-pause-service" "${service_destination}" || recovered=0
            /bin/cp -p "${live_stage}/old/hard-pause" "${cli_destination}" || recovered=0
            /bin/cp -p "${live_stage}/old/${label}.plist" "${plist_destination}" || recovered=0
            /bin/cp -p "${live_stage}/old/hard-pause-uninstall" "${uninstaller_destination}" || recovered=0
            /bin/cp -p "${live_stage}/old/helper-AGENTS.md" "${guidance_destination}" || recovered=0
            /bin/cp -p "${live_stage}/old/state-AGENTS.md" "${state_guidance_destination}" || recovered=0
        fi
        if [[ ${recovered} -eq 1 ]]; then
            /bin/launchctl bootstrap system "${plist_destination}" >/dev/null 2>&1 \
                && /bin/launchctl enable "system/${label}" >/dev/null 2>&1 \
                && /bin/launchctl kickstart -k "system/${label}" >/dev/null 2>&1 \
                || recovered=0
        fi
    fi
    if [[ ${recovered} -eq 1 ]]; then
        run_enrolled_cli "${cli_destination}" "${live_stage}/cancel-live-update.json" \
            cancel-live-update "${live_token}" || recovered=0
    fi
    if [[ ${recovered} -eq 1 ]]; then
        run_enrolled_cli "${cli_destination}" "${live_stage}/restored-health.json" list \
            || recovered=0
    fi
    if [[ ${recovered} -eq 1 ]]; then
        /usr/bin/sed -E 's/:[[:space:]]*null([,}])/: ""\1/g' \
            "${live_stage}/restored-health.json" >"${live_stage}/restored-health.plist"
        local enforcing issues
        enforcing=$(/usr/bin/plutil -extract protection.isEnforcing raw -expect bool -o - \
            "${live_stage}/restored-health.plist" 2>/dev/null) || recovered=0
        issues=$(/usr/bin/plutil -extract protection.issues raw -expect array -o - \
            "${live_stage}/restored-health.plist" 2>/dev/null) || recovered=0
        [[ "${enforcing:-}" == true && "${issues:-}" == 0 ]] || recovered=0
    fi
    if [[ ${recovered} -eq 1 && -e "${standby_plist_destination:-}" ]]; then
        if /bin/launchctl print "system/${label}.standby" >/dev/null 2>&1; then
            run_enrolled_cli "${cli_destination}" "${live_stage}/cancelled-standby.json" \
                retire-standby "${live_token}" || recovered=0
            if [[ ${recovered} -eq 1 ]]; then
                /bin/launchctl bootout "system/${label}.standby" >/dev/null 2>&1 || recovered=0
            fi
        fi
        if [[ ${recovered} -eq 1 ]]; then
            /bin/rm -f -- "${standby_plist_destination}" || recovered=0
        fi
    fi
    if [[ ${recovered} -eq 1 ]]; then
        echo "hard-pause installer: the prior service resumed; the live update was cancelled." >&2
        return 0
    fi
    echo "hard-pause installer: automatic recovery is incomplete; standby and protected state were retained." >&2
    return 1
}

run_live_update() {
    probe_installed_browser_worker
    validate_parent "${helper_dir}"
    live_stage=$(/usr/bin/mktemp -d "${helper_dir}/live-update.XXXXXXXX") \
        || fail "could not create a durable live-update stage"
    /bin/chmod 0700 "${live_stage}"
    /usr/bin/install -d -o root -g wheel -m 0700 "${live_stage}/old" "${live_stage}/new"
    /bin/cp -p "${service_destination}" "${live_stage}/old/hard-pause-service"
    /bin/cp -p "${cli_destination}" "${live_stage}/old/hard-pause"
    /bin/cp -p "${uninstaller_destination}" "${live_stage}/old/hard-pause-uninstall"
    /bin/cp -p "${plist_destination}" "${live_stage}/old/${label}.plist"
    /bin/cp -p "${guidance_destination}" "${live_stage}/old/helper-AGENTS.md"
    /bin/cp -p "${state_guidance_destination}" "${live_stage}/old/state-AGENTS.md"
    /usr/bin/install -o root -g wheel -m 0755 "${stage}/hard-pause-service" \
        "${live_stage}/new/hard-pause-service"
    /usr/bin/install -o root -g wheel -m 0755 "${stage}/hard-pause" \
        "${live_stage}/new/hard-pause"
    /usr/bin/install -o root -g wheel -m 0755 "${stage}/hard-pause-uninstall" \
        "${live_stage}/new/hard-pause-uninstall"
    /usr/bin/install -o root -g wheel -m 0644 "${stage}/AGENTS.md" \
        "${live_stage}/new/AGENTS.md"
    live_token=$(/usr/bin/uuidgen) || fail "could not create a live-update token"
    /usr/bin/printf '%s\n' "${live_token}" >"${live_stage}/token"
    /bin/chmod 0600 "${live_stage}/token"
    standby_plist_destination="/Library/LaunchDaemons/${label}.standby.plist"
    [[ ! -e "${standby_plist_destination}" && ! -L "${standby_plist_destination}" ]] \
        || fail "a standby service is already registered; inspect the previous update"

    local standby_plist="${live_stage}/new/${label}.standby.plist"
    /usr/bin/plutil -create xml1 "${standby_plist}"
    /usr/libexec/PlistBuddy -c "Add :Label string ${label}.standby" "${standby_plist}"
    /usr/libexec/PlistBuddy -c 'Add :ProgramArguments array' "${standby_plist}"
    /usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string ${live_stage}/new/hard-pause-service" \
        "${standby_plist}"
    /usr/libexec/PlistBuddy -c 'Add :ProgramArguments:1 string --standby' "${standby_plist}"
    /usr/libexec/PlistBuddy -c "Add :ProgramArguments:2 string ${live_token}" "${standby_plist}"
    /usr/libexec/PlistBuddy -c 'Add :MachServices dict' "${standby_plist}"
    /usr/libexec/PlistBuddy -c "Add :MachServices:${label}.standby bool true" "${standby_plist}"
    /usr/libexec/PlistBuddy -c 'Add :KeepAlive bool true' "${standby_plist}"
    /usr/libexec/PlistBuddy -c 'Add :RunAtLoad bool true' "${standby_plist}"
    /usr/bin/plutil -lint "${standby_plist}" >/dev/null

    local public_plist="${live_stage}/new/${label}.plist"
    /bin/cp -p "${stage}/${label}.plist" "${public_plist}"
    /usr/libexec/PlistBuddy -c 'Add :ProgramArguments:1 string --live-update-primary' "${public_plist}"
    /usr/libexec/PlistBuddy -c "Add :ProgramArguments:2 string ${live_token}" "${public_plist}"
    /usr/bin/plutil -lint "${public_plist}" >/dev/null

    live_started=1
    retry_claim_preflight_allowed=0
    run_enrolled_cli "${cli_source}" "${live_stage}/begin.json" \
        begin-live-update "${live_token}" "${live_stage}/new/hard-pause-service" \
        || fail "the running service did not freeze for live update"
    verify_live_status "${live_stage}/begin.json" frozen
    # Older services did not reserve native writes. Recheck after setup is frozen.
    verify_native_update_compatibility
    /usr/bin/install -o root -g wheel -m 0644 "${standby_plist}" "${standby_plist_destination}"
    /bin/launchctl bootstrap system "${standby_plist_destination}" \
        || fail "the standby service could not start"
    /bin/launchctl enable "system/${label}.standby" \
        || fail "the standby service could not be enabled"
    /bin/launchctl kickstart -k "system/${label}.standby" \
        || fail "the standby service could not run"
    run_enrolled_cli "${cli_source}" "${live_stage}/standby.json" \
        standby-readiness "${live_token}" || fail "standby did not report readiness"
    verify_live_status "${live_stage}/standby.json" standby_ready
    run_enrolled_cli "${cli_source}" "${live_stage}/old-frozen.json" \
        inspect-live-update "${live_token}" || fail "the old service lost its update gate"
    verify_live_status "${live_stage}/old-frozen.json" frozen
    probe_installed_browser_worker

    live_old_stopped=1
    /bin/launchctl bootout "system/${label}" \
        || fail "the old service could not release its public endpoint"
    /usr/bin/install -o root -g wheel -m 0755 "${live_stage}/new/hard-pause-service" \
        "${service_destination}"
    /usr/bin/install -o root -g wheel -m 0755 "${live_stage}/new/hard-pause" \
        "${cli_destination}"
    /usr/bin/install -o root -g wheel -m 0755 "${live_stage}/new/hard-pause-uninstall" \
        "${uninstaller_destination}"
    /usr/bin/install -o root -g wheel -m 0644 "${public_plist}" "${plist_destination}"
    /usr/bin/install -o root -g wheel -m 0644 "${live_stage}/new/AGENTS.md" "${guidance_destination}"
    /usr/bin/install -o root -g wheel -m 0600 "${live_stage}/new/AGENTS.md" "${state_guidance_destination}"
    /bin/launchctl bootstrap system "${plist_destination}" \
        || fail "the new public service could not start"
    /bin/launchctl enable "system/${label}" \
        || fail "the new public service could not be enabled"
    /bin/launchctl kickstart -k "system/${label}" \
        || fail "the new public service could not run"
    run_enrolled_cli "${cli_destination}" "${live_stage}/new-read-only.json" \
        inspect-live-update "${live_token}" || fail "the new public service is not ready"
    verify_live_status "${live_stage}/new-read-only.json" standby_ready
    probe_installed_browser_worker

    # A timeout after this call may mean the new service already owns state.
    # Recovery must not start the old service once finalization was attempted.
    live_finalization_started=1
    run_enrolled_cli "${cli_destination}" "${live_stage}/finalized.json" \
        finalize-live-update "${live_token}" || fail "live-update finalization needs inspection"
    verify_live_status "${live_stage}/finalized.json" finalized
    run_enrolled_cli "${cli_destination}" "${live_stage}/final-health.json" list \
        || fail "the finalized service did not answer its health check"
    /usr/bin/sed -E 's/:[[:space:]]*null([,}])/: ""\1/g' \
        "${live_stage}/final-health.json" >"${live_stage}/final-health.plist"
    [[ "$(/usr/bin/plutil -extract protection.isEnforcing raw -expect bool -o - \
        "${live_stage}/final-health.plist")" == true ]] \
        || fail "the finalized service is not enforcing"
    [[ "$(/usr/bin/plutil -extract protection.issues raw -expect array -o - \
        "${live_stage}/final-health.plist")" == 0 ]] \
        || fail "the finalized service reports protection issues"
    probe_installed_browser_worker
    run_enrolled_cli "${cli_destination}" "${live_stage}/retired-standby.json" \
        retire-standby "${live_token}" || fail "the standby could not release its separate rules"
    verify_live_status "${live_stage}/retired-standby.json" finalized false
    /bin/launchctl bootout "system/${label}.standby" \
        || fail "the redundant standby could not be removed"
    /bin/rm -f -- "${standby_plist_destination}"
}

if [[ ${live_update} -eq 0 ]]; then
if [[ ${update_existing} -eq 1 ]]; then
    if [[ ${inactive_migration} -eq 1 || ${active_legacy_migration} -eq 1 ]]; then
        if [[ ${inactive_migration} -eq 1 ]]; then
            run_enrolled_cli "${cli_destination}" "${stage}/existing-can-uninstall.json" can-uninstall \
                || fail "the installed service reports protection that prevents migration"
        else
            "${stage}/hard-pause-service" --verify-active-legacy-state \
                || fail "the active legacy state cannot be migrated safely"
        fi
        migration_stage=$(/usr/bin/mktemp -d "${helper_dir}/inactive-migration.XXXXXXXX") \
            || fail "could not create a durable migration stage"
        /bin/chmod 0700 "${migration_stage}"
        migration_token=$(/usr/bin/uuidgen) || fail "could not create a migration token"
        /usr/bin/printf '%s\n' "${migration_token}" >"${migration_stage}/token"
        /bin/chmod 0600 "${migration_stage}/token"
        /bin/cp -p "${stage}/${label}.plist" "${stage}/${label}.migration.plist"
        migration_mode=--inactive-migration
        if [[ ${active_legacy_migration} -eq 1 ]]; then
            migration_mode=--active-legacy-migration
        fi
        /usr/libexec/PlistBuddy -c "Add :ProgramArguments:1 string ${migration_mode}" \
            "${stage}/${label}.migration.plist"
        /usr/libexec/PlistBuddy -c "Add :ProgramArguments:2 string ${migration_token}" \
            "${stage}/${label}.migration.plist"
        /usr/bin/plutil -lint "${stage}/${label}.migration.plist" >/dev/null
        /bin/cp -pR "${stage}/rollback" "${migration_stage}/old-files"
        for state_name in state-v2.json pending-state-v2.json apple-lockdown-state-v1.json; do
            if [[ -e "${support_dir}/${state_name}" ]]; then
                /bin/cp -p "${support_dir}/${state_name}" "${migration_stage}/${state_name}"
            fi
        done
    else
        update_gate_token=$(/usr/bin/uuidgen) || fail "could not create an update gate token"
        /usr/bin/printf '%s\n' "${update_gate_token}" >"${update_gate_token_path}"
        /bin/chmod 0600 "${update_gate_token_path}"
        update_gate_cleanup_needed=1
        retry_claim_preflight_allowed=0
        /bin/launchctl asuser "${existing_enrolled_uid}" /usr/bin/sudo -u "#${existing_enrolled_uid}" \
            "${cli_source}" prepare-update "${update_gate_token}" \
            >"${stage}/update-gate-health-check.json" 2>"${stage}/update-gate-health-check.stderr" \
            || fail "the installed service could not prepare safely for the update"
        verify_inactive_snapshot "${stage}/update-gate-health-check.json"
    fi
fi

if [[ ${inactive_migration} -eq 1 || ${active_legacy_migration} -eq 1 ]]; then
    retry_claim_preflight_allowed=0
fi
if /bin/launchctl print "system/${label}" >/dev/null 2>&1; then
    [[ ${managed_install} -eq 1 ]] \
        || fail "a launchd job already uses ${label}, but Hard Pause does not own this installation"
    /bin/launchctl bootout "system/${label}" >/dev/null 2>&1 \
        || fail "the existing service could not be stopped; no files were changed"
    previous_service_loaded=1
fi
rollback_armed=1
if [[ ${inactive_migration} -eq 1 || ${active_legacy_migration} -eq 1 ]]; then
    migration_verifier=--verify-inactive-legacy-state
    if [[ ${active_legacy_migration} -eq 1 ]]; then
        migration_verifier=--verify-active-legacy-state
    fi
    "${stage}/hard-pause-service" "${migration_verifier}" \
        || fail "durable state changed before migration; the old service will be restarted"
fi
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
if [[ ${inactive_migration} -eq 1 || ${active_legacy_migration} -eq 1 ]]; then
    /usr/bin/install -o root -g wheel -m 0644 "${stage}/${label}.migration.plist" "${plist_destination}"
else
    /usr/bin/install -o root -g wheel -m 0644 "${stage}/${label}.plist" "${plist_destination}"
fi
/usr/bin/install -o root -g wheel -m 0600 "${enrollment_stage}" "${enrollment_destination}"
/usr/bin/install -o root -g wheel -m 0644 "${stage}/AGENTS.md" "${guidance_destination}"
/usr/bin/install -o root -g wheel -m 0600 "${stage}/AGENTS.md" "${state_guidance_destination}"

/bin/launchctl bootstrap system "${plist_destination}" \
    || fail "launchd could not bootstrap ${label}"
/bin/launchctl enable "system/${label}" \
    || fail "launchd could not enable ${label}"
/bin/launchctl kickstart -k "system/${label}" \
    || fail "launchd could not start ${label}"
if [[ ${update_existing} -eq 1 ]]; then
    if [[ ${inactive_migration} -eq 1 || ${active_legacy_migration} -eq 1 ]]; then
        run_enrolled_cli "${cli_destination}" "${stage}/migration-read-only.json" list \
            || fail "the read-only migrated service is not available"
        verify_inactive_snapshot "${stage}/migration-read-only.json" "${active_legacy_migration}"
        if [[ ${active_legacy_migration} -eq 1 ]]; then
            verify_same_restrictions "${stage}/existing-health-check.json" \
                "${stage}/migration-read-only.json"
        fi
        rollback_armed=0
        migration_finalization_started=1
        migration_finalizer=finalize-inactive-migration
        if [[ ${active_legacy_migration} -eq 1 ]]; then
            migration_finalizer=finalize-active-legacy-migration
        fi
        run_enrolled_cli "${cli_destination}" "${stage}/migration-finalized.json" \
            "${migration_finalizer}" "${migration_token}" \
            || fail "migration finalization needs inspection"
        verify_inactive_snapshot "${stage}/migration-finalized.json" "${active_legacy_migration}"
        if [[ ${active_legacy_migration} -eq 1 ]]; then
            verify_same_restrictions "${stage}/existing-health-check.json" \
                "${stage}/migration-finalized.json"
        fi
    else
        rollback_armed=0
        /bin/launchctl asuser "${sudo_uid}" /usr/bin/sudo -u "#${sudo_uid}" \
            "${cli_destination}" cancel-update "${update_gate_token}" >"${stage}/health-check.json" \
            || fail "the installed service did not release its update gate"
        verify_inactive_snapshot "${stage}/health-check.json"
        update_gate_cleanup_needed=0
    fi
else
    /bin/launchctl asuser "${sudo_uid}" /usr/bin/sudo -u "#${sudo_uid}" \
        "${cli_destination}" list >"${stage}/health-check.json" \
        || fail "the installed service did not pass its authenticated health check"
    if [[ ${managed_install} -eq 1 ]]; then
        verify_inactive_snapshot "${stage}/health-check.json"
    fi
    rollback_armed=0
fi
fi

install_browser_worker() {
    if [[ -e "${browser_worker_root}" ]]; then
        [[ -d "${browser_worker_root}" && ! -L "${browser_worker_root}" ]] \
            || fail "the browser worker directory is unsafe"
        [[ "$(/usr/bin/stat -f '%u' "${browser_worker_root}")" == 0 ]] \
            || fail "the browser worker directory is not root-owned"
    else
        /usr/bin/install -d -o root -g wheel -m 0755 "${browser_worker_root}"
    fi
    /bin/chmod 0755 "${browser_worker_root}"
    if [[ -e "${browser_worker_destination}" ]]; then
        [[ -d "${browser_worker_destination}" && ! -L "${browser_worker_destination}" ]] \
            || fail "the installed browser worker path is unsafe"
        [[ "$(/usr/bin/stat -f '%u' "${browser_worker_destination}")" == 0 ]] \
            || fail "the installed browser worker is not root-owned"
        local staged_hash installed_hash
        staged_hash=$(/usr/bin/codesign -dv --verbose=4 \
            "${stage}/HardPauseBrowserWorker.app" 2>&1 | /usr/bin/sed -n 's/^CDHash=//p')
        installed_hash=$(/usr/bin/codesign -dv --verbose=4 \
            "${browser_worker_destination}" 2>&1 | /usr/bin/sed -n 's/^CDHash=//p')
        [[ -n "${staged_hash}" && "${staged_hash}" == "${installed_hash}" ]] \
            || fail "the installed browser worker build number has different signed code"
    else
        /usr/bin/ditto "${stage}/HardPauseBrowserWorker.app" "${browser_worker_destination}"
        /usr/sbin/chown -R root:wheel "${browser_worker_destination}"
    fi
    /bin/chmod -R a+rX,go-w "${browser_worker_destination}"
    [[ -x "${browser_worker_executable}" && ! -L "${browser_worker_executable}" ]] \
        || fail "the installed browser worker executable is unsafe"
    [[ "$(/usr/bin/stat -f '%u' "${browser_worker_executable}")" == 0 ]] \
        || fail "the installed browser worker executable is not root-owned"
    /usr/bin/codesign --verify --strict --deep -R="${browser_worker_requirement}" \
        "${browser_worker_destination}" \
        || fail "the installed browser worker signature is invalid"

    local worker_plist="${stage}/${browser_worker_job_label}.plist"
    /usr/bin/plutil -create xml1 "${worker_plist}"
    /usr/libexec/PlistBuddy -c "Add :Label string ${browser_worker_job_label}" "${worker_plist}"
    /usr/libexec/PlistBuddy -c 'Add :ProgramArguments array' "${worker_plist}"
    /usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string ${browser_worker_executable}" \
        "${worker_plist}"
    /usr/libexec/PlistBuddy -c 'Add :ProgramArguments:1 string --serve' "${worker_plist}"
    /usr/libexec/PlistBuddy -c "Add :ProgramArguments:2 string ${browser_worker_job_label}" \
        "${worker_plist}"
    /usr/libexec/PlistBuddy -c 'Add :MachServices dict' "${worker_plist}"
    /usr/libexec/PlistBuddy -c "Add :MachServices:${browser_worker_job_label} bool true" \
        "${worker_plist}"
    /usr/libexec/PlistBuddy -c 'Add :KeepAlive bool true' "${worker_plist}"
    /usr/libexec/PlistBuddy -c 'Add :RunAtLoad bool true' "${worker_plist}"
    /usr/libexec/PlistBuddy -c 'Add :ProcessType string Background' "${worker_plist}"
    /usr/bin/plutil -lint "${worker_plist}" >/dev/null

    local prior_plist="${stage}/prior-browser-worker.plist"
    local had_prior_plist=0
    local prior_loaded=0
    if [[ -e "${browser_worker_plist_destination}" ]]; then
        /bin/cp -p "${browser_worker_plist_destination}" "${prior_plist}"
        had_prior_plist=1
    fi
    if /bin/launchctl print "gui/${sudo_uid}/${browser_worker_job_label}" >/dev/null 2>&1; then
        [[ ${had_prior_plist} -eq 1 ]] \
            || fail "an unrelated browser worker launchd job already exists"
        if [[ ${live_update} -eq 1 ]]; then
            /bin/launchctl asuser "${sudo_uid}" \
                "${stage}/HardPauseBrowserWorker.app/Contents/MacOS/HardPauseBrowserWorker" \
                --probe-existing "${browser_worker_job_label}" \
                >/dev/null || fail "the existing browser worker is not ready during live update"
            return 0
        fi
        /bin/launchctl bootout "gui/${sudo_uid}/${browser_worker_job_label}" \
            || fail "the existing browser worker could not be stopped"
        prior_loaded=1
    fi
    /usr/bin/install -o root -g wheel -m 0644 "${worker_plist}" \
        "${browser_worker_plist_destination}"
    if ! /bin/launchctl bootstrap "gui/${sudo_uid}" "${browser_worker_plist_destination}"; then
        /bin/launchctl bootout "gui/${sudo_uid}/${browser_worker_job_label}" >/dev/null 2>&1 || true
        if [[ ${had_prior_plist} -eq 1 ]]; then
            /bin/cp -p "${prior_plist}" "${browser_worker_plist_destination}"
            if [[ ${prior_loaded} -eq 1 ]]; then
                /bin/launchctl bootstrap "gui/${sudo_uid}" "${browser_worker_plist_destination}" \
                    || fail "the browser worker and its previous launchd job could not be started"
            fi
        else
            /bin/rm -f -- "${browser_worker_plist_destination}"
        fi
        fail "the browser worker could not be started; the protection service remains installed"
    fi

    local remaining_probes=5
    until /bin/launchctl asuser "${sudo_uid}" /usr/bin/sudo -u "#${sudo_uid}" \
        "${browser_worker_executable}" --probe "${browser_worker_job_label}" \
        >"${stage}/new-browser-worker-probe.json" \
        2>"${stage}/new-browser-worker-probe.stderr"; do
        remaining_probes=$((remaining_probes - 1))
        if [[ ${remaining_probes} -eq 0 ]]; then
            echo "hard-pause installer: the new browser worker needs setup before taking over." >&2
            return 0
        fi
        /bin/sleep 1
    done
    local old_plist old_label old_executable
    for old_plist in /Library/LaunchAgents/org.hardpause.browser-worker*.plist; do
        [[ -e "${old_plist}" && "${old_plist}" != "${browser_worker_plist_destination}" ]] \
            || continue
        [[ -f "${old_plist}" && ! -L "${old_plist}" \
            && "$(/usr/bin/stat -f '%u' "${old_plist}")" == 0 ]] || continue
        old_label=$(/usr/libexec/PlistBuddy -c 'Print :Label' "${old_plist}" 2>/dev/null) \
            || continue
        [[ "${old_label}" == org.hardpause.browser-worker \
            || "${old_label}" =~ ^org\.hardpause\.browser-worker\.v[0-9]+$ ]] || continue
        /bin/launchctl print "gui/${sudo_uid}/${old_label}" >/dev/null 2>&1 || continue
        old_executable=$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' \
            "${old_plist}" 2>/dev/null) || continue
        [[ "${old_executable}" == "${browser_worker_root}"/*/Contents/MacOS/HardPauseBrowserWorker \
            && -x "${old_executable}" && ! -L "${old_executable}" \
            && "$(/usr/bin/stat -f '%u' "${old_executable}")" == 0 ]] || continue
        if /bin/launchctl asuser "${sudo_uid}" /usr/bin/sudo -u "#${sudo_uid}" \
            "${browser_worker_executable}" --migrate "${old_label}" "${browser_worker_job_label}" \
            >"${stage}/migrate-${old_label}.json" 2>"${stage}/migrate-${old_label}.stderr"; then
            if /bin/launchctl bootout "gui/${sudo_uid}/${old_label}"; then
                /bin/rm -f -- "${old_plist}"
            else
                echo "hard-pause installer: keeping ${old_label} because it could not stop safely." >&2
            fi
        else
            echo "hard-pause installer: keeping ${old_label} until its pause pages can move safely." >&2
        fi
    done
}

if [[ ${live_update} -eq 1 ]]; then
    run_live_update
fi
install_browser_worker
build_record_stage=$(/usr/bin/mktemp "${support_dir}/installed-build-v1.XXXXXXXX") \
    || fail "the installed build record could not be staged"
/bin/chmod 0600 "${build_record_stage}"
/usr/bin/printf '%s\n' "${app_build}" >"${build_record_stage}"
/bin/mv -f -- "${build_record_stage}" "${installed_build_destination}" \
    || fail "the installed build record could not be committed"
if [[ ${live_update} -eq 1 ]]; then
    live_success=1
    echo "Hard Pause transferred the running service with active protection preserved."
fi

echo "Hard Pause enrolled user ${sudo_user} (${sudo_uid}) and started ${label}."
echo "Installed CLI: ${cli_destination}"
echo "Browser worker: ${browser_worker_destination}"
echo "Agent maintenance guidance: ${guidance_destination}"
install_complete=1
