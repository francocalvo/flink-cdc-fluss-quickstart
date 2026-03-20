-- Layer 3A: Movie Revenue Analytics - Simple aggregation from movie_items
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

-- Movie revenue analytics - aggregated from movie_items
CREATE TABLE movie_revenue_analytics (
    movie_id STRING,
    movie_title STRING,
    duration_minutes INT,

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

    -- Revenue by showing status
    scheduled_showing_revenue DECIMAL(15, 2),
    live_showing_revenue DECIMAL(15, 2),
    finished_showing_revenue DECIMAL(15, 2),

    -- Counts by status
    scheduled_tickets BIGINT,
    live_tickets BIGINT,
    finished_tickets BIGINT,
    scheduled_showings BIGINT,
    live_showings BIGINT,
    finished_showings BIGINT,

    -- Temporal metrics
    last_ticket_purchased TIMESTAMP(3),
    last_updated TIMESTAMP(3),
    WATERMARK FOR last_updated AS last_updated - INTERVAL '5' SECOND,

    PRIMARY KEY (movie_id) NOT ENFORCED
) WITH (
    'bucket.num' = '4',
    'table.datalake.enabled' = 'true',
    'table.datalake.freshness' = '60s'
);

-- Simple aggregation from movie_items intermediate table
INSERT INTO movie_revenue_analytics
SELECT
    movie_id,
    movie_title,
    movie_duration_minutes as duration_minutes,

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

    -- Revenue by showing status
    SUM(CASE WHEN showing_status = 'scheduled' THEN final_price ELSE 0 END) / 100.0 as scheduled_showing_revenue,
    SUM(CASE WHEN showing_status = 'live' THEN final_price ELSE 0 END) / 100.0 as live_showing_revenue,
    SUM(CASE WHEN showing_status = 'finished' THEN final_price ELSE 0 END) / 100.0 as finished_showing_revenue,

    -- Counts by status
    COUNT(DISTINCT CASE WHEN ticket_status = 'scheduled' THEN ticket_id END) as scheduled_tickets,
    COUNT(DISTINCT CASE WHEN ticket_status = 'live' THEN ticket_id END) as live_tickets,
    COUNT(DISTINCT CASE WHEN ticket_status = 'finished' THEN ticket_id END) as finished_tickets,
    COUNT(DISTINCT CASE WHEN showing_status = 'scheduled' THEN showing_id END) as scheduled_showings,
    COUNT(DISTINCT CASE WHEN showing_status = 'live' THEN showing_id END) as live_showings,
    COUNT(DISTINCT CASE WHEN showing_status = 'finished' THEN showing_id END) as finished_showings,

    -- Temporal metrics
    MAX(ticket_created_at) as last_ticket_purchased,
    MAX(item_updated_at) as last_updated

FROM movie_items
GROUP BY movie_id, movie_title, movie_duration_minutes;
