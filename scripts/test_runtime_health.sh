#!/usr/bin/env bash
# Focused tests for bounded runner, per-run state, health, web UI, and Compose.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="${ROOT}/scripts/backup-runner.sh"
HEALTH="${ROOT}/scripts/backup-healthcheck.sh"
SCRATCH="$(mktemp -d)"
PASS=0
FAIL=0
PIDS=()
trap 'for pid in "${PIDS[@]}"; do kill -KILL "${pid}" 2>/dev/null || true; done; rm -rf "${SCRATCH}"' EXIT

pass() { printf 'PASS %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }

alive_non_zombie() {
    local pid="$1" state
    [[ -r "/proc/${pid}/stat" ]] || return 1
    state="$(cut -d' ' -f3 "/proc/${pid}/stat" 2>/dev/null)"
    [[ "${state}" != "Z" ]]
}

wait_for_count() {
    local dir="$1" expected="$2" attempts=0 count
    while (( attempts < 100 )); do
        count="$(find "${dir}" -maxdepth 1 -type f -name '*.env' 2>/dev/null | wc -l)"
        (( count >= expected )) && return 0
        sleep 0.05
        attempts=$((attempts + 1))
    done
    return 1
}

# Runner validation and disabled behavior.
marker="${SCRATCH}/marker"
cat > "${SCRATCH}/quick.sh" <<EOF
#!/usr/bin/env bash
printf ran > "${marker}"
EOF
chmod +x "${SCRATCH}/quick.sh"
rc=0
BACKUP_MAX_RUNTIME=bogus BACKUP_COMMAND="${SCRATCH}/quick.sh" "${RUNNER}" >/dev/null 2>&1 || rc=$?
[[ ${rc} -eq 64 && ! -e "${marker}" ]] && pass "invalid runtime rejected before launch" || fail "invalid runtime validation"

rc=0
BACKUP_MAX_RUNTIME=0 BACKUP_COMMAND="${SCRATCH}/quick.sh" "${RUNNER}" >/dev/null 2>&1 || rc=$?
[[ ${rc} -eq 0 && -e "${marker}" ]] && pass "runtime 0 disables timeout" || fail "runtime 0 behavior"

rm -f "${marker}"
rc=0
BACKUP_MAX_RUNTIME=2s BACKUP_KILL_AFTER=bad BACKUP_COMMAND="${SCRATCH}/quick.sh" "${RUNNER}" >/dev/null 2>&1 || rc=$?
[[ ${rc} -eq 64 && ! -e "${marker}" ]] && pass "invalid kill-after rejected" || fail "kill-after validation"

rc=0
BACKUP_MAX_RUNTIME=2s BACKUP_KILL_AFTER=1s BACKUP_COMMAND="${SCRATCH}/quick.sh" "${RUNNER}" >/dev/null 2>&1 || rc=$?
[[ ${rc} -eq 0 && -e "${marker}" ]] && pass "valid bounded runtime runs command" || fail "valid runtime"

# TERM-resistant parent and descendant must be bounded by KILL escalation.
cat > "${SCRATCH}/resistant.sh" <<EOF
#!/usr/bin/env bash
trap '' TERM
bash -c 'trap "" TERM; while :; do sleep 1; done' &
printf '%s\n' "\$!" > "${SCRATCH}/child.pid"
while :; do sleep 1; done
EOF
chmod +x "${SCRATCH}/resistant.sh"
start="$(date +%s)"
rc=0
BACKUP_MAX_RUNTIME=1s BACKUP_KILL_AFTER=1s BACKUP_COMMAND="${SCRATCH}/resistant.sh" "${RUNNER}" >/dev/null 2>&1 || rc=$?
end="$(date +%s)"
child_pid="$(cat "${SCRATCH}/child.pid")"
if [[ ${rc} -eq 137 && $((end - start)) -le 4 ]] && ! alive_non_zombie "${child_pid}"; then
    pass "TERM-resistant process tree receives bounded KILL and scheduler returns"
else
    fail "bounded process-group escalation (rc=${rc}, elapsed=$((end-start)), child=${child_pid})"
fi

# Build a backup fixture whose init_env blocks and ignores TERM. backup.sh must
# create active state before reaching it or touching the configured log target.
mkdir -p "${SCRATCH}/fixture/app"
cat > "${SCRATCH}/fixture/app/includes.sh" <<'EOF'
#!/usr/bin/env bash
color() { :; }
init_env() { trap '' TERM; while :; do sleep 1; done; }
EOF
sed "s|^\. /app/includes\.sh$|. ${SCRATCH}/fixture/app/includes.sh|" \
    "${ROOT}/scripts/backup.sh" > "${SCRATCH}/fixture/app/backup.sh"
chmod +x "${SCRATCH}/fixture/app/backup.sh"

active="${SCRATCH}/active-blocked"
mkdir -p "${active}"
BACKUP_ACTIVE_STATUS_DIR="${active}" BACKUP_STATUS_FILE="${SCRATCH}/aggregate-blocked.env" \
BACKUP_LOG_TARGET=/dev/null BACKUP_MAX_RUNTIME=1s BACKUP_KILL_AFTER=1s \
BACKUP_COMMAND="${SCRATCH}/fixture/app/backup.sh" "${RUNNER}" >/dev/full 2>&1 &
pid=$!; PIDS+=("${pid}")
if wait_for_count "${active}" 1; then
    record="$(find "${active}" -maxdepth 1 -type f -name '*.env' -print -quit)"
    if grep -q '^STATE=RUNNING$' "${record}" && grep -q '^RUN_ID=' "${record}" \
        && grep -q '^PID=' "${record}" && grep -q '^PAIR_INDICES=ALL$' "${record}" \
        && grep -q '^START_EPOCH=' "${record}" && grep -q '^LAST_START=' "${record}" \
        && grep -q '^EXIT_CODE=255$' "${record}"; then
        pass "RUNNING evidence precedes unusable inherited stdout"
    else
        fail "active record required fields"
    fi
else
    fail "active record was not created before blocked initialization"
fi
wait "${pid}" 2>/dev/null || true

# A cooperative TERM timeout must return timeout's status while backup.sh's
# EXIT trap records its signal-derived status and removes the active record.
cat > "${SCRATCH}/fixture/app/includes-cooperative.sh" <<'EOF'
#!/usr/bin/env bash
color() { :; }
init_env() { while :; do sleep 1; done; }
EOF
sed "s|^\. /app/includes\.sh$|. ${SCRATCH}/fixture/app/includes-cooperative.sh|" \
    "${ROOT}/scripts/backup.sh" > "${SCRATCH}/fixture/app/backup-cooperative.sh"
chmod +x "${SCRATCH}/fixture/app/backup-cooperative.sh"
cooperative_active="${SCRATCH}/active-cooperative"
cooperative_aggregate="${SCRATCH}/aggregate-cooperative.env"
mkdir -p "${cooperative_active}"
rc=0
BACKUP_ACTIVE_STATUS_DIR="${cooperative_active}" BACKUP_STATUS_FILE="${cooperative_aggregate}" \
BACKUP_LOG_TARGET=/dev/null BACKUP_MAX_RUNTIME=1s BACKUP_KILL_AFTER=2s \
BACKUP_COMMAND="${SCRATCH}/fixture/app/backup-cooperative.sh" "${RUNNER}" \
    >/dev/null 2>&1 || rc=$?
active_count="$(find "${cooperative_active}" -maxdepth 1 -type f -name '*.env' | wc -l)"
if [[ ${rc} -eq 124 && "${active_count}" -eq 0 ]] \
    && grep -q '^STATE=FAILED$' "${cooperative_aggregate}" \
    && grep -q '^EXIT_CODE=143$' "${cooperative_aggregate}"; then
    pass "cooperative TERM timeout records signal failure and removes active state"
else
    fail "cooperative TERM cleanup (rc=${rc}, active=${active_count})"
fi

# KILL leaves stale evidence and the healthcheck reports it after the bound.
if [[ -n "${record:-}" && -f "${record}" ]]; then
    rc=0
    BACKUP_ACTIVE_STATUS_DIR="${active}" BACKUP_MAX_RUNTIME=1s BACKUP_HEALTH_GRACE=0 "${HEALTH}" || rc=$?
    [[ ${rc} -ne 0 ]] && pass "forced KILL leaves unhealthy stale RUNNING evidence" || fail "forced-KILL stale health evidence"
else
    fail "forced KILL did not preserve active record"
fi

# Concurrent invocations have distinct records.
concurrent="${SCRATCH}/active-concurrent"
mkdir -p "${concurrent}"
for pairs in 0 1; do
    PAIR_INDICES="${pairs}" BACKUP_ACTIVE_STATUS_DIR="${concurrent}" \
    BACKUP_STATUS_FILE="${SCRATCH}/aggregate-concurrent.env" BACKUP_LOG_TARGET=/dev/null \
    BACKUP_MAX_RUNTIME=1s BACKUP_KILL_AFTER=1s BACKUP_COMMAND="${SCRATCH}/fixture/app/backup.sh" \
    "${RUNNER}" >/dev/null 2>&1 &
    PIDS+=("$!")
done
if wait_for_count "${concurrent}" 2; then
    names="$(find "${concurrent}" -maxdepth 1 -type f -name '*.env' -printf '%f\n' | sort -u | wc -l)"
    [[ "${names}" -eq 2 ]] && pass "concurrent runs keep unique active records" || fail "concurrent record names"
else
    fail "concurrent active records"
fi
wait "${PIDS[-2]}" 2>/dev/null || true
wait "${PIDS[-1]}" 2>/dev/null || true

write_record() {
    local file="$1" state="$2" epoch="$3"
    cat > "${file}" <<EOF
RUN_ID=test-1
PID=123
PAIR_INDICES=0
STATE=${state}
START_EPOCH=${epoch}
LAST_START=2026-01-01T00:00:00Z
LAST_END=
EXIT_CODE=255
EOF
}

# Health matrix: empty, fresh, stale, terminal, malformed, and disabled aging.
healthdir="${SCRATCH}/health"
mkdir -p "${healthdir}"
BACKUP_ACTIVE_STATUS_DIR="${healthdir}" BACKUP_MAX_RUNTIME=1s "${HEALTH}" \
    && pass "no active records is healthy" || fail "empty health directory"
now="$(date +%s)"
write_record "${healthdir}/fresh.env" RUNNING "${now}"
BACKUP_ACTIVE_STATUS_DIR="${healthdir}" BACKUP_MAX_RUNTIME=10s BACKUP_HEALTH_GRACE=0 "${HEALTH}" \
    && pass "fresh RUNNING record is healthy" || fail "fresh record health"
write_record "${healthdir}/fresh.env" RUNNING "$((now - 20))"
rc=0; BACKUP_ACTIVE_STATUS_DIR="${healthdir}" BACKUP_MAX_RUNTIME=10s BACKUP_HEALTH_GRACE=0 "${HEALTH}" || rc=$?
[[ ${rc} -ne 0 ]] && pass "stale RUNNING record is unhealthy" || fail "stale record health"
write_record "${healthdir}/also-fresh.env" RUNNING "${now}"
rc=0; BACKUP_ACTIVE_STATUS_DIR="${healthdir}" BACKUP_MAX_RUNTIME=10s BACKUP_HEALTH_GRACE=0 "${HEALTH}" || rc=$?
[[ ${rc} -ne 0 ]] && pass "concurrent fresh record cannot mask a stale run" || fail "concurrent stale masking"
BACKUP_ACTIVE_STATUS_DIR="${healthdir}" BACKUP_MAX_RUNTIME=0 BACKUP_HEALTH_GRACE=0 "${HEALTH}" \
    && pass "runtime 0 disables stale-age health checking" || fail "disabled stale checking"
write_record "${healthdir}/fresh.env" SUCCESS "$((now - 999))"
write_record "${healthdir}/also-fresh.env" SUCCESS "$((now - 999))"
BACKUP_ACTIVE_STATUS_DIR="${healthdir}" BACKUP_MAX_RUNTIME=1s BACKUP_HEALTH_GRACE=0 "${HEALTH}" \
    && pass "terminal record is ignored" || fail "terminal record health"
printf 'STATE=SUCCESS\n' > "${healthdir}/fresh.env"
rc=0; BACKUP_ACTIVE_STATUS_DIR="${healthdir}" BACKUP_MAX_RUNTIME=1s "${HEALTH}" || rc=$?
[[ ${rc} -ne 0 ]] && pass "malformed terminal record is unhealthy" || fail "malformed terminal record health"
printf 'STATE=RUNNING\nBROKEN=yes\n' > "${healthdir}/fresh.env"
rc=0; BACKUP_ACTIVE_STATUS_DIR="${healthdir}" BACKUP_MAX_RUNTIME=1s "${HEALTH}" || rc=$?
[[ ${rc} -ne 0 ]] && pass "malformed active record is unhealthy" || fail "malformed record health"

# Static/default invocation-path, image, and resolved Compose assertions.
if grep -Fq 'echo "${cron_expr} env PAIR_INDICES=${pair_indices} /app/backup-runner.sh"' \
    "${ROOT}/scripts/entrypoint.sh"; then
    pass "generated cron entries route through canonical runner"
else
    fail "generated cron runner path"
fi

if grep -Fq 'PAIR_INDICES="${pair_indices}" /app/backup-runner.sh || initial_backup_rc=$?' \
    "${ROOT}/scripts/entrypoint.sh"; then
    pass "interval startup routes through canonical runner"
else
    fail "interval startup runner path"
fi

if grep -Fqx '    /app/backup-runner.sh' "${ROOT}/scripts/entrypoint.sh"; then
    pass "entrypoint backup command routes through canonical runner"
else
    fail "entrypoint backup runner path"
fi

if grep -Fq 'backupScript: envOr("BACKUP_SCRIPT", "/app/backup-runner.sh")' \
    "${ROOT}/patches/0006-feat-cli-add-serve-subcommand-embedded-Go-HTTP-web-U.patch"; then
    pass "web UI defaults to canonical runner while retaining override"
else
    fail "web UI runner default"
fi

if grep -Eq '^RUN apk add --no-cache .*\bcoreutils\b' "${ROOT}/Dockerfile"; then
    pass "Docker image installs GNU coreutils"
else
    fail "Docker coreutils installation"
fi

if grep -Fq 'HEALTHCHECK --interval=1m --timeout=10s --start-period=30s --retries=1' \
    "${ROOT}/Dockerfile" \
    && grep -Fq 'CMD ["/app/backup-healthcheck.sh"]' "${ROOT}/Dockerfile"; then
    pass "Docker image declares backup healthcheck"
else
    fail "Docker healthcheck declaration"
fi

if command -v docker >/dev/null 2>&1; then
    compose="$(cd "${ROOT}" && docker compose config 2>/dev/null)"
    if grep -q 'driver: local' <<<"${compose}" && grep -q 'max-file: "3"' <<<"${compose}" \
        && grep -q 'max-size: 10m' <<<"${compose}"; then
        pass "Compose resolves local driver with 10m/3 rotation"
    else
        fail "resolved Compose logging options"
    fi
else
    printf 'SKIP docker compose unavailable\n'
fi

printf '\nResults: %d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ ${FAIL} -eq 0 ]]
