#!/usr/bin/env bash
# =============================================================================
#  rollback.sh — Roll back sync-service Docker container on GCP VMs
#
#  Usage:
#    rollback.sh <environment> [image-tag]
#
#    environment : qa | staging | prod
#    image-tag   : (optional) full GCR image to roll back to.
#                  If omitted:
#                    prod     → flips LB back to previous MIG (no docker needed)
#                    non-prod → re-runs previous image recorded on each VM
#
#  SSH mechanism: gcloud compute ssh --tunnel-through-iap (OS Login — no static keys)
# =============================================================================

set -euo pipefail

ENVIRONMENT="${1:?'ERROR: Environment required (qa|staging|prod)'}"
TARGET_IMAGE="${2:-}"

APP_NAME="${APP_NAME:-sync-service}"
GCP_PROJECT="${GCP_PROJECT:-cloudeagle-prod}"
GCP_REGION="${GCP_REGION:-us-central1}"
GCR_HOST="gcr.io"
SSH_TIMEOUT=120
ROLLOUT_TIMEOUT=300

log()  { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die()  { log "ERROR: $*" >&2; exit 1; }
warn() { log "WARN:  $*"; }

case "${ENVIRONMENT}" in
    qa|staging|prod) ;;
    *) die "Unknown environment '${ENVIRONMENT}'" ;;
esac

ssh_vm() {
    local instance="$1" zone="$2" cmd="$3"
    gcloud compute ssh "${instance}" \
        --project="${GCP_PROJECT}" \
        --zone="${zone}" \
        --tunnel-through-iap \
        --ssh-flag="-o ConnectTimeout=${SSH_TIMEOUT}" \
        --ssh-flag="-o StrictHostKeyChecking=accept-new" \
        --ssh-flag="-o ServerAliveInterval=30" \
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
#  CORE: Swap Docker container to rollback image on a single VM
# =============================================================================
rollback_container_on_vm() {
    local instance_name="$1" zone="$2" rollback_image="$3"
    log "Restoring ${instance_name} → ${rollback_image}"

    ssh_vm "${instance_name}" "${zone}" "
        set -euo pipefail

        gcloud auth configure-docker ${GCR_HOST} --quiet

        echo '[rollback] Pulling rollback image...'
        docker pull ${rollback_image}

        echo '[rollback] Refreshing secrets...'
        sudo /opt/sync-service/fetch-secrets.sh

        echo '[rollback] Stopping current container...'
        docker stop --time=30 sync-service 2>/dev/null || true
        docker rm sync-service 2>/dev/null || true

        echo '[rollback] Starting rollback container...'
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
          --memory=2g --memory-swap=2g --cpus=2 \
          --read-only \
          --tmpfs /tmp:rw,noexec,nosuid,size=256m \
          --security-opt=no-new-privileges:true \
          ${rollback_image}

        echo '${rollback_image}' | sudo tee /etc/sync-service/active-image-tag > /dev/null

        echo '[rollback] Container status:'
        docker ps --filter name=sync-service --format 'table {{.Names}}\t{{.Status}}'
        echo '[rollback] Done on '\\$(hostname)
    "
}

# =============================================================================
#  PRODUCTION ROLLBACK — LB backend flip (< 5 seconds, no docker needed)
#  The previous MIG is still running the old image — just flip the LB.
# =============================================================================
rollback_blue_green() {
    log "=== Blue/Green rollback for PRODUCTION ==="
    local lb_backend="${APP_NAME}-backend-prod"
    local rollback_bucket="cloudeagle-artifacts"

    # Read the slot metadata written by deploy.sh
    local slot_json
    slot_json=$(gsutil cat "gs://${rollback_bucket}/${APP_NAME}/prod/active-slot.json" 2>/dev/null || echo '{}')

    local previous_mig current_mig prev_image
    previous_mig=$(echo "${slot_json}" | python3 -c \
        "import sys,json; print(json.load(sys.stdin).get('previous_mig',''))" 2>/dev/null || echo "")
    current_mig=$(echo "${slot_json}" | python3 -c \
        "import sys,json; print(json.load(sys.stdin).get('active_mig',''))" 2>/dev/null || echo "")
    prev_image=$(echo "${slot_json}" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); print(d.get('previous_image_tag', d.get('image_tag','')))" \
        2>/dev/null || echo "")

    [[ -z "${previous_mig}" ]] && \
        die "Cannot determine previous MIG from active-slot.json. Manual rollback required."

    log "Currently active : ${current_mig}"
    log "Rolling back to  : ${previous_mig}"

    # If a specific image was supplied, redeploy it to the previous MIG first
    if [[ -n "${TARGET_IMAGE}" ]]; then
        log "Redeploying specific image (${TARGET_IMAGE}) to ${previous_mig} before traffic switch..."
        local prev_instances
        prev_instances=$(get_mig_instances "${previous_mig}" "--region=${GCP_REGION}")
        while IFS= read -r instance_url; do
            [[ -z "${instance_url}" ]] && continue
            rollback_container_on_vm \
                "$(get_vm_name "${instance_url}")" \
                "$(get_vm_zone "${instance_url}")" \
                "${TARGET_IMAGE}"
        done <<< "${prev_instances}"
    fi

    # Ensure the previous MIG has healthy instances
    local prev_running
    prev_running=$(get_mig_instances "${previous_mig}" "--region=${GCP_REGION}" | wc -l | tr -d '[:space:]')
    if [[ "${prev_running}" == "0" ]]; then
        log "Previous MIG has 0 instances — scaling up to match active MIG..."
        local target_size
        target_size=$(gcloud compute instance-groups managed describe "${current_mig}" \
            --region="${GCP_REGION}" --project="${GCP_PROJECT}" \
            --format="value(targetSize)" 2>/dev/null || echo "3")
        gcloud compute instance-groups managed resize "${previous_mig}" \
            --size="${target_size}" --region="${GCP_REGION}" --project="${GCP_PROJECT}"
        gcloud compute instance-groups managed wait-until "${previous_mig}" \
            --stable --region="${GCP_REGION}" --project="${GCP_PROJECT}" \
            --timeout="${ROLLOUT_TIMEOUT}" \
            || die "Previous MIG failed to start. Manual intervention required."
    fi

    # Flip the LB backend — this is what actually switches user traffic
    log "Flipping LB backend: ${current_mig} → ${previous_mig} ..."
    local prev_mig_url
    prev_mig_url=$(gcloud compute instance-groups managed describe "${previous_mig}" \
        --region="${GCP_REGION}" --project="${GCP_PROJECT}" \
        --format="value(selfLink)" 2>/dev/null)

    gcloud compute backend-services update "${lb_backend}" \
        --global --project="${GCP_PROJECT}" \
        --backends="group=${prev_mig_url},balancing-mode=UTILIZATION,max-utilization=0.8,capacity-scaler=1"

    # Update active-slot.json to reflect the rollback
    printf '{
        "active_mig":    "%s",
        "previous_mig":  "%s",
        "image_tag":     "%s",
        "rolled_back_at":"%s",
        "rollback_by":   "automated"
    }' "${previous_mig}" "${current_mig}" "${prev_image:-unknown}" \
       "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    | gsutil cp - "gs://${rollback_bucket}/${APP_NAME}/prod/active-slot.json"

    log "=== Production rollback COMPLETE (< 5 seconds) ==="
    log "Traffic is now on: ${previous_mig} (previous stable version)"
    log "IMPORTANT: '${current_mig}' is still running — investigate before scaling down."
}

# =============================================================================
#  NON-PRODUCTION ROLLBACK — redeploy previous image to all VMs
# =============================================================================
rollback_rolling() {
    local mig_name zone scope

    case "${ENVIRONMENT}" in
        qa)
            mig_name="${APP_NAME}-qa"
            zone="${GCP_ZONE_QA:-us-central1-a}"
            scope="--zone=${zone}"
            ;;
        staging)
            mig_name="${APP_NAME}-staging"
            zone="${GCP_ZONE_STAGING:-us-central1-b}"
            scope="--zone=${zone}"
            ;;
    esac

    log "=== Rolling rollback for ${ENVIRONMENT} (MIG: ${mig_name}) ==="

    # Determine rollback image: use supplied tag, or read from each VM's record
    local rollback_image="${TARGET_IMAGE:-}"

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

        # If no target image given, read previous-image-tag from the VM itself
        local image_to_restore="${rollback_image}"
        if [[ -z "${image_to_restore}" ]]; then
            image_to_restore=$(ssh_vm "${vm_name}" "${vm_zone}" \
                "cat /etc/sync-service/previous-image-tag 2>/dev/null || echo ''" \
                2>/dev/null || echo "")
            [[ -z "${image_to_restore}" ]] && {
                warn "${vm_name}: No previous image recorded — skipping this VM"
                failed=$((failed + 1))
                continue
            }
        fi

        log "--- Restoring VM ${total}: ${vm_name} → ${image_to_restore}"
        if rollback_container_on_vm "${vm_name}" "${vm_zone}" "${image_to_restore}"; then
            log "Rollback successful on ${vm_name}"
        else
            warn "Rollback FAILED on ${vm_name} — manual intervention required"
            failed=$((failed + 1))
        fi
    done <<< "${instances}"

    [[ ${failed} -gt 0 ]] && \
        die "Rollback failed on ${failed}/${total} VMs. Manual intervention required."
    log "=== Rolling rollback complete (${total} VMs restored) ==="
}

# =============================================================================
#  MAIN
# =============================================================================
log "Initiating rollback: app=${APP_NAME} | env=${ENVIRONMENT}${TARGET_IMAGE:+ | image=${TARGET_IMAGE}}"
gcloud config set project "${GCP_PROJECT}" --quiet

if [[ "${ENVIRONMENT}" == "prod" ]]; then
    rollback_blue_green
else
    rollback_rolling
fi

log "Rollback script finished."
