#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"
DEFAULT_VERSION="v0.27.0"
DEFAULT_REGISTRY="swr.cn-north-4.myhuaweicloud.com/infiniflow/ragflow"
DEFAULT_BRANCH="main"
AUTO_COMMIT_PREFIX="pennbay custom"
WEB_URL="http://127.0.0.1:10080"
MCP_URL="http://192.168.88.243:9382/sse"
HEALTH_ATTEMPTS=60
HEALTH_SLEEP_SEC=5

DRY_RUN=0
VERSION="${DEFAULT_VERSION}"
FROM_VERSION=""
REGISTRY="${DEFAULT_REGISTRY}"
BRANCH="${DEFAULT_BRANCH}"
FULL_STACK=0
MODE="gpu"
PUSH=0
SERVICE=""
COMPOSE_PROFILES_VALUE=""
DEVICE_VALUE=""
RAGFLOW_IMAGE=""
RAGFLOW_VERSION=""
GPU_LOCAL_IMAGE=""
REBASE_STARTED=0
AUTO_COMMITTED=0
AUTO_COMMIT_MESSAGE=""
METADATA_DB_PROFILE_VALUE="${METADATA_DB_PROFILE:-mysql}"

set_mode() {
  local mode="$1"

  case "${mode}" in
    gpu)
      MODE="gpu"
      SERVICE="ragflow-gpu"
      COMPOSE_PROFILES_VALUE="elasticsearch,gpu,metadata-${METADATA_DB_PROFILE_VALUE}"
      DEVICE_VALUE="gpu"
      ;;
    *)
      fail "unsupported mode: ${mode}"
      ;;
  esac
}

set_mode "${MODE}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--dry-run] [--version <tag>] [--from-version <tag>] [--full-stack] [--push]
                          [--health-attempts <num>] [--health-sleep-sec <num>]

Rebase the local ${DEFAULT_BRANCH} branch onto a fixed RAGFlow release tag,
optionally create a WIP commit from local changes, force-push the rebased
branch to origin, and recreate the selected service with a fixed release image.

Options:
  --dry-run              Print the planned commands without executing them.
  --version <tag>        Override the target release tag (${DEFAULT_VERSION}).
  --from-version <tag>   Override the detected current release tag.
  --full-stack           Recreate the full compose stack instead of only ${SERVICE}.
  --push                 Push ${DEFAULT_BRANCH} to origin (default: skip).
  --health-attempts <n>  Number of health-check attempts before failing (default: ${HEALTH_ATTEMPTS}).
  --health-sleep-sec <n> Seconds to sleep between health-check attempts (default: ${HEALTH_SLEEP_SEC}).
  -h, --help             Show this help message.
EOF
}

log() {
  printf '[sync] %s\n' "$*"
}

fail() {
  printf '[sync][error] %s\n' "$*" >&2
  exit 1
}

run_cmd() {
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    printf '[dry-run] %s\n' "$*"
    return 0
  fi
  "$@"
}

run_compose() {
  run_cmd env \
    COMPOSE_PROFILES="${COMPOSE_PROFILES_VALUE}" \
    DEVICE="${DEVICE_VALUE}" \
    RAGFLOW_IMAGE="${RAGFLOW_IMAGE}" \
    RAGFLOW_VERSION="${RAGFLOW_VERSION}" \
    GPU_LOCAL_IMAGE="${GPU_LOCAL_IMAGE}" \
    docker compose \
    --project-directory "${SCRIPT_DIR}" \
    -f "${COMPOSE_FILE}" \
    "$@"
}

cleanup_on_error() {
  local exit_code=$?
  local line_no=${1:-unknown}

  printf '[sync][error] failed at line %s with exit code %s\n' "${line_no}" "${exit_code}" >&2

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    exit "${exit_code}"
  fi

  if [[ "${REBASE_STARTED}" -eq 1 ]]; then
    git -C "${REPO_ROOT}" rebase --abort >/dev/null 2>&1 || true
  fi

  exit "${exit_code}"
}

trap 'cleanup_on_error ${LINENO}' ERR

detect_current_base() {
  git -C "${REPO_ROOT}" describe --tags --abbrev=0 --match 'v[0-9]*' "${BRANCH}" 2>/dev/null || true
}

ensure_main_branch() {
  local current_branch
  current_branch="$(git -C "${REPO_ROOT}" branch --show-current)"
  [[ "${current_branch}" == "${BRANCH}" ]] || fail "current branch must be ${BRANCH}, got ${current_branch:-detached HEAD}"
}

create_auto_commit_if_needed() {
  if [[ -z "$(git -C "${REPO_ROOT}" status --porcelain)" ]]; then
    log "worktree already clean"
    return 0
  fi

  AUTO_COMMIT_MESSAGE="${AUTO_COMMIT_PREFIX}: WIP before rebase to ${VERSION}"
  log "create auto commit"
  run_cmd git -C "${REPO_ROOT}" add -A
  run_cmd git -C "${REPO_ROOT}" commit -m "${AUTO_COMMIT_MESSAGE}"
  AUTO_COMMITTED=1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --version)
      [[ $# -ge 2 ]] || fail "--version requires a value"
      VERSION="$2"
      shift 2
      ;;
    --from-version)
      [[ $# -ge 2 ]] || fail "--from-version requires a value"
      FROM_VERSION="$2"
      shift 2
      ;;
    --full-stack)
      FULL_STACK=1
      shift
      ;;
    --push)
      PUSH=1
      shift
      ;;
    --health-attempts)
      [[ $# -ge 2 ]] || fail "--health-attempts requires a value"
      [[ "$2" =~ ^[0-9]+$ ]] || fail "--health-attempts must be a non-negative integer"
      HEALTH_ATTEMPTS="$2"
      shift 2
      ;;
    --health-sleep-sec)
      [[ $# -ge 2 ]] || fail "--health-sleep-sec requires a value"
      [[ "$2" =~ ^[0-9]+$ ]] || fail "--health-sleep-sec must be a non-negative integer"
      HEALTH_SLEEP_SEC="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

[[ -f "${COMPOSE_FILE}" ]] || fail "missing compose file: ${COMPOSE_FILE}"
git -C "${REPO_ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "not inside a git repository: ${REPO_ROOT}"

RAGFLOW_IMAGE="${REGISTRY}:${VERSION}"
RAGFLOW_VERSION="${VERSION}"
GPU_LOCAL_IMAGE="ragflow-gpu-local:${RAGFLOW_VERSION}"

log "branch: ${BRANCH}"
log "target version: ${VERSION}"
log "base image: ${RAGFLOW_IMAGE}"
log "local gpu image: ${GPU_LOCAL_IMAGE}"
log "mode: ${MODE}"

log "fetch"
run_cmd git -C "${REPO_ROOT}" fetch upstream --tags --force
run_cmd git -C "${REPO_ROOT}" fetch origin --prune

if [[ "${DRY_RUN}" -ne 1 ]]; then
  git -C "${REPO_ROOT}" rev-parse --verify --quiet "${VERSION}^{commit}" >/dev/null \
    || fail "version not found after fetch: ${VERSION}"
fi

ensure_main_branch
create_auto_commit_if_needed

CURRENT_BASE="${FROM_VERSION}"
if [[ -z "${CURRENT_BASE}" ]]; then
  CURRENT_BASE="$(detect_current_base)"
fi
[[ -n "${CURRENT_BASE}" ]] || fail "unable to detect current stable base tag; rerun with --from-version <tag>"

log "current base: ${CURRENT_BASE}"

if [[ "${CURRENT_BASE}" == "${VERSION}" ]]; then
  log "rebase: already based on ${VERSION}"
else
  log "rebase ${BRANCH} onto ${VERSION}"
  REBASE_STARTED=1
  run_cmd git -C "${REPO_ROOT}" rebase --onto "${VERSION}" "${CURRENT_BASE}" "${BRANCH}"
  REBASE_STARTED=0
fi

if [[ "${PUSH}" -eq 1 ]]; then
  log "push"
  run_cmd git -C "${REPO_ROOT}" push --force-with-lease origin "${BRANCH}"
else
  log "push: skipped (default; use --push to enable)"
fi

if [[ "${MODE}" == "gpu" ]]; then
  log "build local gpu image"
  run_compose build --pull "${SERVICE}"
else
  log "pull upstream image"
  run_compose pull "${SERVICE}"
fi

log "recreate"
if [[ "${FULL_STACK}" -eq 1 ]]; then
  run_compose up -d --force-recreate
elif [[ "${METADATA_DB_PROFILE_VALUE}" == "mysql" ]]; then
  run_compose up -d --force-recreate "${SERVICE}"
else
  # Recreate only the target service by default. Recreating dependencies like
  # MySQL makes startup materially slower and increases the chance that the
  # health check times out during database initialization.
  run_compose up -d --force-recreate --no-deps "${SERVICE}"
fi

check_http_code() {
  local url="$1"
  local expected="$2"
  local label="$3"
  local code=""

  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "${url}" || true)"
  if [[ "${code}" == "${expected}" ]]; then
    log "health check: ${label} ok (${code})"
    return 0
  fi

  log "health check: ${label} pending (got ${code:-curl-failed}, want ${expected})"
  return 1
}

log "health check"
if [[ "${DRY_RUN}" -eq 1 ]]; then
  printf '[dry-run] expect web 200 at %s\n' "${WEB_URL}"
  printf '[dry-run] expect mcp 401 at %s\n' "${MCP_URL}"
  log "done"
  exit 0
fi

health_ok=0
for ((i=1; i<=HEALTH_ATTEMPTS; i++)); do
  if check_http_code "${WEB_URL}" "200" "web" && check_http_code "${MCP_URL}" "401" "mcp"; then
    health_ok=1
    break
  fi
  sleep "${HEALTH_SLEEP_SEC}"
done

if [[ "${health_ok}" -ne 1 ]]; then
  printf '[sync][error] service did not become healthy in time\n' >&2
  run_compose ps >&2 || true
  run_compose logs --no-color --tail=200 "${SERVICE}" >&2 || true
  exit 1
fi

log "done"
