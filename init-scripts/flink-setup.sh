#!/bin/bash
set -euo pipefail

# ====== Config ======
FLINK_ENDPOINT="${FLINK_ENDPOINT:-http://localhost:8081}"
SQL_CLIENT_CONTAINER="${SQL_CLIENT_CONTAINER:-flink-sql-client}"
DOCKER_COMPOSE_PROJECT="${DOCKER_COMPOSE_PROJECT:-}"

# Path to SQL scripts
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CATALOG_SQL="${SCRIPT_DIR}/../init-scripts/catalog/01-init.sql"

# Environment file for credentials
ENV_FILE="${SCRIPT_DIR}/../.env"

# ====== Helpers ======
CURL_COMMON=( -sS --connect-timeout 5 --max-time 30 )

require() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing $1"; exit 1; }; }
require curl
require docker

# Simple environment variable substitution function
substitute_env_vars() {
    local content="$1"
    # Replace ${VAR} with environment variable values
    while IFS= read -r line; do
        # Use eval to expand variables, but escape dangerous chars first
        line=$(printf '%s\n' "$line" | sed 's/\\/\\\\/g')
        eval "echo \"$line\""
    done <<< "$content"
}

# Load environment variables if .env exists
if [[ -f "${ENV_FILE}" ]]; then
    echo "Loading environment from ${ENV_FILE}..."
    set -a
    source "${ENV_FILE}"
    set +a
else
    echo "WARNING: No .env file found at ${ENV_FILE}"
    echo "Make sure to run garage.sh first to generate credentials."
fi

# Function to detect Docker context (container vs host)
detect_flink_endpoint() {
    if [[ -n "${DOCKER_HOST:-}" ]] || [[ -f "/.dockerenv" ]]; then
        echo "http://jobmanager:8081"
    else
        echo "${FLINK_ENDPOINT}"
    fi
}

FLINK_API=$(detect_flink_endpoint)

# Function to run SQL in Flink SQL Client
run_flink_sql() {
    local sql_content="$1"
    local description="$2"

    echo "Executing: ${description}"

    # Create temporary SQL file with substituted environment variables
    local temp_sql=$(mktemp)
    trap "rm -f ${temp_sql}" EXIT

    # Substitute environment variables in SQL content
    substitute_env_vars "${sql_content}" > "${temp_sql}"

    # Generate unique filename to avoid conflicts
    local sql_filename="temp-init-$(date +%s).sql"

    # Copy SQL file to container
    docker cp "${temp_sql}" "${SQL_CLIENT_CONTAINER}:/opt/flink/sql/${sql_filename}"

    # Execute the SQL
    docker exec "${SQL_CLIENT_CONTAINER}" \
        /opt/flink/bin/sql-client.sh \
        -f "/opt/flink/sql/${sql_filename}" 2>&1 | tee /tmp/flink-sql-output.log

    # Clean up the temp file in container (best effort)
    docker exec "${SQL_CLIENT_CONTAINER}" rm -f "/opt/flink/sql/${sql_filename}" 2>/dev/null || true

    # Check if execution was successful
    if grep -q "Exception\|Error\|FAILED" /tmp/flink-sql-output.log; then
        echo "❌ SQL execution failed for: ${description}"
        return 1
    else
        echo "✅ SQL execution completed: ${description}"
        return 0
    fi
}

# 1. Wait for Flink JobManager
echo "Waiting for Flink JobManager at ${FLINK_API}..."
MAX_ATTEMPTS=30
ATTEMPT=0

while [[ ${ATTEMPT} -lt ${MAX_ATTEMPTS} ]]; do
    if curl "${CURL_COMMON[@]}" "${FLINK_API}/overview" >/dev/null 2>&1; then
        echo "✅ Flink JobManager is ready"
        break
    else
        echo "  Flink not ready, retrying in 2s... (${ATTEMPT}/${MAX_ATTEMPTS})"
        sleep 2
        ((ATTEMPT++))
    fi
done

if [[ ${ATTEMPT} -ge ${MAX_ATTEMPTS} ]]; then
    echo "❌ Flink JobManager not available after ${MAX_ATTEMPTS} attempts"
    exit 1
fi

# 2. Check Flink cluster status
echo "Checking Flink cluster status..."
OVERVIEW=$(curl "${CURL_COMMON[@]}" "${FLINK_API}/overview")
TASKMANAGERS=$(echo "${OVERVIEW}" | jq -r '.taskmanagers // 0')
SLOTS_AVAILABLE=$(echo "${OVERVIEW}" | jq -r '."slots-available" // 0')

echo "Cluster status:"
echo "  - TaskManagers: ${TASKMANAGERS}"
echo "  - Available slots: ${SLOTS_AVAILABLE}"

if [[ "${SLOTS_AVAILABLE}" -eq 0 ]]; then
    echo "WARNING: No available task slots. Jobs may not be able to run."
fi

# 3. Wait for SQL Client container
echo "Waiting for SQL Client container..."
if ! docker exec "${SQL_CLIENT_CONTAINER}" echo "Container ready" >/dev/null 2>&1; then
    echo "ERROR: SQL Client container '${SQL_CLIENT_CONTAINER}' is not running"
    echo "Available containers:"
    docker ps --format "table {{.Names}}\t{{.Status}}"
    exit 1
fi

# 4. Create all tables in a single SQL session
echo "Setting up complete Flink pipeline in single session..."
COMPLETE_SQL_CONTENT=$(cat << 'EOF'
-- ===========================================
-- Create Paimon Catalog
-- ===========================================
CREATE CATALOG IF NOT EXISTS paimon_catalog WITH (
    'type' = 'paimon',
    'metastore' = 'jdbc',
    'uri' = 'jdbc:postgresql://postgres-catalog:5432/paimon_catalog',
    'jdbc.user' = 'root',
    'jdbc.password' = 'root',
    'warehouse' = 's3://warehouse/paimon',
    's3.endpoint' = 'http://garage:3900',
    's3.path-style-access' = 'true',
    's3.access-key' = '${GARAGE_ACCESS_KEY}',
    's3.secret-key' = '${GARAGE_SECRET_KEY}'
);

USE CATALOG paimon_catalog;
CREATE DATABASE IF NOT EXISTS lakehouse;
USE lakehouse;

-- ===========================================
-- Create Fluss Catalog (Optional)
-- ===========================================
CREATE CATALOG IF NOT EXISTS fluss_catalog WITH (
    'type' = 'fluss',
    'bootstrap.servers' = 'fluss-coordinator:9123'
);

-- ===========================================
-- Switch to default catalog for connector tables
-- ===========================================
USE CATALOG default_catalog;
USE default_database;

-- ===========================================
-- CDC Source Table: osb.tickets
-- ===========================================
CREATE TABLE IF NOT EXISTS cdc_tickets (
    id STRING NOT NULL,
    user_id STRING NOT NULL,
    status STRING NOT NULL,
    cancel_reason STRING,
    entry_amount BIGINT NOT NULL,
    winning_amount BIGINT,
    transactions_entry_transaction STRING,
    transactions_winning_transaction STRING,
    transactions_cancel_transaction STRING,
    status_updated_at TIMESTAMP(3) WITH LOCAL TIME ZONE NOT NULL,
    created_at TIMESTAMP(3) WITH LOCAL TIME ZONE NOT NULL,
    updated_at TIMESTAMP(3) WITH LOCAL TIME ZONE NOT NULL,
    deleted_at TIMESTAMP(3) WITH LOCAL TIME ZONE,
    free_ticket_promotion_id STRING,
    booster_promotion_id STRING,
    booster_promotion_change_reason STRING,
    accept_odds_change BOOLEAN,
    promo_id STRING,
    PRIMARY KEY (id) NOT ENFORCED
) WITH (
    'connector' = 'postgres-cdc',
    'hostname' = 'postgres-source',
    'port' = '5432',
    'username' = 'root',
    'password' = 'root',
    'database-name' = 'source_db',
    'schema-name' = 'osb',
    'table-name' = 'tickets',
    'slot.name' = 'tickets_slot',
    'decoding.plugin.name' = 'pgoutput'
);

-- ===========================================
-- Kinesis Source Table: events
-- ===========================================
CREATE TABLE IF NOT EXISTS kinesis_events (
    event_id STRING,
    event_type STRING,
    payload STRING,
    event_time TIMESTAMP(3),
    WATERMARK FOR event_time AS event_time - INTERVAL '5' SECOND
) WITH (
    'connector' = 'kinesis',
    'stream.arn' = 'arn:aws:kinesis:us-east-1:000000000000:stream/events',
    'aws.region' = 'us-east-1',
    'aws.endpoint' = 'http://localstack:4566',
    'aws.credentials.provider' = 'BASIC',
    'aws.credentials.basic.accesskeyid' = 'test',
    'aws.credentials.basic.secretkey' = 'test',
    'source.init.position' = 'TRIM_HORIZON',
    'format' = 'json'
);

-- ===========================================
-- Switch to Paimon catalog for Paimon tables
-- ===========================================
USE CATALOG paimon_catalog;
USE lakehouse;

-- ===========================================
-- Paimon Sink Table: tickets
-- ===========================================
CREATE TABLE IF NOT EXISTS tickets (
    id STRING NOT NULL,
    user_id STRING NOT NULL,
    status STRING NOT NULL,
    cancel_reason STRING,
    entry_amount BIGINT NOT NULL,
    winning_amount BIGINT,
    transactions_entry_transaction STRING,
    transactions_winning_transaction STRING,
    transactions_cancel_transaction STRING,
    status_updated_at TIMESTAMP(3) WITH LOCAL TIME ZONE NOT NULL,
    created_at TIMESTAMP(3) WITH LOCAL TIME ZONE NOT NULL,
    updated_at TIMESTAMP(3) WITH LOCAL TIME ZONE NOT NULL,
    deleted_at TIMESTAMP(3) WITH LOCAL TIME ZONE,
    free_ticket_promotion_id STRING,
    booster_promotion_id STRING,
    booster_promotion_change_reason STRING,
    accept_odds_change BOOLEAN,
    promo_id STRING,
    PRIMARY KEY (id) NOT ENFORCED
) WITH (
    'merge-engine' = 'deduplicate',
    'changelog-producer' = 'input',
    'bucket' = '4'
);

-- ===========================================
-- Verify Setup
-- ===========================================
-- Show tables in default catalog
USE CATALOG default_catalog;
SHOW TABLES;

-- Show tables in Paimon catalog
USE CATALOG paimon_catalog;
USE lakehouse;
SHOW TABLES;
EOF
)

# Execute all SQL in a single session
run_flink_sql "${COMPLETE_SQL_CONTENT}" "Setting up complete Flink pipeline"

echo "------------------------------------------"
echo "✅ Flink/Paimon setup complete!"
echo ""
echo "Available tables:"
echo "  - cdc_tickets (PostgreSQL CDC source)"
echo "  - tickets (Paimon sink)"
echo "  - kinesis_events (Kinesis source)"
echo ""
echo "To start CDC pipeline, run:"
echo "  INSERT INTO tickets SELECT * FROM cdc_tickets;"
echo ""
echo "To access Flink Web UI: http://localhost:8081"
echo "------------------------------------------"