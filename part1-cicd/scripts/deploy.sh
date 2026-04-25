#!/usr/bin/env bash
# =============================================================================
#  deploy.sh — Deploy sync-service Docker container to GCP Compute Engine VMs
#
#  Usage:
#    deploy.sh <environment> <image-tag>
#
#    environment : qa | staging | prod
#    image-tag   : full GCR image reference, e.g.
#                  gcr.io/cloudeagle-prod/sync-service:abc1234
#
#  Deployment mechanism:
#    Jenkins SSHes into each VM via Cloud IAP tunnel (OS Login — no static keys).
#    On each VM: gcloud auth configure-docker → docker pull → docker stop → docker run.
#    Secrets are fetched from Secret Manager at container start via fetch-secrets.sh.
#
#  Strategies:
#    qa / staging → Rolling : VMs updated one-at-a-time; health-checked before proceeding
#    prod         → Blue/Green: deploy to idle MIG in parallel, health-check,
#                               then switch GCP LB backend (< 5 seconds)
#
#  Required env vars (injected by Jenkinsfile):
#    GCP_PROJECT     — GCP project ID
#    GCP_REGION      — GCP region
#    BUILD_NUMBER    — Jenkins build number (for audit log)
#    APPROVED_BY     — (prod only) approver identity
#    CHANGE_TICKET   — (prod only) change management ticket
#
#  Exit codes:
#    0 → deployment successful
#    1 → deployment failed (caller should invoke rollback.sh)
# =============================================================================

set -euo pipefail

ENVIRONMENT="${1:?'ERROR: Environment required (qa|staging|prod)'}"
IMAGE_TAG="${2:?'ERROR: Image tag required (e.g. gcr.io/cloudeagle-prod/sync-service:abc1234)'}"

APP_NAME="${APP_NAME:-sync-service}"
GCP_PROJECT="${GCP_PROJECT:-cloudeagle-prod}"
GCP_REGION="${GCP_REGION:-us-central1}"
GCR_HOST="gcr.io"
SSH_TIMEOUT=120
HEALTH_RETRIES=30
HEALTH_DELAY=10

log()  { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die()  { log "ERROR: $*" >&2; exit 1; }
warn() { log "WARN:  $*"; }

# ── Validation ────────────────────────────────────────────────────────────────
case "${ENVIRONMENT}" in
    qa|staging|prod) ;;
    *) die "Unknown environment '${ENVIRONMENT}'. Must be qa|staging|prod" ;;
esac

if [[ "${ENVIRONMENT}" == "prod" ]]; then
    [[ -z "${APPROVED_BY:-}"   ]] && die "APPROVED_BY env var required for production deployment"
    [[ -z "${CHANGE_TICKET:-}" ]] && die "CHANGE_TICKET env var required for production deployment"
fi

# Verify the image exists in GCR before touching any VM
log "Verifying image exists in GCR: ${IMAGE_TAG}"
gcloud container images describe "${IMAGE_TAG}" \
    --project="${GCP_PROJECT}" \
    &>/dev/null \
    || die "Image not found in GCR: ${IMAGE_TAG}. Ensure the 'Push to GCR' stage succeeded."

# ── SSH helper ─────────────────────────────────────────────────────────────────
# Uses gcloud compute ssh which:
#   - Authenticates via OS Login using the Jenkins GCE service account
#   - Tunnels through Cloud IAP — VMs need no public IP
#   - Generates ephemeral SSH certificates valid for 10 min — zero static keys
ssh_vm() {
    local instance="$1" zone="$2" cmd="$3"
    log "SSH → ${instance} [${zone}]"
    gcloud compute ssh "${instance}" \
        --project="${GCP_PROJECT}" \
        --zone="${zone}" \
        --tunnel-through-iap \
        --ssh-flag="-o ConnectTimeout=${SSH_TIMEOUT}" \
        --ssh-flag="-o StrictHostKeyChecking=accept-new" \
        --ssh-flag="-o ServerAliveInterval=30" \
        --ssh-flag="-o ServerAliveCountMax=3" \
        --command="${cmd}" \
        --quiet
}

get_mig_instances() {
    local mig_name="$1" scope="$2"
    gcloud compute instance-groups managed list-instances "${mig_name}" \
        ${scope} \
        --project="${GCP_PROJECT}" \
        --format="value(instance)" \
        --filter="currentAction=NONE AND status=RUNNING" 2>/dev/null
}

get_vm_zone() { echo "${1}" | grep -oP 'zones/\K[^/]+'; }
get_vm_name()  { echo "${1}" | grep -oP 'instances/\K.+'; }

# =============================================================================
#  CORE: Deploy Docker container to a single VM
# =============================================================================
deploy_container_to_vm() {
    local instance_name="$1" zone="$2"
    log "Deploying ${IMAGE_TAG} to ${instance_name} (${zone})..."

    ssh_vm "${instance_name}" "${zone}" "
        set -euo pipefail

        # ── Authenticate Docker to GCR using the VM's GCE service account ────
        # Uses GCE metadata server — no docker login, no credentials stored on disk.
        echo '[deploy] Configuring Docker auth for GCR...'
        gcloud auth configure-docker ${GCR_HOST} --quiet

        # ── Pull the new image ─────────────────────────────────────────────────
        echo '[deploy] Pulling image: ${IMAGE_TAG}...'
        docker pull ${IMAGE_TAG}

        # ── Preserve previous image tag for rollback ──────────────────────────
        # If this VM already has a running deployment, save its active image tag
        # before replacing the container. Non-prod rollback reads this file.
        if [[ -f /etc/sync-service/active-image-tag ]]; then
            sudo cp /etc/sync-service/active-image-tag /etc/sync-service/previous-image-tag
        else
            current_image=\$(docker inspect -f '{{.Config.Image}}' sync-service 2>/dev/null || echo '')
            if [[ -n \"\${current_image}\" ]]; then
                echo \"\${current_image}\" | sudo tee /etc/sync-service/previous-image-tag > /dev/null
            fi
        fi

        # ── Fetch secrets from Secret Manager into tmpfs ───────────────────────
        # /run/sync-service/ is a tmpfs mount — secrets never touch persistent disk.
        echo '[deploy] Fetching secrets from Secret Manager...'
        sudo /opt/sync-service/fetch-secrets.sh

        # ── Graceful shutdown: SIGTERM + 30s drain window ─────────────────────
        if docker inspect sync-service &>/dev/null; then
            echo '[deploy] Stopping existing container (30s graceful drain)...'
            docker stop --time=30 sync-service
            docker rm sync-service
        fi

        # ── Start new container ────────────────────────────────────────────────
        echo '[deploy] Starting new container...'
        docker run -d \
          --name sync-service \
          --restart unless-stopped \
          -p 8080:8080 \
          -p 8081:8081 \
          --env-file /etc/sync-service/env \
          --env-file /run/sync-service/secrets.env \
          -v /etc/sync-service/application.yml:/app/config/application.yml:ro \
          -v /var/log/sync-service:/app/logs \
          --log-driver=gcplogs \
          --log-opt gcp-project=${GCP_PROJECT} \
          --log-opt gcp-log-cmd=true \
          --memory=2g \
          --memory-swap=2g \
          --cpus=2 \
          --read-only \
          --tmpfs /tmp:rw,noexec,nosuid,size=256m \
          --security-opt=no-new-privileges:true \
          ${IMAGE_TAG}

        # Record active image tag on VM for rollback reference
        echo '${IMAGE_TAG}' | sudo tee /etc/sync-service/active-image-tag > /dev/null

        echo '[deploy] Container started. Status:'
        docker ps --filter name=sync-service --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
    "
}

# =============================================================================
#  HEALTH CHECK: Verify container is healthy on a single VM
# =============================================================================
verify_vm_health() {
    local instance_name="$1" zone="$2"
    local attempt=0

    while [[ ${attempt} -lt ${HEALTH_RETRIES} ]]; do
        local result
        result=$(ssh_vm "${instance_name}" "${zone}" "
            # Check Docker container state
            state=\$(docker inspect -f '{{.State.Status}}' sync-service 2>/dev/null || echo 'missing')
            if [[ \"\${state}\" != 'running' ]]; then
                echo \"CONTAINER_NOT_RUNNING:\${state}\"
                exit 0
            fi

            # Check Spring Boot Actuator health via localhost
            status=\$(curl -sf http://localhost:8080/actuator/health 2>/dev/null \
              | python3 -c 'import sys,json; print(json.load(sys.stdin)[\"status\"])' 2>/dev/null \
              || echo 'CURL_FAIL')
            echo \"\${status}\"
        " 2>/dev/null || echo "SSH_FAIL")

        if [[ "${result}" == "UP" ]]; then
            log "Health check PASSED on ${instance_name} (status=UP)"
            return 0
        fi

        attempt=$((attempt + 1))
        warn "Health check attempt ${attempt}/${HEALTH_RETRIES} on ${instance_name} — status='${result}'"

        if [[ ${attempt} -ge ${HEALTH_RETRIES} ]]; then
            log "ERROR: Health check timed out on ${instance_name}"
            ssh_vm "${instance_name}" "${zone}" \
                "docker logs sync-service --tail 50 2>/dev/null || true" || true
            return 1
        fi
        sleep "${HEALTH_DELAY}"
    done
}

# =============================================================================
#  ROLLING DEPLOYMENT — qa, staging
#  Updates one VM at a time; only proceeds to the next if health check passes.
# =============================================================================
deploy_rolling() {
    local mig_name="$1" zone="$2" scope="$3"
    log "=== Rolling deployment to ${ENVIRONMENT} (MIG: ${mig_name}) ==="

    local instances
    instances=$(get_mig_instances "${mig_name}" "${scope}")
    [[ -z "${instances}" ]] && die "No running instances in MIG '${mig_name}'."

    local total=0 failed=0

    while IFS= read -r instance_url; do
        [[ -z "${instance_url}" ]] && continue
        total=$((total + 1))
        local vm_zone vm_name
        vm_zone=$(get_vm_zone "${instance_url}")
        vm_name=$(get_vm_name "${instance_url}")

        log "--- Rolling update VM ${total}: ${vm_name} (${vm_zone})"

        if deploy_container_to_vm "${vm_name}" "${vm_zone}"; then
            if verify_vm_health "${vm_name}" "${vm_zone}"; then
                log "VM ${vm_name}: healthy after update"
            else
                warn "VM ${vm_name}: health check failed — rolling back this VM"
                rollback_single_vm "${vm_name}" "${vm_zone}"
                failed=$((failed + 1))
            fi
        else
            warn "VM ${vm_name}: deployment failed"
            failed=$((failed + 1))
        fi
    done <<< "${instances}"

    [[ ${failed} -gt 0 ]] && die "Rolling deployment failed on ${failed}/${total} VMs."
    log "=== Rolling deployment to ${ENVIRONMENT} complete (${total} VMs updated) ==="
}

# =============================================================================
#  BLUE/GREEN DEPLOYMENT — prod
# =============================================================================
deploy_blue_green() {
    local lb_backend="${APP_NAME}-backend-prod"
    log "=== Blue/Green deployment to PRODUCTION ==="
    log "Image   : ${IMAGE_TAG}"
    log "Approver: ${APPROVED_BY:-ci} | Ticket: ${CHANGE_TICKET:-n/a}"

    # Determine active and idle MIG
    local current_slot new_slot
    current_slot=$(gcloud compute backend-services get-health "${lb_backend}" \
        --global --project="${GCP_PROJECT}" \
        --format="value(status.healthStatus[0].instance)" 2>/dev/null \
        | grep -oP "(blue|green)" | head -1 || echo "blue")
    new_slot=$( [[ "${current_slot}" == "blue" ]] && echo "green" || echo "blue" )
    local current_mig="${APP_NAME}-prod-${current_slot}"
    local new_mig="${APP_NAME}-prod-${new_slot}"

    log "Active MIG : ${current_mig}"
    log "Target MIG : ${new_mig}"

    local previous_image_tag="unknown"
    local current_instances
    current_instances=$(get_mig_instances "${current_mig}" "--region=${GCP_REGION}" || true)
    if [[ -n "${current_instances}" ]]; then
        local first_current_instance first_current_zone
        first_current_instance=$(get_vm_name "$(echo "${current_instances}" | head -1)")
        first_current_zone=$(get_vm_zone "$(echo "${current_instances}" | head -1)")
        previous_image_tag=$(ssh_vm "${first_current_instance}" "${first_current_zone}" \
            "cat /etc/sync-service/active-image-tag 2>/dev/null || docker inspect -f '{{.Config.Image}}' sync-service 2>/dev/null || echo unknown" \
            2>/dev/null || echo "unknown")
    fi

    # Scale up idle MIG if it has no instances
    local idle_instances
    idle_instances=$(get_mig_instances "${new_mig}" "--region=${GCP_REGION}")
    if [[ -z "${idle_instances}" ]]; then
        local active_size
        active_size=$(gcloud compute instance-groups managed describe "${current_mig}" \
            --region="${GCP_REGION}" --project="${GCP_PROJECT}" \
            --format="value(targetSize)" 2>/dev/null || echo "3")
        log "Idle MIG has 0 instances — resizing to ${active_size}..."
        gcloud compute instance-groups managed resize "${new_mig}" \
            --size="${active_size}" --region="${GCP_REGION}" --project="${GCP_PROJECT}"
        gcloud compute instance-groups managed wait-until "${new_mig}" \
            --stable --region="${GCP_REGION}" --project="${GCP_PROJECT}" --timeout=300
        idle_instances=$(get_mig_instances "${new_mig}" "--region=${GCP_REGION}")
    fi

    # Deploy to all idle MIG VMs in parallel
    log "Deploying to all VMs in idle MIG (${new_mig}) in parallel..."
    local pids=() vm_names=() vm_zones=()
    while IFS= read -r instance_url; do
        [[ -z "${instance_url}" ]] && continue
        local vm_zone vm_name
        vm_zone=$(get_vm_zone "${instance_url}")
        vm_name=$(get_vm_name "${instance_url}")
        vm_names+=("${vm_name}")
        vm_zones+=("${vm_zone}")
        deploy_container_to_vm "${vm_name}" "${vm_zone}" &
        pids+=($!)
    done <<< "${idle_instances}"

    local deploy_failed=0
    for i in "${!pids[@]}"; do
        wait "${pids[$i]}" || { warn "Deploy failed on VM: ${vm_names[$i]}"; deploy_failed=$((deploy_failed + 1)); }
    done
    [[ ${deploy_failed} -gt 0 ]] && die "Deploy failed on ${deploy_failed} VMs in idle MIG. LB traffic NOT switched."

    # Health-check all idle MIG VMs (zero live traffic — safe to verify)
    log "Health-checking all VMs in idle MIG before switching traffic..."
    idle_instances=$(get_mig_instances "${new_mig}" "--region=${GCP_REGION}")
    while IFS= read -r instance_url; do
        [[ -z "${instance_url}" ]] && continue
        local vm_zone vm_name
        vm_zone=$(get_vm_zone "${instance_url}")
        vm_name=$(get_vm_name "${instance_url}")
        verify_vm_health "${vm_name}" "${vm_zone}" \
            || die "Health check failed on ${vm_name}. LB traffic will NOT be switched."
    done <<< "${idle_instances}"

    # Atomic LB traffic switch
    log "Switching LB traffic: ${current_mig} → ${new_mig} ..."
    local new_mig_url
    new_mig_url=$(gcloud compute instance-groups managed describe "${new_mig}" \
        --region="${GCP_REGION}" --project="${GCP_PROJECT}" \
        --format="value(selfLink)" 2>/dev/null)
    gcloud compute backend-services update "${lb_backend}" \
        --global --project="${GCP_PROJECT}" \
        --backends="group=${new_mig_url},balancing-mode=UTILIZATION,max-utilization=0.8,capacity-scaler=1"

    # Persist rollback metadata to GCS
    local rollback_bucket="cloudeagle-artifacts"
    printf '{
        "active_mig":    "%s",
        "previous_mig":  "%s",
        "image_tag":     "%s",
        "previous_image_tag": "%s",
        "build":         "%s",
        "approved_by":   "%s",
        "change_ticket": "%s",
        "switched_at":   "%s"
    }' "${new_mig}" "${current_mig}" "${IMAGE_TAG}" \
       "${previous_image_tag}" "${BUILD_NUMBER:-0}" "${APPROVED_BY:-ci}" "${CHANGE_TICKET:-n/a}" \
       "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    | gsutil cp - "gs://${rollback_bucket}/${APP_NAME}/prod/active-slot.json"

    log "=== Blue/Green deployment COMPLETE ==="
    log "Traffic now on : ${new_mig} (image: ${IMAGE_TAG})"
    log "Rollback ready : ${current_mig} is still running, not receiving traffic"
    log "To rollback    : ./rollback.sh prod"
}

# ── Rollback a single VM to its previous image ────────────────────────────────
rollback_single_vm() {
    local instance_name="$1" zone="$2"
    warn "Rolling back ${instance_name} to previous image..."
    local prev_image
    prev_image=$(ssh_vm "${instance_name}" "${zone}" \
        "cat /etc/sync-service/previous-image-tag 2>/dev/null || echo ''" 2>/dev/null || echo "")

    if [[ -z "${prev_image}" ]]; then
        warn "No previous image recorded on ${instance_name}. Cannot auto-rollback this VM."
        return 1
    fi

    ssh_vm "${instance_name}" "${zone}" "
        gcloud auth configure-docker ${GCR_HOST} --quiet
        docker pull ${prev_image} || true
        sudo /opt/sync-service/fetch-secrets.sh
        docker stop --time=30 sync-service 2>/dev/null || true
        docker rm sync-service 2>/dev/null || true
        docker run -d \
          --name sync-service --restart unless-stopped \
          -p 8080:8080 -p 8081:8081 \
          --env-file /etc/sync-service/env \
          --env-file /run/sync-service/secrets.env \
          -v /etc/sync-service/application.yml:/app/config/application.yml:ro \
          -v /var/log/sync-service:/app/logs \
          --log-driver=gcplogs --log-opt gcp-project=${GCP_PROJECT} \
          ${prev_image}
        echo '${prev_image}' | sudo tee /etc/sync-service/active-image-tag > /dev/null
    "
}

# =============================================================================
#  MAIN
# =============================================================================
log "Deploying: app=${APP_NAME} | env=${ENVIRONMENT} | image=${IMAGE_TAG}"
gcloud config set project "${GCP_PROJECT}" --quiet

case "${ENVIRONMENT}" in
    qa)
        deploy_rolling "${APP_NAME}-qa" "${GCP_ZONE_QA:-us-central1-a}" "--zone=${GCP_ZONE_QA:-us-central1-a}"
        ;;
    staging)
        deploy_rolling "${APP_NAME}-staging" "${GCP_ZONE_STAGING:-us-central1-b}" "--zone=${GCP_ZONE_STAGING:-us-central1-b}"
        ;;
    prod)
        deploy_blue_green
        ;;
esac

log "Deployment script finished successfully."
