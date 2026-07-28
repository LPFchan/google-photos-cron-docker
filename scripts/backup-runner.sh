#!/usr/bin/env bash

# Canonical bounded entry point for every supported backup invocation.
set -u

BACKUP_MAX_RUNTIME="${BACKUP_MAX_RUNTIME:-0}"
BACKUP_KILL_AFTER="${BACKUP_KILL_AFTER:-60s}"
BACKUP_COMMAND="${BACKUP_COMMAND:-/app/backup.sh}"

valid_duration() {
    [[ "$1" =~ ^[1-9][0-9]*[smhd]$ ]]
}

if [[ "${BACKUP_MAX_RUNTIME}" != "0" ]] && ! valid_duration "${BACKUP_MAX_RUNTIME}"; then
    printf 'Invalid BACKUP_MAX_RUNTIME: expected 0 or a positive integer followed by s, m, h, or d\n' >&2
    exit 64
fi

if [[ "${BACKUP_MAX_RUNTIME}" == "0" ]]; then
    exec "${BACKUP_COMMAND}" "$@"
fi

if ! valid_duration "${BACKUP_KILL_AFTER}"; then
    printf 'Invalid BACKUP_KILL_AFTER: expected a positive integer followed by s, m, h, or d\n' >&2
    exit 64
fi

# GNU timeout creates a separate process group for the managed command by
# default. TERM and the bounded KILL escalation therefore reach backup.sh and
# all descendants. exec also preserves the runner PID/process-group identity
# for web UI cancellation and returns timeout's status directly to the caller.
exec timeout --signal=TERM --kill-after="${BACKUP_KILL_AFTER}" \
    "${BACKUP_MAX_RUNTIME}" "${BACKUP_COMMAND}" "$@"
