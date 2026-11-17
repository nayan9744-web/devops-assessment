#!/usr/bin/env bash
#
# deploy.sh <image-tag> - deploy a tagged image on the EC2 host with automatic rollback.
#
# Executed on the instance by GitHub Actions through SSM Run Command (and once by user data).
# Flow: pull new image -> stop current container -> start new one -> smoke test /health
#       -> on failure: restore the previous tag and exit non-zero so the pipeline fails.
#
set -euo pipefail

readonly CONFIG_FILE="${CONFIG_FILE:-/etc/devops-task/app.env}"
readonly STATE_DIR="${STATE_DIR:-/opt/devops-task}"
readonly CONTAINER="devops-task"
readonly HEALTH_RETRIES="${HEALTH_RETRIES:-15}"
readonly HEALTH_INTERVAL="${HEALTH_INTERVAL:-2}"

log() { printf '%s [deploy] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "ERROR: $*"; exit 1; }

[[ $# -eq 1 && -n "$1" ]] || die "usage: $0 <image-tag>"
NEW_TAG="$1"
[[ "${NEW_TAG}" =~ ^[A-Za-z0-9_.-]{1,128}$ ]] || die "invalid image tag: ${NEW_TAG}"

[[ -r "${CONFIG_FILE}" ]] || die "missing ${CONFIG_FILE}"
# shellcheck source=/dev/null
source "${CONFIG_FILE}"
: "${AWS_REGION:?}" "${ECR_REGISTRY:?}" "${ECR_REPOSITORY:?}" "${APP_ENV:?}" "${LOG_GROUP:?}"
HTTP_PORT="${HTTP_PORT:-80}"
LOG_LEVEL="${LOG_LEVEL:-INFO}"
LOG_DRIVER="${LOG_DRIVER:-awslogs}"   # override (e.g. json-file) only for local testing

CURRENT_TAG_FILE="${STATE_DIR}/current_tag"
PREVIOUS_TAG=""
[[ -f "${CURRENT_TAG_FILE}" ]] && PREVIOUS_TAG="$(<"${CURRENT_TAG_FILE}")"

ecr_login() {
  aws ecr get-login-password --region "${AWS_REGION}" \
    | docker login --username AWS --password-stdin "${ECR_REGISTRY}" >/dev/null
}

run_container() {
  local tag="$1" instance_id
  instance_id="$(cat /var/lib/cloud/data/instance-id 2>/dev/null || hostname)"
  local -a log_opts=(--log-driver "${LOG_DRIVER}")
  if [[ "${LOG_DRIVER}" == "awslogs" ]]; then
    log_opts+=(
      --log-opt "awslogs-region=${AWS_REGION}"
      --log-opt "awslogs-group=${LOG_GROUP}"
      --log-opt "awslogs-stream=${instance_id}/${CONTAINER}"
      --log-opt mode=non-blocking
    )
  fi
  docker run -d \
    --name "${CONTAINER}" \
    --restart unless-stopped \
    -p "${HTTP_PORT}:8080" \
    -e PORT=8080 \
    -e APP_ENV="${APP_ENV}" \
    -e APP_VERSION="${tag}" \
    -e LOG_LEVEL="${LOG_LEVEL}" \
    --read-only --tmpfs /tmp \
    --cap-drop ALL --security-opt no-new-privileges:true \
    --memory 256m --cpus 0.5 \
    --stop-timeout 25 \
    "${log_opts[@]}" \
    "${ECR_REPOSITORY}:${tag}" >/dev/null
}

remove_container() {
  if docker container inspect "${CONTAINER}" >/dev/null 2>&1; then
    docker stop --time 25 "${CONTAINER}" >/dev/null || true   # SIGTERM -> graceful shutdown
    docker rm -f "${CONTAINER}" >/dev/null || true
  fi
}

smoke_test() {
  local i
  for (( i = 1; i <= HEALTH_RETRIES; i++ )); do
    if curl -fsS -m 3 "http://127.0.0.1:${HTTP_PORT}/health" >/dev/null 2>&1; then
      log "smoke test passed (attempt ${i})"
      return 0
    fi
    sleep "${HEALTH_INTERVAL}"
  done
  return 1
}

main() {
  log "deploying ${ECR_REPOSITORY}:${NEW_TAG} (previous: ${PREVIOUS_TAG:-none})"
  ecr_login
  docker pull --quiet "${ECR_REPOSITORY}:${NEW_TAG}" >/dev/null || die "cannot pull ${NEW_TAG}"

  remove_container
  run_container "${NEW_TAG}"

  if smoke_test; then
    printf '%s\n' "${PREVIOUS_TAG}" > "${STATE_DIR}/previous_tag"
    printf '%s\n' "${NEW_TAG}" > "${CURRENT_TAG_FILE}"
    docker image prune -f >/dev/null 2>&1 || true
    log "SUCCESS: ${NEW_TAG} is live"
    return 0
  fi

  log "smoke test FAILED for ${NEW_TAG}; last container logs:"
  docker logs --tail 50 "${CONTAINER}" 2>&1 || true
  remove_container

  if [[ -n "${PREVIOUS_TAG}" ]]; then
    log "ROLLBACK: restoring ${PREVIOUS_TAG}"
    run_container "${PREVIOUS_TAG}"
    if smoke_test; then
      log "rollback to ${PREVIOUS_TAG} succeeded"
    else
      log "CRITICAL: rollback to ${PREVIOUS_TAG} is also unhealthy"
    fi
  else
    log "no previous tag recorded, nothing to roll back to"
  fi
  exit 1
}

main
