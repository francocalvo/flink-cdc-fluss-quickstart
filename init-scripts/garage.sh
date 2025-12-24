#!/bin/bash
set -euo pipefail

# ====== Config ======
GARAGE_ADMIN="${GARAGE_ADMIN:-http://localhost:3903}"
GARAGE_ADMIN_TOKEN="${GARAGE_ADMIN_TOKEN:-dev-admin-token}"
ENV_FILE=".env"

# For local dev, a stable bucket alias + key name
KEY_NAME="${KEY_NAME:-paimon-key}"
BUCKET_ALIAS="${BUCKET_ALIAS:-warehouse}"

CAPACITY_BYTES="${CAPACITY_BYTES:-1073741824}" # 1 GiB
ZONE="${ZONE:-dc1}"

# ====== Helpers ======
CURL_COMMON=( -sS --connect-timeout 2 --max-time 15 )

require() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing $1"; exit 1; }; }
require curl
require jq

curl_admin() {
  curl "${CURL_COMMON[@]}" -H "Authorization: Bearer ${GARAGE_ADMIN_TOKEN}" "$@"
}

# 1. Wait for API
echo "Waiting for Garage admin API at ${GARAGE_ADMIN} ..."
until curl "${CURL_COMMON[@]}" "${GARAGE_ADMIN}/health" >/dev/null 2>&1; do
  sleep 2
done

# 2. Get Node ID
echo "Getting node ID..."
STATUS_JSON="$(curl_admin "${GARAGE_ADMIN}/v1/status")"
NODE_ID="$(echo "${STATUS_JSON}" | jq -r '.node // empty')"

if [[ -z "${NODE_ID}" || "${NODE_ID}" == "null" ]]; then
  echo "ERROR: /v1/status did not return .node"
  exit 1
fi

# 3. Handle Role/Layout
ROLE_NOW="$(echo "${STATUS_JSON}" | jq -r --arg nid "$NODE_ID" '(.nodes[]? | select(.id==$nid) | .role) // empty')"

if [[ -z "${ROLE_NOW}" || "${ROLE_NOW}" == "null" ]]; then
  echo "Node has no role; staging and applying layout..."
  curl_admin -X POST "${GARAGE_ADMIN}/v1/layout" \
    -H "Content-Type: application/json" \
    -d "[{\"id\": \"${NODE_ID}\", \"zone\": \"${ZONE}\", \"capacity\": ${CAPACITY_BYTES}, \"tags\": [\"local\"]}]" > /dev/null

  LAYOUT_VERSION="$(curl_admin "${GARAGE_ADMIN}/v1/layout" | jq -r '.version')"
  NEXT_VERSION=$((LAYOUT_VERSION + 1))

  curl_admin -X POST "${GARAGE_ADMIN}/v1/layout/apply" \
    -H "Content-Type: application/json" \
    -d "{\"version\": ${NEXT_VERSION}}" > /dev/null
  sleep 3
fi

# 4. Handle Access Keys
echo "Creating/Fetching access key..."
KEY_RESPONSE="$(curl_admin -X POST "${GARAGE_ADMIN}/v1/key" \
  -H "Content-Type: application/json" \
  -d "{\"name\":\"${KEY_NAME}\"}")"

ACCESS_KEY="$(echo "${KEY_RESPONSE}" | jq -r '.accessKeyId // empty')"
SECRET_KEY="$(echo "${KEY_RESPONSE}" | jq -r '.secretAccessKey // empty')"

if [[ -z "${ACCESS_KEY}" || "${ACCESS_KEY}" == "null" ]]; then
    KEY_DETAILS="$(curl_admin "${GARAGE_ADMIN}/v1/key?name=${KEY_NAME}")"
    ACCESS_KEY="$(echo "${KEY_DETAILS}" | jq -r '.[0].accessKeyId // empty')"
    SECRET_KEY="$(echo "${KEY_DETAILS}" | jq -r '.[0].secretAccessKey // empty')"
fi

# 5. Handle Bucket
echo "Ensuring bucket '${BUCKET_ALIAS}' exists..."

# Check if bucket already exists
EXISTING_BUCKET=$(curl_admin "${GARAGE_ADMIN}/v1/bucket?globalAlias=${BUCKET_ALIAS}" 2>/dev/null | jq -r '.id // empty')

if [[ -n "${EXISTING_BUCKET}" && "${EXISTING_BUCKET}" != "null" && "${EXISTING_BUCKET}" != "empty" ]]; then
    echo "Bucket '${BUCKET_ALIAS}' already exists with ID: ${EXISTING_BUCKET}"
    BUCKET_ID="${EXISTING_BUCKET}"
else
    echo "Creating bucket '${BUCKET_ALIAS}'..."

    # Create bucket using CLI (more reliable than API)
    docker exec garage /garage -c /etc/garage.toml bucket create "${BUCKET_ALIAS}" >/dev/null 2>&1 || {
        echo "Warning: Bucket creation via CLI failed, trying API..."

        # Fallback to API creation without alias, then add alias
        CREATE_RES=$(curl_admin -X POST "${GARAGE_ADMIN}/v1/bucket" \
          -H "Content-Type: application/json" \
          -d "{}")

        BUCKET_ID=$(echo "${CREATE_RES}" | jq -r '.id // empty')

        if [[ -n "${BUCKET_ID}" && "${BUCKET_ID}" != "null" ]]; then
            echo "Created bucket, adding alias..."
            docker exec garage /garage -c /etc/garage.toml bucket alias "${BUCKET_ID}" "${BUCKET_ALIAS}" >/dev/null 2>&1
        fi
    }

    # Get the bucket ID after creation
    BUCKET_ID=$(curl_admin "${GARAGE_ADMIN}/v1/bucket?globalAlias=${BUCKET_ALIAS}" | jq -r '.id // empty')
fi

# 6. Grant Permissions
curl_admin -X POST "${GARAGE_ADMIN}/v1/bucket/allow" \
  -H "Content-Type: application/json" \
  -d "{
    \"bucketId\": \"${BUCKET_ID}\",
    \"accessKeyId\": \"${ACCESS_KEY}\",
    \"permissions\": {\"read\": true, \"write\": true, \"owner\": true}
  }" > /dev/null

# 7. Output to .env
echo "Writing credentials to ${ENV_FILE}..."

cat <<EOF > "${ENV_FILE}"
# Garage S3 Credentials
GARAGE_ACCESS_KEY=${ACCESS_KEY}
GARAGE_SECRET_KEY=${SECRET_KEY}
# S3 API endpoint (default Garage S3 port is 3900)
S3_ENDPOINT=http://localhost:3900
BUCKET_NAME=${BUCKET_ALIAS}
EOF

echo "------------------------------------------"
echo "Success! Contents of ${ENV_FILE}:"
cat "${ENV_FILE}"
echo "------------------------------------------"
echo "Garage initialization complete!"
