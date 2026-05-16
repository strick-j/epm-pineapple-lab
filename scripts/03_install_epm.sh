#!/bin/bash
set -eo pipefail

# Script to install and activate the CyberArk EPM agent on RHEL 9.
#   1. Validates required environment variables.
#   2. Downloads the EPM installer RPM from S3.
#   3. Installs the RPM via dnf.
#   4. Activates the agent against an EPM set using EPM_INSTALLATION_KEY.
#   5. Verifies the agent is installed and the service is active.
#
# Usage: ./03_install_epm.sh
#
# Required env vars (typically exported by user_data):
#   PLATFORM_TENANT_NAME    - Used for log directory path (consistent with
#                             scripts/01_init.sh and scripts/02_configure_target.sh)
#   EPM_INSTALLER_S3_URI    - Full s3:// URI of the EPM installer RPM
#                             (e.g. s3://my-bucket/installers/epm-rhel9.x86_64.rpm)
#   EPM_INSTALLATION_KEY    - EPM installation key tied to the target set
#                             (sensitive — never logged, never echoed)
#
# Reference (docs.cyberark.com EPM Linux install):
#   - Install path: /opt/cyberark/epm/bin/epmcli
#   - Activate:     epmcli --activate [-c <config>] [-k <key> | -f <key_file>]

# Function to log messages
log() {
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$timestamp] $1" | tee -a "$LOG_FILE"
}

# Function to log errors
log_error() {
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$timestamp] ERROR: $1" | tee -a "$LOG_FILE" >&2
}

# Securely shred a file (best-effort) and remove it.
shred_and_rm() {
  local f="$1"
  if [[ -f "$f" ]]; then
    if command -v shred >/dev/null 2>&1; then
      shred -u -z -n 3 "$f" 2>/dev/null || rm -f "$f"
    else
      rm -f "$f"
    fi
  fi
}

# ---------------------------------------------------------
# Begin Main Script
# ---------------------------------------------------------

# Validate required environment variables (fail fast with a clear message).
: "${PLATFORM_TENANT_NAME:?PLATFORM_TENANT_NAME is required}"
: "${EPM_INSTALLER_S3_URI:?EPM_INSTALLER_S3_URI is required}"
: "${EPM_INSTALLATION_KEY:?EPM_INSTALLATION_KEY is required}"

# Logging setup
LOG_DIR="/var/log/${PLATFORM_TENANT_NAME}"
LOG_FILE="${LOG_DIR}/epm_install.log"
FLAG="${LOG_DIR}/epm_install_done"

# Create log directory if it doesn't exist
mkdir -p "$LOG_DIR"
chmod 755 "$LOG_DIR"

# Check if script is run as root
if [[ $EUID -ne 0 ]]; then
  log_error "This script must be run as root or with sudo"
  exit 1
fi

# Check for required tools
for cmd in aws dnf rpm; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log_error "${cmd} not installed"
    exit 1
  fi
done

# Idempotency guard
if [[ -f "$FLAG" ]]; then
  log "EPM agent install already completed; skipping."
  exit 0
fi

log "=========================================="
log "EPM agent install starting"
log "Installer URI:          ${EPM_INSTALLER_S3_URI}"
log "Installation key:       <redacted, ${#EPM_INSTALLATION_KEY} chars>"
log "=========================================="

# ---------------------------------------------------------
# 1. Download installer from S3
# ---------------------------------------------------------
INSTALLER_DIR=$(mktemp -d -t epm-installer.XXXXXX)
# Use the basename of the S3 key as the local filename; fall back to a generic name.
INSTALLER_BASENAME=$(basename "${EPM_INSTALLER_S3_URI}")
if [[ -z "$INSTALLER_BASENAME" || "$INSTALLER_BASENAME" == "/" ]]; then
  INSTALLER_BASENAME="epm-installer.rpm"
fi
INSTALLER_PATH="${INSTALLER_DIR}/${INSTALLER_BASENAME}"

log "Downloading installer to ${INSTALLER_PATH}"
if ! aws s3 cp "${EPM_INSTALLER_S3_URI}" "${INSTALLER_PATH}"; then
  log_error "Failed to download installer from ${EPM_INSTALLER_S3_URI}"
  exit 1
fi

if [[ ! -s "$INSTALLER_PATH" ]]; then
  log_error "Downloaded installer is empty: ${INSTALLER_PATH}"
  exit 1
fi
log "Downloaded $(stat -c %s "$INSTALLER_PATH") bytes"

# ---------------------------------------------------------
# 2. Install the RPM
# ---------------------------------------------------------
log "Installing EPM agent RPM"
if ! dnf install -y "${INSTALLER_PATH}"; then
  log_error "dnf install failed for ${INSTALLER_PATH}"
  exit 1
fi

# Verify the CLI binary landed where expected.
EPMCLI="/opt/cyberark/epm/bin/epmcli"
if [[ ! -x "$EPMCLI" ]]; then
  log_error "Expected ${EPMCLI} after install but it is missing or not executable"
  exit 1
fi
log "epmcli installed at ${EPMCLI}"

# ---------------------------------------------------------
# 3. Activate against the EPM set
# ---------------------------------------------------------
# Write the installation key to a chmod-600 temp file so it never appears in
# the process list (vs. passing -k <key> directly, which is visible to `ps`).
KEY_FILE=$(mktemp -t epm-key.XXXXXX)
chmod 600 "$KEY_FILE"
trap 'shred_and_rm "$KEY_FILE"; rm -rf "$INSTALLER_DIR"' EXIT

printf '%s' "${EPM_INSTALLATION_KEY}" > "$KEY_FILE"

log "Activating EPM agent"
if ! "$EPMCLI" --activate -f "$KEY_FILE" >>"$LOG_FILE" 2>&1; then
  log_error "epmcli --activate failed"
  exit 1
fi

# Drop the key file as soon as activation finishes (the EXIT trap also covers this).
shred_and_rm "$KEY_FILE"

# ---------------------------------------------------------
# 4. Verify
# ---------------------------------------------------------
# The EPM agent registers a systemd service after install. Service name has
# historically been one of: epm, cyberark-epm, vfagent. Check all and warn if
# none are active rather than failing — the activate command above is the
# authoritative success signal.
log "Verifying EPM agent service"
ACTIVE_SVC=""
for svc in epm cyberark-epm vfagent; do
  if systemctl is-active --quiet "$svc" 2>/dev/null; then
    ACTIVE_SVC="$svc"
    break
  fi
done

if [[ -n "$ACTIVE_SVC" ]]; then
  log "EPM service active: ${ACTIVE_SVC}"
else
  log "No known EPM service name reported active (epm/cyberark-epm/vfagent). The agent may still be initializing; check 'systemctl list-units | grep -i epm'."
fi

# ---------------------------------------------------------
# 5. Done
# ---------------------------------------------------------
touch "$FLAG"
log "=========================================="
log "EPM agent install completed"
log "=========================================="
