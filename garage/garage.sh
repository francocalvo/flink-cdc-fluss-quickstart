#!/bin/bash
set -euo pipefail

# ====== Config ======
GARAGE_CONTAINER="${GARAGE_CONTAINER:-garage}"
GARAGE_ADMIN="${GARAGE_ADMIN:-http://localhost:3903}"
GARAGE_ADMIN_TOKEN="${GARAGE_ADMIN_TOKEN:-dev-admin-token}"
ENV_FILE=".env"

KEY_NAME="${KEY_NAME:-paimon-key}"
BUCKET_ALIAS="${BUCKET_ALIAS:-warehouse}"
CAPACITY="${CAPACITY:-1GB}"
ZONE="${ZONE:-dc1}"

# ====== Helpers ======
require() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing $1"; exit 1; }; }
require curl
require jq
require docker

garage_cli() {
  docker exec "${GARAGE_CONTAINER}" /garage "$@"
}

api() {
  curl -sS --connect-timeout 5 --max-time 30 \
    -H "Authorization: Bearer ${GARAGE_ADMIN_TOKEN}" \
    "$@"
}

# ====== Step 1: Wait for API ======
echo "==> Step 1: Waiting for Garage API..."
for i in {1..30}; do
  if curl -sS --connect-timeout 2 "${GARAGE_ADMIN}/health" >/dev/null 2>&1; then
    echo "    API is up"
    break
  fi
  sleep 2
done

# ====== Step 2: Get Node ID ======
echo "==> Step 2: Getting node ID..."
NODE_ID="$(api "${GARAGE_ADMIN}/v2/GetClusterStatus" | jq -r '.nodes[0].id')"
echo "    Node ID: ${NODE_ID}"

if [[ -z "${NODE_ID}" || "${NODE_ID}" == "null" ]]; then
  echo "ERROR: No node found"
  exit 1
fi

# ====== Step 3: Check if layout needs configuration ======
echo "==> Step 3: Checking layout..."
LAYOUT="$(api "${GARAGE_ADMIN}/v2/GetClusterLayout")"
ROLE_COUNT="$(echo "${LAYOUT}" | jq '.roles | length')"

echo "    Nodes with roles: ${ROLE_COUNT}"

if [[ "${ROLE_COUNT}" -eq 0 ]]; then
  # ====== Step 4: Configure layout via CLI ======
  echo "==> Step 4: Configuring layout via CLI..."
  
  echo "    Assigning role to node..."
  garage_cli layout assign "${NODE_ID}" -c "${CAPACITY}" -z "${ZONE}" -t local
  
  echo "    Applying layout..."
  garage_cli layout apply --version 1
  
  echo "    Layout applied"
else
  echo "    Layout already configured, skipping"
fi

# ====== Step 5: Wait for cluster health ======
echo "==> Step 5: Waiting for cluster to be healthy..."
for i in {1..60}; do
  HEALTH="$(api "${GARAGE_ADMIN}/v2/GetClusterHealth" 2>/dev/null || echo "{}")"
  STATUS="$(echo "${HEALTH}" | jq -r '.status // "unknown"')"
  STORAGE="$(echo "${HEALTH}" | jq -r '.storageNodes // 0')"
  
  if [[ "${STATUS}" == "healthy" ]]; then
    echo "    Cluster healthy (${STORAGE} storage node(s))"
    break
  fi
  
  if [[ $((i % 5)) -eq 0 ]]; then
    echo "    Waiting... status=${STATUS}, storageNodes=${STORAGE}"
  fi
  sleep 1
done

if [[ "${STATUS}" != "healthy" ]]; then
  echo "ERROR: Cluster not healthy after 60s"
  api "${GARAGE_ADMIN}/v2/GetClusterHealth" | jq .
  exit 1
fi

# ====== Step 6: Create access key via CLI ======
echo "==> Step 6: Creating access key..."

# Check if key exists and delete it
EXISTING_KEY="$(garage_cli key list 2>/dev/null | grep "${KEY_NAME}" | awk '{print $1}' || echo "")"
if [[ -n "${EXISTING_KEY}" ]]; then
  echo "    Deleting existing key: ${EXISTING_KEY}"
  garage_cli key delete --yes "${EXISTING_KEY}" 2>/dev/null || true
fi

# Create new key
KEY_OUTPUT="$(garage_cli key create "${KEY_NAME}")"
ACCESS_KEY="$(echo "${KEY_OUTPUT}" | grep "Key ID:" | awk '{print $3}')"
SECRET_KEY="$(echo "${KEY_OUTPUT}" | grep "Secret key:" | awk '{print $3}')"

if [[ -z "${ACCESS_KEY}" || -z "${SECRET_KEY}" ]]; then
  echo "ERROR: Failed to parse key output"
  echo "${KEY_OUTPUT}"
  exit 1
fi

echo "    Created key: ${ACCESS_KEY}"

# ====== Step 7: Create bucket via CLI ======
echo "==> Step 7: Creating bucket..."

if garage_cli bucket info "${BUCKET_ALIAS}" >/dev/null 2>&1; then
  echo "    Bucket already exists"
else
  garage_cli bucket create "${BUCKET_ALIAS}"
  echo "    Created bucket: ${BUCKET_ALIAS}"
fi

# ====== Step 8: Grant permissions via CLI ======
echo "==> Step 8: Granting permissions..."
garage_cli bucket allow --read --write --owner "${BUCKET_ALIAS}" --key "${ACCESS_KEY}"
echo "    Permissions granted"

# ====== Step 9: Write .env ======
echo "==> Step 9: Writing ${ENV_FILE}..."
cat > "${ENV_FILE}" <<EOF
# Garage S3 credentials - $(date -Iseconds)
GARAGE_ACCESS_KEY=${ACCESS_KEY}
GARAGE_SECRET_KEY=${SECRET_KEY}
S3_ENDPOINT=http://localhost:3900
BUCKET_NAME=${BUCKET_ALIAS}
EOF

echo ""
echo "========== SUCCESS =========="
cat "${ENV_FILE}"
echo "============================="
