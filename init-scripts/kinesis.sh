#!/bin/bash
set -euo pipefail

# ====== Config ======
LOCALSTACK_ENDPOINT="${LOCALSTACK_ENDPOINT:-http://localhost:4566}"
AWS_REGION="${AWS_REGION:-us-east-1}"
STREAM_NAME="${STREAM_NAME:-events}"
SHARD_COUNT="${SHARD_COUNT:-1}"

# ====== Helpers ======
CURL_COMMON=( -sS --connect-timeout 5 --max-time 30 )

require() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing $1"; exit 1; }; }
require curl

# Function to check if running inside container vs host
detect_endpoint() {
    if [[ -n "${DOCKER_HOST:-}" ]] || [[ -f "/.dockerenv" ]]; then
        # Running inside container - use service name
        echo "http://localstack:4566"
    else
        # Running on host - use localhost
        echo "${LOCALSTACK_ENDPOINT}"
    fi
}

ENDPOINT=$(detect_endpoint)

# 1. Wait for LocalStack
echo "Waiting for LocalStack at ${ENDPOINT}..."
until curl "${CURL_COMMON[@]}" "${ENDPOINT}/_localstack/health" >/dev/null 2>&1; do
    echo "  LocalStack not ready, retrying in 2s..."
    sleep 2
done

# Check if Kinesis service is available
echo "Checking Kinesis service availability..."
HEALTH_JSON="$(curl "${CURL_COMMON[@]}" "${ENDPOINT}/_localstack/health")"
KINESIS_STATUS="$(echo "${HEALTH_JSON}" | jq -r '.services.kinesis // "disabled"')"

if [[ "${KINESIS_STATUS}" != "available" && "${KINESIS_STATUS}" != "running" ]]; then
    echo "ERROR: Kinesis service is ${KINESIS_STATUS}. Check LocalStack configuration."
    exit 1
fi

echo "✅ Kinesis service is ${KINESIS_STATUS}"

# 2. Check if stream exists
echo "Checking if Kinesis stream '${STREAM_NAME}' exists..."
STREAM_EXISTS=false

# Use awslocal if available (inside LocalStack container), otherwise use curl directly
if command -v awslocal >/dev/null 2>&1; then
    echo "Using awslocal command..."
    EXISTING_STREAMS=$(awslocal kinesis list-streams --region "${AWS_REGION}" --output json 2>/dev/null | jq -r '.StreamNames[]? // empty')
else
    echo "Using curl to LocalStack Kinesis API..."
    # Direct API call to LocalStack Kinesis
    LIST_RESPONSE=$(curl "${CURL_COMMON[@]}" \
        -X POST "${ENDPOINT}/" \
        -H "Content-Type: application/x-amz-json-1.1" \
        -H "X-Amz-Target: Kinesis_20131202.ListStreams" \
        -H "Authorization: AWS4-HMAC-SHA256 Credential=test/20230101/us-east-1/kinesis/aws4_request, SignedHeaders=host;x-amz-date, Signature=test" \
        -d '{}' 2>/dev/null || echo '{"StreamNames":[]}')

    EXISTING_STREAMS=$(echo "${LIST_RESPONSE}" | jq -r '.StreamNames[]? // empty' 2>/dev/null || echo "")
fi

for stream in ${EXISTING_STREAMS}; do
    if [[ "${stream}" == "${STREAM_NAME}" ]]; then
        STREAM_EXISTS=true
        break
    fi
done

# 3. Create stream if it doesn't exist
if [[ "${STREAM_EXISTS}" == "true" ]]; then
    echo "Stream '${STREAM_NAME}' already exists."
else
    echo "Creating Kinesis stream '${STREAM_NAME}' with ${SHARD_COUNT} shard(s)..."

    if command -v awslocal >/dev/null 2>&1; then
        awslocal kinesis create-stream \
            --stream-name "${STREAM_NAME}" \
            --shard-count "${SHARD_COUNT}" \
            --region "${AWS_REGION}"
    else
        # Direct API call
        curl "${CURL_COMMON[@]}" \
            -X POST "${ENDPOINT}/" \
            -H "Content-Type: application/x-amz-json-1.1" \
            -H "X-Amz-Target: Kinesis_20131202.CreateStream" \
            -H "Authorization: AWS4-HMAC-SHA256 Credential=test/20230101/us-east-1/kinesis/aws4_request, SignedHeaders=host;x-amz-date, Signature=test" \
            -d "{\"StreamName\":\"${STREAM_NAME}\",\"ShardCount\":${SHARD_COUNT}}"
    fi

    echo "Waiting for stream to become active..."
    sleep 3

    # Wait for stream to be active
    MAX_ATTEMPTS=30
    ATTEMPT=0
    while [[ ${ATTEMPT} -lt ${MAX_ATTEMPTS} ]]; do
        if command -v awslocal >/dev/null 2>&1; then
            STATUS=$(awslocal kinesis describe-stream --stream-name "${STREAM_NAME}" --region "${AWS_REGION}" --output json 2>/dev/null | jq -r '.StreamDescription.StreamStatus // "UNKNOWN"')
        else
            DESCRIBE_RESPONSE=$(curl "${CURL_COMMON[@]}" \
                -X POST "${ENDPOINT}/" \
                -H "Content-Type: application/x-amz-json-1.1" \
                -H "X-Amz-Target: Kinesis_20131202.DescribeStream" \
                -H "Authorization: AWS4-HMAC-SHA256 Credential=test/20230101/us-east-1/kinesis/aws4_request, SignedHeaders=host;x-amz-date, Signature=test" \
                -d "{\"StreamName\":\"${STREAM_NAME}\"}" 2>/dev/null || echo '{}')
            STATUS=$(echo "${DESCRIBE_RESPONSE}" | jq -r '.StreamDescription.StreamStatus // "UNKNOWN"')
        fi

        if [[ "${STATUS}" == "ACTIVE" ]]; then
            echo "Stream '${STREAM_NAME}' is now ACTIVE."
            break
        elif [[ "${STATUS}" == "UNKNOWN" ]]; then
            echo "Could not determine stream status, continuing..."
            break
        else
            echo "  Stream status: ${STATUS}, waiting..."
            sleep 2
            ((ATTEMPT++))
        fi
    done

    if [[ ${ATTEMPT} -ge ${MAX_ATTEMPTS} ]]; then
        echo "WARNING: Stream may not be ready after ${MAX_ATTEMPTS} attempts."
    fi
fi

# 4. Verify stream is accessible
echo "Verifying stream '${STREAM_NAME}' is accessible..."
if command -v awslocal >/dev/null 2>&1; then
    awslocal kinesis list-streams --region "${AWS_REGION}" | grep -q "${STREAM_NAME}" && echo "✅ Stream verified!" || echo "❌ Stream verification failed!"
else
    curl "${CURL_COMMON[@]}" \
        -X POST "${ENDPOINT}/" \
        -H "Content-Type: application/x-amz-json-1.1" \
        -H "X-Amz-Target: Kinesis_20131202.ListStreams" \
        -H "Authorization: AWS4-HMAC-SHA256 Credential=test/20230101/us-east-1/kinesis/aws4_request, SignedHeaders=host;x-amz-date, Signature=test" \
        -d '{}' | grep -q "${STREAM_NAME}" && echo "✅ Stream verified!" || echo "❌ Stream verification failed!"
fi

echo "------------------------------------------"
echo "Kinesis stream '${STREAM_NAME}' initialization complete!"
echo "Stream ARN: arn:aws:kinesis:${AWS_REGION}:000000000000:stream/${STREAM_NAME}"
echo "Endpoint: ${ENDPOINT}"
echo "------------------------------------------"