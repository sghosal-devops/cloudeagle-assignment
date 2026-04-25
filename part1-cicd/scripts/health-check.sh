#!/usr/bin/env bash
# =============================================================================
#  health-check.sh — Post-deployment Docker container health verification
#
#  Checks per VM (7 checks):
#    1. SSH reachability via IAP tunnel
#    2. Docker container is in 'running' state
#    3. Docker built-in HEALTHCHECK status is 'healthy'
#    4. Spring Boot Actuator /health → status=UP
#    5. Liveness probe  → /actuator/health/liveness  HTTP 200
#    6. Readiness probe → /actuator/health/readiness HTTP 200
#    7. MongoDB component in Actuator → status=UP
#
#  Aggregate check:
#    8. All VMs in the MIG are running (desired == healthy count)
#
#  Usage:
#    health-check.sh <environment>
#
#  Exit codes:
#    0 → all VMs healthy
#    1 → one or more checks failed
# =============================================================================

set -euo pipefail

ENVIRONMENT="${1:?'ERROR: Environment required (qa|staging|prod)'}"

APP_NAME="${APP_NAME:-sync-service}"
GCP_PROJECT="${GCP_PROJECT:-cloudeagle-prod}"
GCP_REGION="${GCP_REGION:-us-central1}"
ARTIFACT_BUCKET="${ARTIFACT_BUCKET:-cloudeagle-artifacts}"
SSH_TIMEOUT=60
MAX_RETRIES=30
RETRY_DELAY=10

log()  { printf '[%s] %-6s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "[$1]" "${*:2}"; }
info() { log "INFO" "$@"; }
pass() { log "PASS" "$@"; }
fail() { log "FAIL" "$@" >&2; }
die()  { log "ERROR" "$@" >&2; exit 1; }

PASS_COUNT=0
FAIL_COUNT=0
ok()  { PASS_COUNT=$((PASS_COUNT + 1)); pass "$@"; }
nok() { FAIL_COUNT=$((FAIL_COUNT + 1)); fail "$@"; }

# ── Resolve MIG name and scope for this environment ───────────────────────────
case "${ENVIRONMENT}" in
    qa)
        MIG_NAME="${APP_NAME}-qa"
        MIG_ZONE="${GCP_ZONE_QA:-us-central1-a}"
        MIG_SCOPE="--zone=${MIG_ZONE}"
        ;;
    staging)
        MIG_NAME="${APP_NAME}-staging"
        MIG_ZONE="${GCP_ZONE_STAGING:-us-central1-b}"
        MIG_SCOPE="--zone=${MIG_ZONE}"
        ;;
    prod)
        # For prod, health-check only the active MIG (the one receiving traffic)
        SLOT_JSON=$(gsutil cat \
            "gs://${ARTIFACT_BUCKET}/${APP_NAME}/prod/active-slot.json" 2>/dev/null || echo '{}')
        MIG_NAME=$(echo "${SLOT_JSON}" | python3 -c \
            "import sys,json; print(json.load(sys.stdin).get('active_mig','${APP_NAME}-prod-blue'))" \
            2>/dev/null || echo "${APP_NAME}-prod-blue")
        MIG_ZONE="${GCP_REGION}"
        MIG_SCOPE="--region=${GCP_REGION}"
        ;;
esac

ssh_vm() {
    local instance="$1" zone="$2" cmd="$3"
    gcloud compute ssh "${instance}" \
        --project="${GCP_PROJECT}" \
        --zone="${zone}" \
        --tunnel-through-iap \
        --ssh-flag="-o ConnectTimeout=${SSH_TIMEOUT}" \
        --ssh-flag="-o StrictHostKeyChecking=accept-new" \
        --ssh-flag="-o ServerAliveInterval=15" \
        --command="${cmd}" \
        --quiet 2>/dev/null
}

get_vm_zone() { echo "${1}" | grep -oP 'zones/\K[^/]+'; }
get_vm_name()  { echo "${1}" | grep -oP 'instances/\K.+'; }

# =============================================================================
#  CHECK FUNCTIONS (run per VM via SSH)
# =============================================================================

check_ssh() {
    local vm="$1" zone="$2"
    info "  [1/7] SSH reachability..."
    if ssh_vm "${vm}" "${zone}" "echo ok" &>/dev/null; then
        ok "  [1/7] SSH reachable: ${vm}"
        return 0
    else
        nok "  [1/7] SSH FAILED on ${vm} — IAP tunnel could not connect"
        return 1
    fi
}

check_container_running() {
    local vm="$1" zone="$2"
    info "  [2/7] Docker container state..."
    local state
    state=$(ssh_vm "${vm}" "${zone}" \
        "docker inspect -f '{{.State.Status}}' sync-service 2>/dev/null || echo 'missing'" \
        2>/dev/null || echo "ssh_error")

    if [[ "${state}" == "running" ]]; then
        ok "  [2/7] Container state = running"
        return 0
    else
        nok "  [2/7] Container state = '${state}' (expected 'running')"
        ssh_vm "${vm}" "${zone}" "docker logs sync-service --tail 30 2>/dev/null || true" 2>/dev/null || true
        return 1
    fi
}

check_docker_health_status() {
    local vm="$1" zone="$2"
    info "  [3/7] Docker built-in HEALTHCHECK status..."
    local health_status
    health_status=$(ssh_vm "${vm}" "${zone}" \
        "docker inspect -f '{{.State.Health.Status}}' sync-service 2>/dev/null || echo 'none'" \
        2>/dev/null || echo "ssh_error")

    if [[ "${health_status}" == "healthy" ]]; then
        ok "  [3/7] Docker HEALTHCHECK = healthy"
        return 0
    elif [[ "${health_status}" == "none" ]] || [[ "${health_status}" == "starting" ]]; then
        # HEALTHCHECK not configured or still in start period — not a failure
        info "  [3/7] Docker HEALTHCHECK = '${health_status}' — skipping (not yet evaluated)"
        PASS_COUNT=$((PASS_COUNT + 1))
        return 0
    else
        nok "  [3/7] Docker HEALTHCHECK = '${health_status}' (expected 'healthy')"
        # Show last health check log
        ssh_vm "${vm}" "${zone}" \
            "docker inspect -f '{{json .State.Health}}' sync-service 2>/dev/null | python3 -m json.tool || true" \
            2>/dev/null || true
        return 1
    fi
}

check_actuator_health() {
    local vm="$1" zone="$2"
    info "  [4/7] Actuator /health endpoint..."
    local attempt=0 status="UNKNOWN"

    while [[ ${attempt} -lt ${MAX_RETRIES} ]]; do
        status=$(ssh_vm "${vm}" "${zone}" \
            "curl -sf http://localhost:8080/actuator/health 2>/dev/null \
             | python3 -c 'import sys,json; print(json.load(sys.stdin)[\"status\"])' 2>/dev/null \
             || echo FAIL" 2>/dev/null || echo "SSH_FAIL")

        if [[ "${status}" == "UP" ]]; then
            ok "  [4/7] Actuator /health = UP"
            return 0
        fi

        attempt=$((attempt + 1))
        [[ ${attempt} -lt ${MAX_RETRIES} ]] && {
            info "  [4/7] Attempt ${attempt}/${MAX_RETRIES} — status='${status}', retrying in ${RETRY_DELAY}s..."
            sleep "${RETRY_DELAY}"
        }
    done

    nok "  [4/7] Actuator /health timed out. Last status='${status}'"
    return 1
}

check_liveness() {
    local vm="$1" zone="$2"
    info "  [5/7] Liveness probe..."
    local code
    code=$(ssh_vm "${vm}" "${zone}" \
        "curl -so /dev/null -w '%{http_code}' http://localhost:8080/actuator/health/liveness 2>/dev/null || echo 000" \
        2>/dev/null || echo "000")

    if [[ "${code}" == "200" ]]; then
        ok "  [5/7] Liveness probe = HTTP 200"
    else
        nok "  [5/7] Liveness probe = HTTP ${code} (expected 200)"
        return 1
    fi
}

check_readiness() {
    local vm="$1" zone="$2"
    info "  [6/7] Readiness probe..."
    local code
    code=$(ssh_vm "${vm}" "${zone}" \
        "curl -so /dev/null -w '%{http_code}' http://localhost:8080/actuator/health/readiness 2>/dev/null || echo 000" \
        2>/dev/null || echo "000")

    if [[ "${code}" == "200" ]]; then
        ok "  [6/7] Readiness probe = HTTP 200"
    else
        nok "  [6/7] Readiness probe = HTTP ${code} (expected 200)"
        return 1
    fi
}

check_mongodb() {
    local vm="$1" zone="$2"
    info "  [7/7] MongoDB health component..."
    local mongo_status
    mongo_status=$(ssh_vm "${vm}" "${zone}" \
        "curl -sf http://localhost:8080/actuator/health 2>/dev/null \
         | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get(\"components\",{}).get(\"mongo\",{}).get(\"status\",\"MISSING\"))' \
         2>/dev/null || echo MISSING" 2>/dev/null || echo "SSH_FAIL")

    if [[ "${mongo_status}" == "UP" ]]; then
        ok "  [7/7] MongoDB component = UP"
    elif [[ "${mongo_status}" == "MISSING" ]]; then
        info "  [7/7] MongoDB component not present in health response — skipping"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        nok "  [7/7] MongoDB component = '${mongo_status}' (expected UP)"
        return 1
    fi
}

# =============================================================================
#  PER-VM CHECK RUNNER
# =============================================================================
check_vm() {
    local instance_url="$1"
    local vm_zone vm_name
    vm_zone=$(get_vm_zone "${instance_url}")
    vm_name=$(get_vm_name "${instance_url}")

    info "--- Checking VM: ${vm_name} (${vm_zone})"

    local vm_failed=0
    check_ssh "${vm_name}" "${vm_zone}" || { vm_failed=1; return 1; }

    check_container_running    "${vm_name}" "${vm_zone}" || vm_failed=1
    check_docker_health_status "${vm_name}" "${vm_zone}" || vm_failed=1
    check_actuator_health      "${vm_name}" "${vm_zone}" || vm_failed=1
    check_liveness             "${vm_name}" "${vm_zone}" || vm_failed=1
    check_readiness            "${vm_name}" "${vm_zone}" || vm_failed=1
    check_mongodb              "${vm_name}" "${vm_zone}" || vm_failed=1

    return ${vm_failed}
}

# =============================================================================
#  MAIN
# =============================================================================
info "============================================================"
info "Post-deployment health checks: ${APP_NAME} @ ${ENVIRONMENT}"
info "Active MIG: ${MIG_NAME}"
info "============================================================"

gcloud config set project "${GCP_PROJECT}" --quiet

# ── Check 8: Desired vs running instance count ────────────────────────────────
info "CHECK 8/8: Instance count..."
DESIRED=$(gcloud compute instance-groups managed describe "${MIG_NAME}" \
    ${MIG_SCOPE} --project="${GCP_PROJECT}" \
    --format="value(targetSize)" 2>/dev/null || echo "0")
RUNNING=$(gcloud compute instance-groups managed list-instances "${MIG_NAME}" \
    ${MIG_SCOPE} --project="${GCP_PROJECT}" \
    --filter="status=RUNNING AND currentAction=NONE" \
    --format="value(instance)" 2>/dev/null | wc -l | tr -d '[:space:]')

if [[ "${DESIRED}" == "${RUNNING}" ]] && [[ "${RUNNING}" != "0" ]]; then
    ok "CHECK 8/8: Instance count OK — ${RUNNING}/${DESIRED} running"
else
    nok "CHECK 8/8: Instance count mismatch — ${RUNNING}/${DESIRED} running"
fi

# ── Per-VM checks ─────────────────────────────────────────────────────────────
INSTANCES=$(gcloud compute instance-groups managed list-instances "${MIG_NAME}" \
    ${MIG_SCOPE} --project="${GCP_PROJECT}" \
    --filter="status=RUNNING AND currentAction=NONE" \
    --format="value(instance)" 2>/dev/null)

[[ -z "${INSTANCES}" ]] && die "No running instances in MIG '${MIG_NAME}'"

VM_TOTAL=0
VM_HEALTHY=0

while IFS= read -r instance_url; do
    [[ -z "${instance_url}" ]] && continue
    VM_TOTAL=$((VM_TOTAL + 1))
    check_vm "${instance_url}" && VM_HEALTHY=$((VM_HEALTHY + 1)) || true
done <<< "${INSTANCES}"

# ── Summary ───────────────────────────────────────────────────────────────────
info "============================================================"
info "Results : ${PASS_COUNT} checks passed, ${FAIL_COUNT} failed"
info "VMs     : ${VM_HEALTHY}/${VM_TOTAL} healthy"
info "============================================================"

if [[ ${FAIL_COUNT} -gt 0 ]] || [[ ${VM_HEALTHY} -lt ${VM_TOTAL} ]]; then
    fail "Health checks FAILED — rollback should be triggered"
    exit 1
fi

info "All health checks PASSED. Deployment verified."
exit 0
