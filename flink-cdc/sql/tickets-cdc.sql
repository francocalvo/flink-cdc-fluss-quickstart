-- Run streaming job + checkpointing for EOS
SET 'execution.runtime-mode' = 'streaming';
SET 'execution.checkpointing.mode' = 'EXACTLY_ONCE';
SET 'execution.checkpointing.interval' = '5s';
SET 'execution.checkpointing.max-concurrent-checkpoints' = '1';

-- Event time processing optimization
SET 'pipeline.watermark-alignment.allow-unaligned-source-splits' = 'true';

-- 1) Fluss catalog (point to coordinator+tablet; Fluss supports comma-separated bootstrap servers) :contentReference[oaicite:3]{index=3}
CREATE CATALOG fluss_catalog WITH (
    'type' = 'fluss',
    'bootstrap.servers' = '192.168.1.202:9123,192.168.1.202:9124'
);
USE CATALOG fluss_catalog;

CREATE DATABASE IF NOT EXISTS osb_staging;
USE osb_staging;

-- DROP TABLE IF EXISTS tickets_staging;

-- 2) Fluss staging table (append-only log table) with event time
CREATE TABLE IF NOT EXISTS tickets_staging (
    ticket_id bigint,
    movie_id bigint,
    user_id bigint,
    cost DECIMAL(10, 2),
    status STRING,
    purchased_at timestamp(3),
    WATERMARK FOR purchased_at AS purchased_at - INTERVAL '3' SECOND,
    PRIMARY KEY (ticket_id) NOT ENFORCED
)
WITH (
    'bucket.num' = '4',
    'table.datalake.enabled' = 'true',
    'table.datalake.freshness' = '30s'
);


-- 3) Postgres CDC source (Flink CDC SQL connector)
-- The connector options shown here are the documented ones. :contentReference[oaicite:4]{index=4}

CREATE TEMPORARY TABLE pg_osb_tickets (
  ticket_id BIGINT,
  movie_id BIGINT,
  user_id BIGINT,
  cost DECIMAL(10,2),
  status STRING,
  purchased_at TIMESTAMP(3),
  WATERMARK FOR purchased_at AS purchased_at - INTERVAL '3' SECOND,
  PRIMARY KEY (ticket_id) NOT ENFORCED
) WITH (
  'connector' = 'postgres-cdc',
  'hostname' = '192.168.1.202',
  'port' = '5432',
  'username' = 'root',
  'password' = 'root',
  'database-name' = 'source_db',
  'schema-name' = 'osb',
  'table-name' = 'tickets',
  'slot.name' = 'cdc_osb_tickets_to_fluss',
  'decoding.plugin.name' = 'pgoutput',
  'scan.incremental.snapshot.enabled' = 'true'
);


-- 4) Start the replication stream into Fluss
INSERT INTO tickets_staging
SELECT
    ticket_id,
    movie_id,
    user_id,
    cost,
    status,
    purchased_at
FROM
    pg_osb_tickets;

