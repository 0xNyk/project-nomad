#!/bin/bash

# Project N.O.M.A.D. Recovery Verification Script
# Runs quick checks after restore or outage recovery.

set -euo pipefail

NOMAD_DIR="/opt/project-nomad"
COMPOSE_FILE="${NOMAD_DIR}/compose.yml"
HEALTH_URL="http://localhost:8080/api/health"

RESET='\033[0m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
GREEN='\033[1;32m'

log() {
  echo -e "${GREEN}#${RESET} $*"
}

warn() {
  echo -e "${YELLOW}#${RESET} $*"
}

fail() {
  echo -e "${RED}#${RESET} $*"
  exit 1
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || fail "Missing required command: ${cmd}"
}

check_files() {
  [[ -f "$COMPOSE_FILE" ]] || fail "Missing compose file: ${COMPOSE_FILE}"
  [[ -d "${NOMAD_DIR}/storage" ]] || fail "Missing storage directory: ${NOMAD_DIR}/storage"
  [[ -d "${NOMAD_DIR}/mysql" ]] || warn "MySQL data dir missing: ${NOMAD_DIR}/mysql"
  [[ -d "${NOMAD_DIR}/redis" ]] || warn "Redis data dir missing: ${NOMAD_DIR}/redis"

  log "Required files/directories are present."
}

check_compose_config() {
  docker compose -p project-nomad -f "$COMPOSE_FILE" config >/dev/null
  log "Docker compose config is valid."
}

check_containers() {
  mapfile -t containers < <(docker ps --filter "name=^nomad_" --format "{{.Names}}")

  if [[ "${#containers[@]}" -eq 0 ]]; then
    warn "No running nomad_ containers found. Starting stack now..."
    docker compose -p project-nomad -f "$COMPOSE_FILE" up -d
    mapfile -t containers < <(docker ps --filter "name=^nomad_" --format "{{.Names}}")
  fi

  if [[ "${#containers[@]}" -eq 0 ]]; then
    fail "No Nomad containers are running after startup attempt."
  fi

  log "Running Nomad containers: ${containers[*]}"
}

check_health() {
  require_cmd curl

  warn "Checking API health endpoint..."
  for _ in {1..20}; do
    if curl -fsS "$HEALTH_URL" >/dev/null 2>&1; then
      log "Health check passed at ${HEALTH_URL}"
      return
    fi
    sleep 3
  done

  fail "Health endpoint is not responding: ${HEALTH_URL}"
}

check_docker_health_statuses() {
  warn "Inspecting container health states..."
  mapfile -t states < <(docker ps --filter "name=^nomad_" --format "{{.Names}} {{.Status}}")

  for state in "${states[@]}"; do
    echo "$state"
  done

  log "Container status report complete."
}

require_cmd docker
check_files
check_compose_config
check_containers
check_health
check_docker_health_statuses

log "Recovery verification finished successfully."
