#!/bin/bash
set -e

# Script to set hostname on Ubuntu 24.04
# Usage: ./01_init.sh <new-hostname> [--force]

# ---------------------------------------------------------
# Begin Main Script
# ---------------------------------------------------------

# Validate required environment variables
: "${PLATFORM_TENANT_NAME:?PLATFORM_TENANT_NAME is required}"

# Logging setup
LOG_DIR="/var/log/${PLATFORM_TENANT_NAME}"
LOG_FILE="${LOG_DIR}/hostname-setup.log"

# Function to log messages
log() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $1" | tee -a "$LOG_FILE"
}

# Function to log errors
log_error() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] ERROR: $1" | tee -a "$LOG_FILE" >&2
}

# Check if script is run as root
if [[ $EUID -ne 0 ]]; then
   echo "Error: This script must be run as root or with sudo" 
   exit 1
fi

# Create log directory if it doesn't exist
mkdir -p "$LOG_DIR"
chmod 755 "$LOG_DIR"

log "=========================================="
log "Hostname setup script started"
log "=========================================="

# Parse arguments
FORCE=false
NEW_HOSTNAME=""

for arg in "$@"; do
    case $arg in
        --force)
            FORCE=true
            shift
            ;;
        *)
            if [ -z "$NEW_HOSTNAME" ]; then
                NEW_HOSTNAME="$arg"
            fi
            ;;
    esac
done

# Check if hostname argument is provided
if [ -z "$NEW_HOSTNAME" ]; then
    log_error "No hostname provided"
    echo "Usage: $0 <new-hostname> [--force]"
    echo "  --force    Force hostname change even if already set"
    exit 1
fi

# Validate hostname format (RFC 1123)
if ! [[ "$NEW_HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?$ ]]; then
    log_error "Invalid hostname format: $NEW_HOSTNAME"
    echo "Hostname must:"
    echo "  - Start and end with alphanumeric characters"
    echo "  - Contain only alphanumeric characters and hyphens"
    echo "  - Be 1-63 characters long"
    exit 1
fi

log "Requested hostname: $NEW_HOSTNAME"

# Check current hostname for idempotency
CURRENT_HOSTNAME=$(hostname)
log "Current hostname: $CURRENT_HOSTNAME"

if [ "$CURRENT_HOSTNAME" == "$NEW_HOSTNAME" ] && [ "$FORCE" != true ]; then
    log "Hostname is already set to $NEW_HOSTNAME. No changes needed."
    log "Use --force flag to override this check."
    echo "Hostname is already set to $NEW_HOSTNAME"
    echo "No changes were made. Use --force to override."
    exit 0
fi

if [ "$CURRENT_HOSTNAME" == "$NEW_HOSTNAME" ] && [ "$FORCE" == true ]; then
    log "Hostname already set to $NEW_HOSTNAME but --force flag provided. Proceeding anyway."
fi

log "Proceeding with hostname change from '$CURRENT_HOSTNAME' to '$NEW_HOSTNAME'"

# Set the hostname using hostnamectl (systemd method)
log "Setting hostname using hostnamectl..."
if hostnamectl set-hostname "$NEW_HOSTNAME"; then
    log "Successfully set hostname using hostnamectl"
else
    log_error "Failed to set hostname using hostnamectl"
    exit 1
fi

# Update /etc/hostname
log "Updating /etc/hostname..."
if echo "$NEW_HOSTNAME" > /etc/hostname; then
    log "Successfully updated /etc/hostname"
else
    log_error "Failed to update /etc/hostname"
    exit 1
fi

# Update /etc/hosts to ensure proper hostname resolution
# Preserve existing entries and update/add the hostname entry
log "Updating /etc/hosts..."
if grep -q "127.0.1.1" /etc/hosts; then
    # Update existing 127.0.1.1 entry
    if sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$NEW_HOSTNAME/" /etc/hosts; then
        log "Updated existing 127.0.1.1 entry in /etc/hosts"
    else
        log_error "Failed to update /etc/hosts"
        exit 1
    fi
else
    # Add new entry after localhost
    if sed -i "/^127\.0\.0\.1/a 127.0.1.1\t$NEW_HOSTNAME" /etc/hosts; then
        log "Added new 127.0.1.1 entry to /etc/hosts"
    else
        log_error "Failed to add entry to /etc/hosts"
        exit 1
    fi
fi

# Verify the change
FINAL_HOSTNAME=$(hostname)
FINAL_FQDN=$(hostname -f 2>/dev/null || echo 'Not set')

log "Hostname change completed successfully"
log "Final hostname: $FINAL_HOSTNAME"
log "Final FQDN: $FINAL_FQDN"
log "=========================================="

echo ""
echo "✓ Hostname has been set successfully!"
echo "Current hostname: $FINAL_HOSTNAME"
echo "FQDN: $FINAL_FQDN"
echo ""
echo "Note: The hostname change is effective immediately."
echo "You may need to restart your shell or logout/login to see the updated prompt."
echo ""
echo "Log file: $LOG_FILE"