-- Setup Fluss Staging Tables for YAML CDC Pipeline
SET 'execution.runtime-mode' = 'streaming';

-- Fluss catalog
CREATE CATALOG fluss_catalog WITH (
    'type' = 'fluss',
    'bootstrap.servers' = '192.168.1.202:9123'
);
USE CATALOG fluss_catalog;

CREATE DATABASE IF NOT EXISTS osb_staging;
USE osb_staging;

-- Users staging table
CREATE TABLE IF NOT EXISTS users_staging (
    user_id STRING,
    username STRING,
    email STRING,
    full_name STRING,
    created_at TIMESTAMP(3),
    WATERMARK FOR created_at AS created_at - INTERVAL '5' SECOND,
    PRIMARY KEY (user_id) NOT ENFORCED
) WITH (
    'bucket.num' = '4',
    'table.datalake.enabled' = 'true',
    'table.datalake.freshness' = '60s'
);

-- Movies staging table
CREATE TABLE IF NOT EXISTS movies_staging (
    id STRING,
    title STRING,
    description STRING,
    duration_minutes INT,
    created_at TIMESTAMP(3),
    WATERMARK FOR created_at AS created_at - INTERVAL '5' SECOND,
    PRIMARY KEY (id) NOT ENFORCED
) WITH (
    'bucket.num' = '4',
    'table.datalake.enabled' = 'true',
    'table.datalake.freshness' = '60s'
);

-- Products staging table
CREATE TABLE IF NOT EXISTS products_staging (
    id STRING,
    name STRING,
    category STRING,
    created_at TIMESTAMP(3),
    WATERMARK FOR created_at AS created_at - INTERVAL '5' SECOND,
    PRIMARY KEY (id) NOT ENFORCED
) WITH (
    'bucket.num' = '4',
    'table.datalake.enabled' = 'true',
    'table.datalake.freshness' = '60s'
);

-- Showings staging table
CREATE TABLE IF NOT EXISTS showings_staging (
    id STRING,
    movie_id STRING,
    room_number INT,
    start_time TIMESTAMP(3),
    status STRING,
    updated_at TIMESTAMP(3),
    WATERMARK FOR updated_at AS updated_at - INTERVAL '5' SECOND,
    PRIMARY KEY (id) NOT ENFORCED
) WITH (
    'bucket.num' = '4',
    'table.datalake.enabled' = 'true',
    'table.datalake.freshness' = '60s'
);

-- Selections staging table
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
) WITH (
    'bucket.num' = '4',
    'table.datalake.enabled' = 'true',
    'table.datalake.freshness' = '60s'
);

-- Tickets staging table
CREATE TABLE IF NOT EXISTS tickets_staging (
    id STRING,
    user_id STRING,
    status STRING,
    entry_amount BIGINT,
    status_updated_at TIMESTAMP(3),
    created_at TIMESTAMP(3),
    updated_at TIMESTAMP(3),
    deleted_at TIMESTAMP(3),
    WATERMARK FOR updated_at AS updated_at - INTERVAL '5' SECOND,
    PRIMARY KEY (id) NOT ENFORCED
) WITH (
    'bucket.num' = '4',
    'table.datalake.enabled' = 'true',
    'table.datalake.freshness' = '60s'
);

-- Ticket groups staging table
CREATE TABLE IF NOT EXISTS ticket_groups_staging (
    id STRING,
    ticket_id STRING,
    group_type STRING,
    discount_rate DECIMAL(5,4),
    created_at TIMESTAMP(3),
    updated_at TIMESTAMP(3),
    WATERMARK FOR updated_at AS updated_at - INTERVAL '5' SECOND,
    PRIMARY KEY (id) NOT ENFORCED
) WITH (
    'bucket.num' = '4',
    'table.datalake.enabled' = 'true',
    'table.datalake.freshness' = '60s'
);

-- Item assignments staging table
CREATE TABLE IF NOT EXISTS item_assignments_staging (
    id STRING,
    ticket_id STRING,
    ticket_group_id STRING,
    selection_id STRING,
    final_price BIGINT,
    created_at TIMESTAMP(3),
    updated_at TIMESTAMP(3),
    WATERMARK FOR updated_at AS updated_at - INTERVAL '5' SECOND,
    PRIMARY KEY (id) NOT ENFORCED
) WITH (
    'bucket.num' = '4',
    'table.datalake.enabled' = 'true',
    'table.datalake.freshness' = '60s'
);