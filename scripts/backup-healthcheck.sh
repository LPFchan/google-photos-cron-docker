#!/usr/bin/env bash

# Docker healthcheck: inspect only local per-run state. No logs, network,
# credentials, process probing, or human-readable date parsing are involved.
set -u

ACTIVE_DIR="${BACKUP_ACTIVE_STATUS_DIR:-/tmp/backup-active.d}"
MAX_RUNTIME="${BACKUP_MAX_RUNTIME:-0}"
HEALTH_GRACE="${BACKUP_HEALTH_GRACE:-300}"

[[ -d "${ACTIVE_DIR}" ]] || exit 0
shopt -s nullglob
records=()
for candidate in "${ACTIVE_DIR}"/* "${ACTIVE_DIR}"/.[!.]* "${ACTIVE_DIR}"/..?*; do
    [[ -f "${candidate}" ]] && records+=("${candidate}")
done
[[ ${#records[@]} -gt 0 ]] || exit 0

valid_duration() {
    [[ "$1" =~ ^[1-9][0-9]*[smhd]$ ]]
}

duration_seconds() {
    local value="$1" number unit multiplier limit
    number="${value%?}"
    unit="${value: -1}"
    case "${unit}" in
        s) multiplier=1 ;;
        m) multiplier=60 ;;
        h) multiplier=3600 ;;
        d) multiplier=86400 ;;
        *) return 1 ;;
    esac
    # Saturate values beyond bash's signed range; no representable run age can
    # exceed such a configured duration.
    limit=$(( 9223372036854775807 / multiplier ))
    number="${number#"${number%%[!0]*}"}"
    number="${number:-0}"
    if (( ${#number} > ${#limit} )) \
        || { (( ${#number} == ${#limit} )) && [[ "${number}" > "${limit}" ]]; }; then
        DURATION_SECONDS=9223372036854775807
        return 0
    fi
    DURATION_SECONDS=$(( number * multiplier ))
}

if [[ "${MAX_RUNTIME}" != "0" ]]; then
    valid_duration "${MAX_RUNTIME}" && duration_seconds "${MAX_RUNTIME}" || exit 1
fi
[[ "${HEALTH_GRACE}" =~ ^[0-9]+$ ]] || exit 1
grace_normalized="${HEALTH_GRACE#"${HEALTH_GRACE%%[!0]*}"}"
grace_normalized="${grace_normalized:-0}"
max_integer=9223372036854775807
if (( ${#grace_normalized} > ${#max_integer} )) \
    || { (( ${#grace_normalized} == ${#max_integer} )) && [[ "${grace_normalized}" > "${max_integer}" ]]; }; then
    health_grace_seconds=9223372036854775807
else
    health_grace_seconds=$(( 10#${grace_normalized} ))
fi

now="$(date +%s)" || exit 1
for record in "${records[@]}"; do
    [[ -f "${record}" ]] || continue

    run_id="" pid="" pair_indices="" state="" start_epoch="" last_start="" exit_code=""
    malformed=0
    while IFS='=' read -r key value || [[ -n "${key:-}" ]]; do
        case "${key}" in
            RUN_ID) run_id="${value}" ;;
            PID) pid="${value}" ;;
            PAIR_INDICES) pair_indices="${value}" ;;
            STATE) state="${value}" ;;
            START_EPOCH) start_epoch="${value}" ;;
            LAST_START) last_start="${value}" ;;
            EXIT_CODE) exit_code="${value}" ;;
            LAST_END) : ;;
            *) malformed=1 ;;
        esac
    done < "${record}" || exit 1

    [[ ${malformed} -eq 0 && -n "${run_id}" && "${pid}" =~ ^[1-9][0-9]*$ \
        && -n "${pair_indices}" && "${start_epoch}" =~ ^[0-9]+$ \
        && -n "${last_start}" && "${exit_code}" =~ ^[0-9]+$ ]] || exit 1

    start_normalized="${start_epoch#"${start_epoch%%[!0]*}"}"
    start_normalized="${start_normalized:-0}"
    if (( ${#start_normalized} > ${#max_integer} )) \
        || { (( ${#start_normalized} == ${#max_integer} )) && [[ "${start_normalized}" > "${max_integer}" ]]; }; then
        exit 1
    fi
    start_epoch=$(( 10#${start_normalized} ))

    case "${state}" in
        SUCCESS|FAILED) continue ;;
        RUNNING) ;;
        *) exit 1 ;;
    esac

    if [[ "${MAX_RUNTIME}" != "0" ]]; then
        # Guard additions against signed overflow.
        if (( DURATION_SECONDS > 9223372036854775807 - health_grace_seconds )); then
            allowed=9223372036854775807
        else
            allowed=$(( DURATION_SECONDS + health_grace_seconds ))
        fi
        (( start_epoch <= now )) || exit 1
        age=$(( now - start_epoch ))
        (( age <= allowed )) || exit 1
    fi
done

exit 0
