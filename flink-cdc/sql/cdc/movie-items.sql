-- Layer 2A: Movie Items - Filtered view of movie ticket purchases only
SET 'execution.runtime-mode' = 'streaming';
SET 'execution.checkpointing.mode' = 'EXACTLY_ONCE';
SET 'execution.checkpointing.interval' = '5s';

-- Use Fluss catalog
CREATE CATALOG fluss_catalog WITH (
    'type' = 'fluss',
    'bootstrap.servers' = '192.168.1.202:9123'
);
USE CATALOG fluss_catalog;
CREATE DATABASE IF NOT EXISTS osb_staging;
USE osb_staging;

-- Movie items table - optimized for movie revenue analytics
CREATE TABLE movie_items (
    -- Item identifiers
    item_id STRING,
    ticket_id STRING,
    selection_id STRING,

    -- Financial data
    final_price BIGINT,
    base_price BIGINT,
    discount_rate DECIMAL(5,4),

    -- Ticket context
    user_id STRING,
    ticket_status STRING,

    -- Movie context
    movie_id STRING,
    movie_title STRING,
    movie_duration_minutes INT,
    showing_id STRING,
    room_number INT,
    start_time TIMESTAMP(3),
    showing_status STRING,

    -- Temporal data
    item_created_at TIMESTAMP(3),
    item_updated_at TIMESTAMP(3),
    ticket_created_at TIMESTAMP(3),
    ticket_status_updated_at TIMESTAMP(3),

    WATERMARK FOR item_updated_at AS item_updated_at - INTERVAL '5' SECOND,
    PRIMARY KEY (item_id) NOT ENFORCED
) WITH (
    'bucket.num' = '4',
    'table.datalake.enabled' = 'true',
    'table.datalake.freshness' = '30s'
);

-- Populate movie items from enriched items
INSERT INTO movie_items
SELECT
    item_id,
    ticket_id,
    selection_id,

    final_price,
    base_price,
    discount_rate,

    user_id,
    ticket_status,

    movie_id,
    movie_title,
    movie_duration_minutes,
    showing_id,
    room_number,
    start_time,
    showing_status,

    item_created_at,
    item_updated_at,
    ticket_created_at,
    ticket_status_updated_at

FROM enriched_item_assignments
WHERE item_type = 'movie_ticket'
  AND movie_id IS NOT NULL;
