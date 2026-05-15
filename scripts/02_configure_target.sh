#!/bin/bash

# Script to configure target for SIA connections.
#   1. Obtains AWS credentials from environment variables
#   2. Authenticates against Conjur wtih AWS credentials
#   3. Uses secrets returned from Conjur to obtain Identity Platform Token
#   4. Uses Identity Platform Token to retrieve SIA bash_cmd
#   5. Configures the target for SIA connections
#
# Usage: ./02_configure_target.sh [--force]

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

# Helper functions for Signing Request
sha256Hash() {
  printf "$1" | openssl dgst -sha256 -binary -hex | sed 's/^.* //'
}

to_hex() {
  printf "$1" | od -A n -t x1 | tr -d [:space:]
}

hmac_sha256() {
  printf "$2" | \
    openssl dgst -binary -hex -sha256 -mac HMAC -macopt hexkey:"$1" | \
    sed 's/^.* //'
}

# Function to URL encode string
urlencode() {
  local string="$1"
  local strlen=${#string}
  local encoded=""
  local pos c o

  for (( pos=0 ; pos<strlen ; pos++ )); do
    c=${string:$pos:1}
    case "$c" in
      [-_.~a-zA-Z0-9] ) o="${c}" ;;
      * ) printf -v o '%%%02x' "'$c"
    esac
    encoded+="${o}"
  done
  echo "${encoded}"
}

# Function to decode base64url
base64url_decode() {
  local input="$1"
  # Replace base64url characters with base64 characters
  local base64=$(echo "$input" | tr '_-' '/+')

  # Add padding if needed
  local padding=$((4 - ${#base64} % 4))
  if [[ $padding -lt 4 ]]; then
    base64="${base64}$(printf '=%.0s' $(seq 1 $padding))"
  fi

  # Decode
  echo "$base64" | base64 -d 2>/dev/null
}

# Function to validate AWS Access Key ID format
validate_access_key() {
  local access_key="$1"

  # AWS Access Key ID format rules:
  # - Exactly 20 characters long
  # - Starts with AKIA (standard) or ASIA (temporary/STS)
  # - Contains only uppercase alphanumeric characters

  if [[ -z "$access_key" ]]; then
    log_error "Access Key is empty"
    exit 1
  fi

  if [[ ${#access_key} -ne 20 ]]; then
    log_error "Access Key must be exactly 20 chars (found ${#access_key})"
    exit 1
  fi
s
  if [[ ! "$access_key" =~ ^(AKIA|ASIA)[A-Z0-9]{16}$ ]]; then
    log_error "Access Key format is invalid"
    log_error "  - Must start with AKIA (standard) or ASIA (temporary)"
    log_error "  - Must contain only uppercase letters and numbers"
    exit 1
  fi

  # Check prefix for key type
  if [[ "$access_key" =~ ^AKIA ]]; then
    log "✓ Access Key is valid (Standard IAM user key)"
  elif [[ "$access_key" =~ ^ASIA ]]; then
    log "✓ Access Key is valid (Temporary/STS key)"
  fi

  return 0
}

# Function to validate AWS Secret Access Key format
validate_secret_key() {
  local secret_key="$1"

  # AWS Secret Access Key format rules:
  # - Exactly 40 characters long
  # - Contains alphanumeric characters plus + / =
  # - Base64-like format

  if [[ -z "$secret_key" ]]; then
    log_error "Secret Key is empty"
    exit 1
  fi

  if [[ ${#secret_key} -ne 40 ]]; then
    log_error "Secret Key must be exactly 40 characters (found ${#secret_key})"
    exit 1
  fi

  if [[ ! "$secret_key" =~ ^[A-Za-z0-9/+]{40}$ ]]; then
    log_error "Secret Key format is invalid"
    log_error "  - Must be exactly 40 characters"
    log_error "  - Must contain only letters, numbers, /, and +"
    exit 1
  fi

  log "✓ Secret Key format is valid"
  return 0
}

# Function to validate AWS Session Token format (for temporary credentials)
validate_session_token() {
  local token="$1"

  # Session Token rules:
  # - Variable length (typically 356+ characters)
  # - Base64 encoded string
  # - Only present for temporary credentials (STS)

  if [[ -z "$token" ]]; then
    log "⚠ Session Token is empty (not required for standard credentials)"
    exit 0
  fi

  # Token should be at least 100 characters
  if [[ ${#token} -lt 100 ]]; then
    log "Session Token seems too short (found ${#token} characters)"
    exit 1
  fi

  # Check if it's base64-like format
  if [[ ! "$token" =~ ^[A-Za-z0-9/+=]+$ ]]; then
    log_error "Session Token contains invalid characters"
    exit 1
  fi

  log "✓ Session Token format is valid (${#token} characters)"
  return 0
}

# Function to handle HTTP responses
http_response(){
  local HTTP_CODE="$1"
  local RESPONSE="$2"

  # Check HTTP status code
  if [[ "$HTTP_CODE" -eq 200 || "$HTTP_CODE" -eq 201 ]]; then
    log "✓ API call successful"
    return 0
  elif [[ "$HTTP_CODE" -eq 401 ]]; then
    log_error "Authentication failed (401 Unauthorized)"
    log_error "The bearer token may be invalid or expired"
    exit 1
  elif [[ "$HTTP_CODE" -eq 403 ]]; then
    log_error "Access denied (403 Forbidden)"
    log_error "You don't have permission to access this resource"
    exit 1
  elif [[ "$HTTP_CODE" -eq 404 ]]; then
    log_error "Resource not found (404 Not Found)"
    log_error "The specified resource does not exist"
    exit 1
  else
    log_error "Request failed with HTTP code: ${HTTP_CODE}"
    log_error "Response: ${RESPONSE}"
    exit 1
  fi
}

# Function to validate installation via bash_cmd completed successfully
check_installation_completed() {
    local FILE="$1"
    
    # Check if file exists
    if [[ ! -f "$FILE" ]]; then
        log_error "File '$file' not found"
        return 1
    fi
    
    # Check if file is readable
    if [[ ! -r "$FILE" ]]; then
        log_error "File '$FILE' is not readable"
        return 1
    fi
    
    # Read the last line of the file
    local last_line=$(tail -n 1 "$FILE")
    
    # Check if last line contains "Installation Completed"
    if [[ "$last_line" == "Installation Completed" ]]; then
        log "✓ Installation completed successfully"
        return 0
    else
        log_error "✗ Installation not completed"
        log_error "Last line: $last_line"
        return 1
    fi
}

# ---------------------------------------------------------
# Begin Main Script
# ---------------------------------------------------------

# Validate required environment variables
: "${AWS_ROLE_NAME:?AWS_ROLE_NAME is required}"
: "${SERVICE_ID:?SERVICE_ID is required}"
: "${HOST_ID:?HOST_ID is required}"
: "${USERNAME_VARIABLE:?USERNAME_VARIABLE is required}"
: "${PASSWORD_VARIABLE:?PASSWORD_VARIABLE is required}"
: "${IDENTITY_TENANT_ID:?IDENTITY_TENANT_ID is required}"
: "${PLATFORM_TENANT_NAME:?PLATFORM_TENANT_NAME is required}"
: "${WORKSPACE_ID:?WORKSPACE_ID is required}"
: "${WORKSPACE_TYPE:?WORKSPACE_TYPE is required}"

# Logging setup
LOG_DIR="/var/log/${PLATFORM_TENANT_NAME}"
LOG_FILE="${LOG_DIR}/configure_target.log"
FLAG="${LOG_DIR}/sia_configure_done"

# Create log directory if it doesn't exist
mkdir -p "$LOG_DIR"
chmod 755 "$LOG_DIR"

# Check if script is run as root
if [[ $EUID -ne 0 ]]; then
  log_error "This script must be run as root or with sudo"
  exit 1
fi

# Check for required tools
for cmd in aws jq curl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log_error "${cmd} not installed"
    exit 1
  fi
done

# Idempotency guard
if [[ -f "$FLAG" ]]; then
  log "Registration already completed; skipping."
  exit 0
fi

# ---------------------------------------------------------
# Retrieve AWS Credentials for authentication to Conjur
# ---------------------------------------------------------
log "=========================================="
log "Obtaining AWS Credentials"
log "=========================================="
log "Retrieving host role from IMDS..."

IMDS_TOKEN_URL="http://169.254.169.254/latest/api/token"
IMDS_URL="http://169.254.169.254/latest/"
IMDS_URL+="meta-data/iam/security-credentials/${AWS_ROLE_NAME}"
# Retrieve IAM information from IMDS to be used in STS signing request
log "Requesting AWS credentials from IMDS URL: ${IMDS_TOKEN_URL}"
TOKEN=$(curl -sS -X PUT "${IMDS_TOKEN_URL}" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
log "Requesting AWS credentials from IMDS URL: ${IMDS_URL}"
METADATACREDS=$(curl -sS -H "X-aws-ec2-metadata-token: ${TOKEN}" \
  "${IMDS_URL}")
log "Parsing credentials from IMDS..."
ACCESS_KEY=$(jq -r '.AccessKeyId' <<<${METADATACREDS})
SECRET_KEY=$(jq -r '.SecretAccessKey' <<<${METADATACREDS})
SESSION_TOKEN=$(jq -r '.Token' <<<${METADATACREDS})
log "Validating AWS Credentials"

# Verifiy Access Key, Secret Key, and Token are valid
log "Validating AWS Access Key..."
validate_access_key "$ACCESS_KEY"
log "Validating AWS Secret Key..."
validate_secret_key "$SECRET_KEY"
log "Validating AWS Session Token..."
validate_session_token "$SESSION_TOKEN"

log "=========================================="
log "✓ AWS Credentials validation PASSED"
log "=========================================="

fulldate=$(date -u +"%Y%m%dT%H%M00Z")
shortdate=$(date -u +"%Y%m%d")

log "Creating Canonical AWS Request"
REGION="us-east-1"
SERVICE="sts"
HOST="${SERVICE}.amazonaws.com"

# Empty payload for IAM request
METHOD="GET"
CANONICAL_URI="/"
CANONICAL_QUERY="$(urlencode "Action")=$(urlencode "GetCallerIdentity")"
CANONICAL_QUERY+="&$(urlencode "Version")=$(urlencode "2011-06-15")"
HEADER_HOST="host:${HOST}"
HEADER_X_AMZ_DATE="x-amz-date:${fulldate}"
HEADER_X_AMZ_SECURITY_TOKEN="x-amz-security-token:${SESSION_TOKEN}"
CANONICAL_HEADERS="${HEADER_HOST}\n${HEADER_X_AMZ_DATE}\n"
CANONICAL_HEADERS+="${HEADER_X_AMZ_SECURITY_TOKEN}"
REQ_PAYLOAD="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
SIGNED_HEADERS="host;x-amz-date;x-amz-security-token"

CANONICAL_REQUEST="${METHOD}\n${CANONICAL_URI}\n${CANONICAL_QUERY}\n"
CANONICAL_REQUEST+="${CANONICAL_HEADERS}\n\n${SIGNED_HEADERS}\n${REQ_PAYLOAD}"
HASHED_CANONICAL_REQUEST=$(sha256Hash "${CANONICAL_REQUEST}")

log "Hashed Canonical Request: ${HASHED_CANONICAL_REQUEST}"
log "Creating String to Sign"
ALGO="AWS4-HMAC-SHA256"
STRING_TO_SIGN="${ALGO}\n${fulldate}\n${shortdate}/${REGION}"
STRING_TO_SIGN+="/${SERVICE}/aws4_request\n${HASHED_CANONICAL_REQUEST}"
log "String to Sign: ${STRING_TO_SIGN}"

log "Calculating Signature"
secret=$(to_hex "AWS4${SECRET_KEY}")
k_date=$(hmac_sha256 "${secret}" "${shortdate}")
k_region=$(hmac_sha256 "${k_date}" "${REGION}")
k_service=$(hmac_sha256 "${k_region}" "${SERVICE}")
k_signing=$(hmac_sha256 "${k_service}" "aws4_request")
signature=$(hmac_sha256 "${k_signing}" "${STRING_TO_SIGN}" | sed 's/^.* //')

log "Signature: ${signature}"

log "Assembling Auth Header"
CRED="Credential=${ACCESS_KEY}/${shortdate}/${REGION}/${SERVICE}/aws4_request"
SIGNED_HEADERS="SignedHeaders=host;x-amz-date;x-amz-security-token"
SIGNATURE="Signature=${signature}"

AUTHORIZATION="${ALGO} ${CRED}, ${SIGNED_HEADERS}, ${SIGNATURE}"
log "Authorization Header: ${AUTHORIZATION}"

log "==========================================="
log "Attempting Conjur Authentication"
log "==========================================="

# Conjur Configuration
CONJUR_ACCOUNT="conjur"
CONJUR_URL="https://${PLATFORM_TENANT_NAME}.secretsmgr.cyberark.cloud/api"
SERVICE_ID="${SERVICE_ID}"
HOST_ID="${HOST_ID}"
CONJUR_KIND="variable"

# Payload using AWS Signed Auth Headers and Session Token
JSON_PAYLOAD=$(cat <<EOF
{
  "Authorization": "${AUTHORIZATION}",
  "host": "${HOST}",
  "X-Amz-Date": "${fulldate}",
  "X-Amz-Security-Token": "${SESSION_TOKEN}"
}
EOF
)

# Define Conjur authentication path
CONJUR_PATH="authn-iam/${SERVICE_ID}/${CONJUR_ACCOUNT}"
ENCODED_HOST_ID=$(urlencode "$HOST_ID")
CONJUR_PATH+="/${ENCODED_HOST_ID}/authenticate"

# Attempt Conjur Authentication
CONJUR_AUTH_RESPONSE=$(curl -s -w "\n%{http_code}" \
  -H "content-type: application/json" \
  -H "accept-encoding: base64" \
  -d "${JSON_PAYLOAD}" \
  "${CONJUR_URL}/${CONJUR_PATH}")

# Extract HTTP status code (last line)
HTTP_CODE=$(echo "$CONJUR_AUTH_RESPONSE" | tail -n1)
CONJUR_TOKEN=$(sed '$d' <<< "$CONJUR_AUTH_RESPONSE")

http_response $HTTP_CODE $CONJUR_TOKEN
log "Conjur Token (encoded): ${CONJUR_TOKEN:0:50}..."

# URL encode the variable identifier
ENCODED_USERNAME_VARIABLE=$(urlencode "${USERNAME_VARIABLE}")
ENCODED_PASSWORD_VARIABLE=$(urlencode "${PASSWORD_VARIABLE}")

# Construct the API endpoints
# Format: /secrets/{account}/{kind}/{identifier}
PASSWORD_API_ENDPOINT="${CONJUR_URL}/secrets/${CONJUR_ACCOUNT}"
PASSWORD_API_ENDPOINT+="/${CONJUR_KIND}/${ENCODED_PASSWORD_VARIABLE}"
USERNAME_API_ENDPOINT="${CONJUR_URL}/secrets/${CONJUR_ACCOUNT}"
USERNAME_API_ENDPOINT+="/${CONJUR_KIND}/${ENCODED_USERNAME_VARIABLE}"

log "Retrieving secret from Conjur Cloud..."
# Retrieve the password
USERNAME_VALUE=$(curl -sS -w "\n%{http_code}" \
  -H "Authorization:Token token=\"${CONJUR_TOKEN}\"" \
  "${USERNAME_API_ENDPOINT}")
PASSWORD_VALUE=$(curl -sS -w "\n%{http_code}" \
  -H "Authorization: Token token=\"${CONJUR_TOKEN}\"" \
  "${PASSWORD_API_ENDPOINT}")

# Extract secret value (everything except last line)
CLIENT_ID=$(echo "$USERNAME_VALUE" | sed '$d')
CLIENT_SECRET=$(echo "$PASSWORD_VALUE" | sed '$d')

log "Client ID Value: ${CLIENT_ID}"
log "Client Secret Value: ${CLIENT_SECRET:0:8}..."

log "==========================================="
log "Starting SIA Target Configuration"
log "==========================================="
log "Attempting Platform Auth"
IDENTITY_URL="https://${IDENTITY_TENANT_ID}.id.cyberark.cloud"
PLATFORM_TOKEN_URL="${IDENTITY_URL}/oauth2/platformtoken"
log "Requesting Oauth Token from ${PLATFORM_TOKEN_URL}"
PLATFORM_RESPONSE=$(curl -sS -w "\n%{http_code}" \
  -X POST "$PLATFORM_TOKEN_URL" \
  -H "Accept: application/json" \
  -F "grant_type=client_credentials" \
  -F "client_id=${CLIENT_ID}" \
  -F "client_secret=${CLIENT_SECRET}")

HTTP_CODE=$(tail -n1 <<<"${PLATFORM_RESPONSE}")
BODY=$(sed '$d' <<<"${PLATFORM_RESPONSE}")

http_response $HTTP_CODE $BODY

PLATFORM_TOKEN=$(jq -r '.access_token // empty' <<<"$BODY")
log "Parsed access_token: ${PLATFORM_TOKEN:0:50}..."

# Construct SIA script retreival URL and request configuration script
SIA_API_URL="https://${PLATFORM_TENANT_NAME}.dpa.cyberark.cloud/api"
CONFIGURE_TARGET_API_URL="${SIA_API_URL}/public-keys/scripts"
log "Requesting setup script from ${CONFIGURE_TARGET_API_URL}"
SETUP_RESPONSE=$(curl -sk -X GET "$CONFIGURE_TARGET_API_URL" \
  -H "Authorization: Bearer ${PLATFORM_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "workspaceId=${WORKSPACE_ID}" \
  -d "workspaceType=${WORKSPACE_TYPE}"
)

# Decode the Base64 payload into bash_cmd
base64_payload=$(jq -r '.base64_cmd' <<<"$SETUP_RESPONSE")
if [[ -z "$base64_payload" || "$base64_payload" == "null" ]]; then
  log_error "No 'base64_cmd' returned in setup response"
  exit 3
fi

SETUP_LOG="${LOG_DIR}/setup_script.log"
bash_cmd=$(echo "$base64_payload" | base64 --decode)
log "Executing decoded setup script"
eval "$bash_cmd" | tee -a ${SETUP_LOG}

# Invalidate token
log "Logging out of Identity Platform"
LOGOUT=$(curl -sS -X POST "${IDENTITY_URL}/security/logout" \
  -H "Authorization: Bearer ${PLATFORM_TOKEN}" -d "{}")
LOGOUT_SUCCESS=$(jq -r '.success' <<<${LOGOUT})
if $LOGOUT_SUCCESS; then
  log "Successfully logged out of Identity Platform"
else
  log_error "Failed to logout of Identity Platform"
fi

check_installation_completed "${SETUP_LOG}"
if [[ $? -eq 0 ]]; then
  log "Connector registration completed successfully"
  # Mark done
  touch "${FLAG}" 
else
    log_error "Connector registration did not complete properly"
    exit 1
fi