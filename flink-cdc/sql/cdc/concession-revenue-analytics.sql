-- Layer 3B: Concession Revenue Analytics - Simple aggregation from concession_items
SET 'execution.runtime-mode' = 'streaming';
SET 'execution.checkpointing.mode' = 'EXACTLY_ONCE';
SET 'execution.checkpointing.interval' = '10s';

-- Event time processing optimization
SET 'table.exec.emit.early-fire.enabled' = 'true';
SET 'table.exec.emit.early-fire.delay' = '1s';
SET 'table.optimizer.agg-phase-strategy' = 'TWO_PHASE';
SET 'table.exec.mini-batch.enabled' = 'true';
SET 'table.exec.mini-batch.allow-latency' = '1s';
SET 'table.exec.mini-batch.size' = '500';

-- Use Fluss catalog
CREATE CATALOG fluss_catalog WITH (
    'type' = 'fluss',
    'bootstrap.servers' = '192.168.1.202:9123'
);
USE CATALOG fluss_catalog;

CREATE DATABASE IF NOT EXISTS osb_staging;
USE osb_staging;

-- Concession revenue analytics by product
CREATE TABLE concession_revenue_analytics (
    product_id STRING,
    product_name STRING,
    product_category STRING,

    -- Total metrics
    total_revenue DECIMAL(15, 2),
    total_items BIGINT,
    unique_tickets BIGINT,
    unique_users BIGINT,
    avg_revenue_per_ticket DECIMAL(10, 2),
    avg_revenue_per_item DECIMAL(10, 2),

    -- Revenue by ticket status
    scheduled_ticket_revenue DECIMAL(15, 2),
    live_ticket_revenue DECIMAL(15, 2),
    finished_ticket_revenue DECIMAL(15, 2),

    -- Counts by status
    scheduled_tickets BIGINT,
    live_tickets BIGINT,
    finished_tickets BIGINT,

    -- Temporal metrics
    last_purchase TIMESTAMP(3),
    last_updated TIMESTAMP(3),
    WATERMARK FOR last_updated AS last_updated - INTERVAL '5' SECOND,

    PRIMARY KEY (product_id) NOT ENFORCED
) WITH (
    'bucket.num' = '4',
    'table.datalake.enabled' = 'true',
    'table.datalake.freshness' = '60s'
);

-- Aggregate concession revenue by product
INSERT INTO concession_revenue_analytics
SELECT
    product_id,
    product_name,
    product_category,

    -- Total metrics
    SUM(final_price) / 100.0 as total_revenue, -- Convert from cents to dollars
    COUNT(*) as total_items,
    COUNT(DISTINCT ticket_id) as unique_tickets,
    COUNT(DISTINCT user_id) as unique_users,
    SUM(final_price) / COUNT(DISTINCT ticket_id) / 100.0 as avg_revenue_per_ticket,
    AVG(final_price) / 100.0 as avg_revenue_per_item,

    -- Revenue by ticket status
    SUM(CASE WHEN ticket_status = 'scheduled' THEN final_price ELSE 0 END) / 100.0 as scheduled_ticket_revenue,
    SUM(CASE WHEN ticket_status = 'live' THEN final_price ELSE 0 END) / 100.0 as live_ticket_revenue,
    SUM(CASE WHEN ticket_status = 'finished' THEN final_price ELSE 0 END) / 100.0 as finished_ticket_revenue,

    -- Counts by status
    COUNT(DISTINCT CASE WHEN ticket_status = 'scheduled' THEN ticket_id END) as scheduled_tickets,
    COUNT(DISTINCT CASE WHEN ticket_status = 'live' THEN ticket_id END) as live_tickets,
    COUNT(DISTINCT CASE WHEN ticket_status = 'finished' THEN ticket_id END) as finished_tickets,

    -- Temporal metrics
    MAX(ticket_created_at) as last_purchase,
    MAX(item_updated_at) as last_updated

FROM concession_items
GROUP BY product_id, product_name, product_category;
