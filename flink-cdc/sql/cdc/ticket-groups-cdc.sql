-- Run streaming job + checkpointing for EOS
SET 'execution.runtime-mode' = 'streaming';
SET 'execution.checkpointing.mode' = 'EXACTLY_ONCE';
SET 'execution.checkpointing.interval' = '5s';
SET 'execution.checkpointing.max-concurrent-checkpoints' = '1';
SET 'state.checkpoints.dir' = '__CHECKPOINTS_DIR__/ticket-groups-cdc';

-- 1) Fluss catalog (point to coordinator+tablet; Fluss supports comma-separated bootstrap servers)
CREATE CATALOG fluss_catalog WITH (
    'type' = 'fluss',
    'bootstrap.servers' = '192.168.1.202:9123'
);
USE CATALOG fluss_catalog;

CREATE DATABASE IF NOT EXISTS osb_staging;
USE osb_staging;

-- 2) Fluss staging table (append-only log table)
CREATE TABLE IF NOT EXISTS ticket_groups_staging (
    id STRING,
    ticket_id STRING,
    group_type STRING,
    discount_rate DECIMAL(5,4),
    created_at TIMESTAMP(3),
    updated_at TIMESTAMP(3),
    WATERMARK FOR updated_at AS updated_at - INTERVAL '5' SECOND,
    PRIMARY KEY (id) NOT ENFORCED
)
WITH (
    'bucket.num' = '4',
    'table.datalake.enabled' = 'true',
    'table.datalake.freshness' = '60s'
);

-- 3) Postgres CDC source (Flink CDC SQL connector)
CREATE TEMPORARY TABLE pg_osb_ticket_groups (
  id STRING,
  ticket_id STRING,
  group_type STRING,
  discount_rate DECIMAL(5,4),
  created_at TIMESTAMP(3),
  updated_at TIMESTAMP(3),
  WATERMARK FOR updated_at AS updated_at - INTERVAL '5' SECOND,
  PRIMARY KEY (id) NOT ENFORCED
) WITH (
  'connector' = 'postgres-cdc',
  'hostname' = '192.168.1.202',
  'port' = '5432',
  'username' = 'root',
  'password' = 'root',
  'database-name' = 'source_db',
  'schema-name' = 'osb',
  'table-name' = 'ticket_groups',
  'slot.name' = 'cdc_osb_ticket_groups_to_fluss',
  'decoding.plugin.name' = 'pgoutput',
  'scan.incremental.snapshot.enabled' = 'true'
);

-- 4) Start the replication stream into Fluss
INSERT INTO ticket_groups_staging
SELECT
    id,
    ticket_id,
    group_type,
    discount_rate,
    created_at,
    updated_at
FROM
    pg_osb_ticket_groups;
