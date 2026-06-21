#!/bin/bash

# Project N.O.M.A.D. Restore Script
# Restores a backup produced by backup_nomad.sh

set -euo pipefail

NOMAD_DIR="/opt/project-nomad"
BACKUP_ARCHIVE=""
TEMP_DIR=""
SKIP_START=false
LOAD_IMAGES=true

RESET='\033[0m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
GREEN='\033[1;32m'
WHITE='\033[39m'

usage() {
  cat <<EOF
Usage: $(basename "$0") --backup <path/to/backup.tar.gz> [options]

Options:
  --target-dir <path>   Nomad install directory to restore to (default: /opt/project-nomad)
  --skip-start          Do not start containers after restore
  --skip-image-load     Do not load images.tar even if present in backup
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
  [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
  exit 1
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || fail "Missing required command: ${cmd}"
}

stop_existing_stack() {
  if [[ -f "${NOMAD_DIR}/compose.yml" ]]; then
    warn "Stopping existing Nomad stack..."
    docker compose -p project-nomad -f "${NOMAD_DIR}/compose.yml" down || true
  else
    warn "No existing compose file found at ${NOMAD_DIR}; skipping stack shutdown."
  fi
}

verify_backup_checksums() {
  local backup_root="$1"
  if [[ ! -f "${backup_root}/SHA256SUMS" ]]; then
    warn "SHA256SUMS not present in backup. Skipping checksum verification."
    return
  fi

  warn "Verifying backup checksums..."
  (cd "$backup_root" && sha256sum -c SHA256SUMS)
  log "Checksum verification passed."
}

restore_files() {
  local backup_root="$1"
  local nomad_payload="${backup_root}/nomad"

  [[ -d "$nomad_payload" ]] || fail "Backup payload missing 'nomad/' directory."

  mkdir -p "$NOMAD_DIR"

  if [[ -f "${NOMAD_DIR}/compose.yml" ]]; then
    local pre_restore="${NOMAD_DIR}.pre-restore.$(date +%Y%m%d_%H%M%S)"
    warn "Creating safety copy of current installation at ${pre_restore}"
    cp -a "$NOMAD_DIR" "$pre_restore"
  fi

  warn "Restoring files into ${NOMAD_DIR}..."
  rsync -a --delete "${nomad_payload}/" "${NOMAD_DIR}/"

  if [[ "$LOAD_IMAGES" == true && -f "${backup_root}/images.tar" ]]; then
    warn "Loading backed up Docker images (this may take a while)..."
    docker load -i "${backup_root}/images.tar"
    log "Image load complete."
  fi
}

start_stack() {
  [[ -f "${NOMAD_DIR}/compose.yml" ]] || fail "Restore complete but compose.yml is missing."

  warn "Starting restored Nomad stack..."
  docker compose -p project-nomad -f "${NOMAD_DIR}/compose.yml" up -d

  if command -v curl >/dev/null 2>&1; then
    warn "Checking API health endpoint..."
    for _ in {1..20}; do
      if curl -fsS http://localhost:8080/api/health >/dev/null 2>&1; then
        log "Health check passed at http://localhost:8080/api/health"
        return
      fi
      sleep 3
    done
    warn "Health check did not pass yet. Verify with: curl -f http://localhost:8080/api/health"
  else
    warn "curl not found; skipping automated health check."
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backup)
      shift
      [[ $# -gt 0 ]] || fail "--backup requires a value"
      BACKUP_ARCHIVE="$1"
      ;;
    --target-dir)
      shift
      [[ $# -gt 0 ]] || fail "--target-dir requires a value"
      NOMAD_DIR="$1"
      ;;
    --skip-start)
      SKIP_START=true
      ;;
    --skip-image-load)
      LOAD_IMAGES=false
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

[[ -n "$BACKUP_ARCHIVE" ]] || {
  usage
  fail "--backup is required"
}

[[ -f "$BACKUP_ARCHIVE" ]] || fail "Backup archive not found: ${BACKUP_ARCHIVE}"

require_cmd docker
require_cmd tar
require_cmd rsync
require_cmd sha256sum

stop_existing_stack

TEMP_DIR="$(mktemp -d)"
warn "Extracting backup archive..."
tar -C "$TEMP_DIR" -xzf "$BACKUP_ARCHIVE"

BACKUP_ROOT="$(find "$TEMP_DIR" -mindepth 1 -maxdepth 1 -type d | head -n1)"
[[ -n "$BACKUP_ROOT" ]] || fail "Backup archive did not contain a valid root directory."

verify_backup_checksums "$BACKUP_ROOT"
restore_files "$BACKUP_ROOT"

if [[ "$SKIP_START" == false ]]; then
  start_stack
else
  warn "Restore completed with --skip-start. Start manually with: docker compose -p project-nomad -f ${NOMAD_DIR}/compose.yml up -d"
fi

rm -rf "$TEMP_DIR"
log "Restore completed successfully."
