-- Layer 3C: Overall Revenue Analytics - Combined movie + concession revenue
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

-- Overall revenue analytics - high-level business metrics
CREATE TABLE overall_revenue_analytics (
    metric_date DATE,

    -- Total revenue breakdown
    total_revenue DECIMAL(15, 2),
    movie_revenue DECIMAL(15, 2),
    concession_revenue DECIMAL(15, 2),
    concession_revenue_percentage DECIMAL(5, 2),

    -- Volume metrics
    total_tickets BIGINT,
    total_items BIGINT,
    movie_items BIGINT,
    concession_items BIGINT,
    unique_users BIGINT,

    -- Average metrics
    avg_revenue_per_ticket DECIMAL(10, 2),
    avg_movie_revenue_per_ticket DECIMAL(10, 2),
    avg_concession_revenue_per_ticket DECIMAL(10, 2),
    avg_items_per_ticket DECIMAL(8, 2),

    -- Revenue by status
    scheduled_revenue DECIMAL(15, 2),
    live_revenue DECIMAL(15, 2),
    finished_revenue DECIMAL(15, 2),

    -- Top categories
    top_movie_title STRING,
    top_movie_revenue DECIMAL(15, 2),
    top_concession_category STRING,
    top_concession_category_revenue DECIMAL(15, 2),

    -- Temporal
    last_updated TIMESTAMP(3),
    WATERMARK FOR last_updated AS last_updated - INTERVAL '5' SECOND,

    PRIMARY KEY (metric_date) NOT ENFORCED
) WITH (
    'bucket.num' = '2',
    'table.datalake.enabled' = 'true',
    'table.datalake.freshness' = '60s'
);

-- Aggregate daily revenue metrics from enriched items
INSERT INTO overall_revenue_analytics
SELECT
    CAST(item_updated_at AS DATE) as metric_date,

    -- Total revenue breakdown
    SUM(final_price) / 100.0 as total_revenue,
    SUM(CASE WHEN item_type = 'movie_ticket' THEN final_price ELSE 0 END) / 100.0 as movie_revenue,
    SUM(CASE WHEN item_type = 'concession' THEN final_price ELSE 0 END) / 100.0 as concession_revenue,
    (SUM(CASE WHEN item_type = 'concession' THEN final_price ELSE 0 END) * 100.0 /
     NULLIF(SUM(final_price), 0)) as concession_revenue_percentage,

    -- Volume metrics
    COUNT(DISTINCT ticket_id) as total_tickets,
    COUNT(*) as total_items,
    COUNT(CASE WHEN item_type = 'movie_ticket' THEN 1 END) as movie_items,
    COUNT(CASE WHEN item_type = 'concession' THEN 1 END) as concession_items,
    COUNT(DISTINCT user_id) as unique_users,

    -- Average metrics
    SUM(final_price) / COUNT(DISTINCT ticket_id) / 100.0 as avg_revenue_per_ticket,
    SUM(CASE WHEN item_type = 'movie_ticket' THEN final_price ELSE 0 END) /
        NULLIF(COUNT(DISTINCT CASE WHEN item_type = 'movie_ticket' THEN ticket_id END), 0) / 100.0 as avg_movie_revenue_per_ticket,
    SUM(CASE WHEN item_type = 'concession' THEN final_price ELSE 0 END) /
        NULLIF(COUNT(DISTINCT CASE WHEN item_type = 'concession' THEN ticket_id END), 0) / 100.0 as avg_concession_revenue_per_ticket,
    COUNT(*) * 1.0 / COUNT(DISTINCT ticket_id) as avg_items_per_ticket,

    -- Revenue by status
    SUM(CASE WHEN ticket_status = 'scheduled' THEN final_price ELSE 0 END) / 100.0 as scheduled_revenue,
    SUM(CASE WHEN ticket_status = 'live' THEN final_price ELSE 0 END) / 100.0 as live_revenue,
    SUM(CASE WHEN ticket_status = 'finished' THEN final_price ELSE 0 END) / 100.0 as finished_revenue,

    -- Top performers (simplified - would need window functions for proper ranking)
    FIRST_VALUE(movie_title) as top_movie_title,
    MAX(CASE WHEN item_type = 'movie_ticket' THEN final_price ELSE 0 END) / 100.0 as top_movie_revenue,
    FIRST_VALUE(product_category) as top_concession_category,
    MAX(CASE WHEN item_type = 'concession' THEN final_price ELSE 0 END) / 100.0 as top_concession_category_revenue,

    -- Temporal
    MAX(item_updated_at) as last_updated

FROM enriched_item_assignments
GROUP BY CAST(item_updated_at AS DATE);
