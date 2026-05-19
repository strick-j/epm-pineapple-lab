#!/bin/bash
set -eo pipefail

# Script to install and activate the CyberArk EPM agent on RHEL 9.
#   1. Validates required environment variables.
#   2. Downloads the EPM installer tarball from S3.
#   3. Extracts the tarball to find the RPM and config file.
#   4. Installs the RPM via dnf.
#   5. Activates the agent against an EPM set using EPM_INSTALLATION_KEY
#      and the CyberArkEPMAgentSetupLinux.config from the kit.
#   6. Verifies the agent service (cyberark-epm) is active.
#
# Usage: ./03_install_epm.sh
#
# Required env vars (typically exported by user_data):
#   PLATFORM_TENANT_NAME    - Used for log directory path (consistent with
#                             scripts/01_init.sh and scripts/02_configure_target.sh)
#   EPM_INSTALLER_S3_URI    - Full s3:// URI of the EPM installer tarball as
#                             downloaded from the EPM Download Center. The
#                             tarball must contain CyberArkEPMAgentSetupLinux.config
#                             and epm-rhel9.x86_64.rpm (covers RHEL 9/10,
#                             Oracle Linux 9, Amazon Linux 2023, Rocky Linux 9).
#                             A bare .rpm is also accepted (activation will run
#                             without -c).
#   EPM_INSTALLATION_KEY    - Installation key tied to the target EPM set
#                             (sensitive — never logged, never echoed)
#
# Reference: CyberArk EPM docs, "Install/upgrade EPM agents on Linux endpoints"
#   Activate syntax:
#     /opt/cyberark/epm/bin/epmcli --activate [-c <path_to_config_file>]
#         [-k <installation_key> | -f <path_to_installation_key_file>]
#         [--proxy-host <proxy_host> --proxy-port <proxy_port>]
#   Status check: /opt/cyberark/epm/bin/epmcli --status

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
for cmd in aws dnf rpm tar systemctl; do
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
WORK_DIR=$(mktemp -d -t epm-installer.XXXXXX)
EXTRACT_DIR="${WORK_DIR}/extracted"
mkdir -p "$EXTRACT_DIR"

INSTALLER_BASENAME=$(basename "${EPM_INSTALLER_S3_URI}")
if [[ -z "$INSTALLER_BASENAME" || "$INSTALLER_BASENAME" == "/" ]]; then
  log_error "Cannot derive a local filename from ${EPM_INSTALLER_S3_URI}"
  exit 1
fi
INSTALLER_PATH="${WORK_DIR}/${INSTALLER_BASENAME}"

# Parse the s3:// URI so we can pre-flight with head-object and produce a
# single clean error message instead of letting `aws s3 cp` dump a raw AWS
# stack trace to stderr above our own log message.
if [[ "$EPM_INSTALLER_S3_URI" != s3://* ]]; then
  log_error "Invalid S3 URI: ${EPM_INSTALLER_S3_URI} (expected s3://<bucket>/<key>)"
  exit 1
fi
S3_REMAINDER=${EPM_INSTALLER_S3_URI#s3://}
S3_BUCKET=${S3_REMAINDER%%/*}
S3_KEY=${S3_REMAINDER#*/}
if [[ -z "$S3_BUCKET" || -z "$S3_KEY" || "$S3_KEY" == "$S3_REMAINDER" ]]; then
  log_error "Invalid S3 URI: ${EPM_INSTALLER_S3_URI} (could not split into bucket and key)"
  exit 1
fi

# Pre-flight: does the object exist and can we read it?
log "Checking for installer at ${EPM_INSTALLER_S3_URI}"
HEAD_STDERR=$(mktemp -t epm-head.XXXXXX)
if ! aws s3api head-object --bucket "$S3_BUCKET" --key "$S3_KEY" >/dev/null 2>"$HEAD_STDERR"; then
  if grep -qE '\(404\)|Not Found' "$HEAD_STDERR"; then
    log_error "EPM installer not found at ${EPM_INSTALLER_S3_URI}; aborting"
  elif grep -qE '\(403\)|Forbidden' "$HEAD_STDERR"; then
    log_error "Access denied reading ${EPM_INSTALLER_S3_URI}; check the instance IAM role"
  else
    log_error "S3 head-object failed for ${EPM_INSTALLER_S3_URI}: $(tr '\n' ' ' < "$HEAD_STDERR")"
  fi
  rm -f "$HEAD_STDERR"
  exit 1
fi
rm -f "$HEAD_STDERR"

log "Downloading installer to ${INSTALLER_PATH}"
CP_STDERR=$(mktemp -t epm-cp.XXXXXX)
if ! aws s3 cp "${EPM_INSTALLER_S3_URI}" "${INSTALLER_PATH}" >/dev/null 2>"$CP_STDERR"; then
  log_error "S3 download failed for ${EPM_INSTALLER_S3_URI}: $(tr '\n' ' ' < "$CP_STDERR")"
  rm -f "$CP_STDERR"
  exit 1
fi
rm -f "$CP_STDERR"

if [[ ! -s "$INSTALLER_PATH" ]]; then
  log_error "Downloaded installer is empty: ${INSTALLER_PATH}"
  exit 1
fi
log "Downloaded $(stat -c %s "$INSTALLER_PATH") bytes"

# ---------------------------------------------------------
# 2. Extract (if tarball) or stage (if bare RPM)
# ---------------------------------------------------------
case "$INSTALLER_BASENAME" in
  *.tar.gz|*.tgz|*.tar|*.tar.bz2|*.tar.xz)
    log "Extracting tarball"
    if ! tar -xf "$INSTALLER_PATH" -C "$EXTRACT_DIR"; then
      log_error "Failed to extract ${INSTALLER_PATH}"
      exit 1
    fi
    ;;
  *.rpm)
    log "Bare RPM provided; skipping extract"
    cp "$INSTALLER_PATH" "$EXTRACT_DIR/"
    ;;
  *)
    log_error "Unsupported installer format: ${INSTALLER_BASENAME} (expected .tar.gz/.tgz/.tar/.tar.bz2/.tar.xz/.rpm)"
    exit 1
    ;;
esac

# Locate the RPM and config file inside the extracted payload.
# CyberArk's EPM kit ships exactly one .rpm; their docs note the same RPM covers
# RHEL 9/10, Oracle Linux 9, Amazon Linux 2023, and Rocky Linux 9. Filenames
# have varied (case of "RHEL", presence of version suffixes), so just find any
# .rpm in the kit rather than trying to match a specific naming convention.
mapfile -t RPM_CANDIDATES < <(find "$EXTRACT_DIR" -maxdepth 4 -type f -iname '*.rpm')
if [[ ${#RPM_CANDIDATES[@]} -eq 0 ]]; then
  log_error "No .rpm file found in installer payload at ${EXTRACT_DIR}"
  log_error "Extracted contents (for debugging):"
  find "$EXTRACT_DIR" -maxdepth 4 -mindepth 1 2>&1 | tee -a "$LOG_FILE" >&2 || true
  exit 1
fi
if [[ ${#RPM_CANDIDATES[@]} -gt 1 ]]; then
  log_error "Expected exactly one .rpm in installer payload, found ${#RPM_CANDIDATES[@]}:"
  printf '  %s\n' "${RPM_CANDIDATES[@]}" | tee -a "$LOG_FILE" >&2
  exit 1
fi
RPM_FILE="${RPM_CANDIDATES[0]}"
log "Found RPM: ${RPM_FILE}"

CONFIG_FILE=$(find "$EXTRACT_DIR" -maxdepth 4 -type f -iname 'CyberArkEPMAgentSetupLinux.config' | head -n1)
if [[ -n "$CONFIG_FILE" ]]; then
  log "Found config: ${CONFIG_FILE}"
else
  log "No CyberArkEPMAgentSetupLinux.config found; activation will run without -c"
fi

# ---------------------------------------------------------
# 3. Install the RPM
# ---------------------------------------------------------
log "Installing EPM agent RPM"
if ! dnf install -y "${RPM_FILE}"; then
  log_error "dnf install failed for ${RPM_FILE}"
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
# 4. Activate against the EPM set
# ---------------------------------------------------------
# Write the installation key to a chmod-600 temp file so it never appears in
# the process list (vs. passing -k <key> directly, which is visible to `ps`).
# Docs note: "-f is recommended ... the most secure option and enables
# deployment scalability."
KEY_FILE=$(mktemp -t epm-key.XXXXXX)
chmod 600 "$KEY_FILE"
trap 'shred_and_rm "$KEY_FILE"; rm -rf "$WORK_DIR"' EXIT

printf '%s' "${EPM_INSTALLATION_KEY}" > "$KEY_FILE"

ACTIVATE_ARGS=(--activate -f "$KEY_FILE")
if [[ -n "$CONFIG_FILE" ]]; then
  ACTIVATE_ARGS=(--activate -c "$CONFIG_FILE" -f "$KEY_FILE")
fi

log "Activating EPM agent"
if ! "$EPMCLI" "${ACTIVATE_ARGS[@]}" >>"$LOG_FILE" 2>&1; then
  log_error "epmcli --activate failed"
  exit 1
fi

# Drop the key file as soon as activation finishes (the EXIT trap also covers this).
shred_and_rm "$KEY_FILE"

# ---------------------------------------------------------
# 5. Verify
# ---------------------------------------------------------
# After --activate, the cyberark-epm service starts asynchronously and
# epmcli --status races ahead of it, returning an "unexpected" result.
# Poll systemctl is-active before the status check, then settle briefly
# so the daemon finishes initializing before we ask it anything.
log "Waiting for cyberark-epm.service to become active (timeout 60s)"
SERVICE_UP=false
for attempt in $(seq 1 30); do
  if systemctl is-active --quiet cyberark-epm; then
    SERVICE_UP=true
    log "cyberark-epm.service is active (after ~$((attempt * 2))s)"
    break
  fi
  sleep 2
done

if ! $SERVICE_UP; then
  log_error "cyberark-epm service did not become active within 60s"
  systemctl status cyberark-epm --no-pager >>"$LOG_FILE" 2>&1 || true
  exit 1
fi

# Brief settle window — service is "active" but the daemon may still be
# initializing internal state that epmcli --status queries.
sleep 5

log "Running epmcli --status"
if ! "$EPMCLI" --status >>"$LOG_FILE" 2>&1; then
  log_error "epmcli --status reported a non-zero exit"
  exit 1
fi

# ---------------------------------------------------------
# 6. Done
# ---------------------------------------------------------
touch "$FLAG"
log "=========================================="
log "EPM agent install completed"
log "=========================================="
