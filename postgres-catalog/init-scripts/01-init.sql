-- ===========================================
-- Catalogs
-- ===========================================
CREATE CATALOG paimon_catalog WITH (
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

CREATE CATALOG fluss_catalog WITH (
    'type' = 'fluss',
    'bootstrap.servers' = 'fluss-coordinator:9123'
);

-- ===========================================
-- CDC Source: osb.tickets
-- ===========================================
CREATE TABLE cdc_tickets (
    id STRING NOT NULL,
    user_id STRING NOT NULL,
    status STRING NOT NULL,
    cancel_reason STRING,
    entry_amount bigint NOT NULL,
    winning_amount bigint,
    transactions_entry_transaction STRING,
    transactions_winning_transaction STRING,
    transactions_cancel_transaction STRING,
    status_updated_at timestamp(3
) WITH LOCAL time zone NOT NULL,
    created_at timestamp(3
) WITH LOCAL time zone NOT NULL,
    updated_at timestamp(3
) WITH LOCAL time zone NOT NULL,
    deleted_at timestamp(3
) WITH LOCAL time zone,
    free_ticket_promotion_id STRING,
    booster_promotion_id STRING,
    booster_promotion_change_reason STRING,
    accept_odds_change boolean,
    promo_id STRING,
    PRIMARY KEY (id) NOT ENFORCED
)
WITH (
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
-- Paimon Sink: tickets
-- ===========================================
CREATE TABLE tickets (
    id STRING NOT NULL,
    user_id STRING NOT NULL,
    status STRING NOT NULL,
    cancel_reason STRING,
    entry_amount bigint NOT NULL,
    winning_amount bigint,
    transactions_entry_transaction STRING,
    transactions_winning_transaction STRING,
    transactions_cancel_transaction STRING,
    status_updated_at timestamp(3
) WITH LOCAL time zone NOT NULL,
    created_at timestamp(3
) WITH LOCAL time zone NOT NULL,
    updated_at timestamp(3
) WITH LOCAL time zone NOT NULL,
    deleted_at timestamp(3
) WITH LOCAL time zone,
    free_ticket_promotion_id STRING,
    booster_promotion_id STRING,
    booster_promotion_change_reason STRING,
    accept_odds_change boolean,
    promo_id STRING,
    PRIMARY KEY (id) NOT ENFORCED
)
WITH (
    'merge-engine' = 'deduplicate',
    'changelog-producer' = 'input',
    'bucket' = '4'
);

-- ===========================================
-- Fluss Streaming Table (optional)
-- ===========================================
CREATE TABLE fluss_catalog.default_db.tickets_stream (
    id STRING NOT NULL,
    user_id STRING NOT NULL,
    status STRING NOT NULL,
    cancel_reason STRING,
    entry_amount bigint NOT NULL,
    winning_amount bigint,
    status_updated_at timestamp(3
) WITH LOCAL time zone NOT NULL,
    created_at timestamp(3
) WITH LOCAL time zone NOT NULL,
    updated_at timestamp(3
) WITH LOCAL time zone NOT NULL,
    PRIMARY KEY (id) NOT ENFORCED
);

-- ===========================================
-- Kinesis Source (optional, uses new 5.x connector)
-- ===========================================
CREATE TABLE kinesis_events (
    event_id STRING,
    event_type STRING,
    payload STRING,
    event_time timestamp(3),
    WATERMARK FOR event_time AS event_time - interval '5' SECOND
)
WITH (
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
-- Run CDC Pipeline
-- ===========================================
-- INSERT INTO tickets SELECT * FROM cdc_tickets;
