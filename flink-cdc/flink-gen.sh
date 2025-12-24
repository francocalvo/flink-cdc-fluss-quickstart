#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"
OUTPUT_FILE="${SCRIPT_DIR}/../sql/init-catalogs.sql"

# Load environment variables
if [[ -f "${ENV_FILE}" ]]; then
    set -a
    source "${ENV_FILE}"
    set +a
else
    echo "ERROR: No .env file found at ${ENV_FILE}"
    echo "Run garage.sh first to generate credentials."
    exit 1
fi

# Generate the SQL file
cat > "${OUTPUT_FILE}" << EOF
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
-- Paimon Sink Table: tickets
-- ===========================================
USE CATALOG paimon_catalog;
USE lakehouse;

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
EOF

chmod 644 "${OUTPUT_FILE}"

echo "✅ Generated: ${OUTPUT_FILE}"
echo ""
echo "To start an interactive session with catalogs pre-configured, run:"
echo ""
echo "  docker compose cp sql/init-catalogs.sql sql-client:/tmp/init-catalogs.sql"
echo "  docker compose exec sql-client /opt/flink/bin/sql-client.sh -i /tmp/init-catalogs.sql"
echo ""
echo "Then to start the CDC pipeline:"
echo "  INSERT INTO paimon_catalog.lakehouse.tickets SELECT * FROM cdc_tickets;"
