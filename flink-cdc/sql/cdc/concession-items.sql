-- Layer 2B: Concession Items - Filtered view of concession/product purchases only
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

-- Concession items table - optimized for concession revenue analytics
CREATE TABLE concession_items (
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

    -- Product context
    product_id STRING,
    product_name STRING,
    product_category STRING,

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

-- Populate concession items from enriched items
INSERT INTO concession_items
SELECT
    item_id,
    ticket_id,
    selection_id,

    final_price,
    base_price,
    discount_rate,

    user_id,
    ticket_status,

    product_id,
    product_name,
    product_category,

    item_created_at,
    item_updated_at,
    ticket_created_at,
    ticket_status_updated_at

FROM enriched_item_assignments
WHERE item_type = 'concession'
  AND product_id IS NOT NULL;
