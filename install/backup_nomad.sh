#!/bin/bash

# Project N.O.M.A.D. Backup Script
# Creates a restorable backup archive for /opt/project-nomad

set -euo pipefail

NOMAD_DIR="/opt/project-nomad"
COMPOSE_FILE="${NOMAD_DIR}/compose.yml"
DEFAULT_BACKUP_DIR="${NOMAD_DIR}/backups"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_NAME="nomad-backup-${TIMESTAMP}"
BACKUP_DIR="$DEFAULT_BACKUP_DIR"
SKIP_STOP=false
SKIP_RESTART=false
INCLUDE_IMAGES=false

RESET='\033[0m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
GREEN='\033[1;32m'
WHITE='\033[39m'

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --output-dir <path>   Backup output directory (default: ${DEFAULT_BACKUP_DIR})
  --name <name>         Backup base name (default: ${BACKUP_NAME})
  --skip-stop           Do not stop containers before backup (faster, less consistent)
  --skip-restart        Do not restart containers after backup
  --include-images      Export current project images with docker save
  -h, --help            Show this help
EOF
}

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

ensure_nomad_exists() {
  [[ -d "$NOMAD_DIR" ]] || fail "Nomad directory not found: ${NOMAD_DIR}"
  [[ -f "$COMPOSE_FILE" ]] || fail "Compose file not found: ${COMPOSE_FILE}"
}

project_running() {
  docker ps --filter "name=^nomad_" --format "{{.Names}}" | grep -q .
}

stop_project() {
  if [[ -x "${NOMAD_DIR}/stop_nomad.sh" ]]; then
    warn "Stopping running Nomad containers for consistent backup..."
    bash "${NOMAD_DIR}/stop_nomad.sh"
    return
  fi

  warn "stop_nomad.sh not found; stopping stack with docker compose..."
  docker compose -p project-nomad -f "$COMPOSE_FILE" stop || true
}

start_project() {
  if [[ -x "${NOMAD_DIR}/start_nomad.sh" ]]; then
    warn "Restarting Nomad containers..."
    bash "${NOMAD_DIR}/start_nomad.sh"
    return
  fi

  warn "start_nomad.sh not found; starting stack with docker compose..."
  docker compose -p project-nomad -f "$COMPOSE_FILE" up -d
}

export_images() {
  local output_path="$1"
  local images_file="${output_path}/images.tar"

  mapfile -t images < <(docker compose -p project-nomad -f "$COMPOSE_FILE" config --images | awk 'NF')

  if [[ "${#images[@]}" -eq 0 ]]; then
    warn "No images found from compose config; skipping image export."
    return
  fi

  warn "Exporting ${#images[@]} image(s) for offline restore..."
  docker save -o "$images_file" "${images[@]}"
  log "Saved images archive: ${images_file}"
}

create_backup() {
  local workdir archive final_archive

  mkdir -p "$BACKUP_DIR"
  workdir="$(mktemp -d)"
  archive="${workdir}/${BACKUP_NAME}"
  mkdir -p "${archive}/nomad"

  warn "Copying Nomad files..."
  cp -a "$COMPOSE_FILE" "${archive}/nomad/compose.yml"

  for helper in start_nomad.sh stop_nomad.sh update_nomad.sh backup_nomad.sh restore_nomad.sh verify_nomad_recovery.sh; do
    if [[ -f "${NOMAD_DIR}/${helper}" ]]; then
      cp -a "${NOMAD_DIR}/${helper}" "${archive}/nomad/${helper}"
    fi
  done

  for dir in storage mysql redis sidecar-updater; do
    if [[ -d "${NOMAD_DIR}/${dir}" ]]; then
      cp -a "${NOMAD_DIR}/${dir}" "${archive}/nomad/${dir}"
    fi
  done

  cat > "${archive}/BACKUP_INFO.txt" <<EOF
Project: Project N.O.M.A.D.
Created: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
Source Dir: ${NOMAD_DIR}
Host: $(hostname)
Include Images: ${INCLUDE_IMAGES}
EOF

  if [[ "$INCLUDE_IMAGES" == true ]]; then
    export_images "$archive"
  fi

  (cd "$archive" && find . -type f ! -name 'SHA256SUMS' -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)

  final_archive="${BACKUP_DIR}/${BACKUP_NAME}.tar.gz"
  warn "Creating compressed backup archive..."
  tar -C "$workdir" -czf "$final_archive" "$BACKUP_NAME"
  rm -rf "$workdir"

  log "Backup complete: ${WHITE}${final_archive}${RESET}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)
      shift
      [[ $# -gt 0 ]] || fail "--output-dir requires a value"
      BACKUP_DIR="$1"
      ;;
    --name)
      shift
      [[ $# -gt 0 ]] || fail "--name requires a value"
      BACKUP_NAME="$1"
      ;;
    --skip-stop)
      SKIP_STOP=true
      ;;
    --skip-restart)
      SKIP_RESTART=true
      ;;
    --include-images)
      INCLUDE_IMAGES=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown option: $1"
      ;;
  esac
  shift
done

require_cmd docker
require_cmd tar
require_cmd sha256sum
ensure_nomad_exists

WAS_RUNNING=false
if project_running; then
  WAS_RUNNING=true
fi

if [[ "$SKIP_STOP" == false && "$WAS_RUNNING" == true ]]; then
  stop_project
elif [[ "$SKIP_STOP" == true ]]; then
  warn "Skipping container stop by request. Backup consistency is best-effort."
fi

create_backup

if [[ "$WAS_RUNNING" == true && "$SKIP_RESTART" == false ]]; then
  start_project
elif [[ "$WAS_RUNNING" == true && "$SKIP_RESTART" == true ]]; then
  warn "Containers were running before backup but restart was skipped by request."
fi
