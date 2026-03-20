-- Run streaming job + checkpointing for EOS
SET 'execution.runtime-mode' = 'streaming';
SET 'execution.checkpointing.mode' = 'EXACTLY_ONCE';
SET 'execution.checkpointing.interval' = '5s';
SET 'execution.checkpointing.max-concurrent-checkpoints' = '1';
SET 'state.checkpoints.dir' = '__CHECKPOINTS_DIR__/selections-cdc';

-- 1) Fluss catalog (point to coordinator+tablet; Fluss supports comma-separated bootstrap servers)
CREATE CATALOG fluss_catalog WITH (
    'type' = 'fluss',
    'bootstrap.servers' = '192.168.1.202:9123'
);
USE CATALOG fluss_catalog;

CREATE DATABASE IF NOT EXISTS osb_staging;
USE osb_staging;

-- 2) Fluss staging table (append-only log table)
CREATE TABLE IF NOT EXISTS selections_staging (
    id STRING,
    showing_id STRING,
    product_id STRING,
    status STRING,
    base_price BIGINT,
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
CREATE TEMPORARY TABLE pg_osb_selections (
  id STRING,
  showing_id STRING,
  product_id STRING,
  status STRING,
  base_price BIGINT,
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
  'table-name' = 'selections',
  'slot.name' = 'cdc_osb_selections_to_fluss',
  'decoding.plugin.name' = 'pgoutput',
  'scan.incremental.snapshot.enabled' = 'true'
);

-- 4) Start the replication stream into Fluss
INSERT INTO selections_staging
SELECT
    id,
    showing_id,
    product_id,
    status,
    base_price,
    created_at,
    updated_at
FROM
    pg_osb_selections;