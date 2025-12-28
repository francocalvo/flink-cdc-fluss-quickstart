-- Real-time revenue analytics per movie
SET 'execution.runtime-mode' = 'streaming';
SET 'execution.checkpointing.mode' = 'EXACTLY_ONCE';
SET 'execution.checkpointing.interval' = '10s';

-- Use Fluss catalog
CREATE CATALOG fluss_catalog WITH (
    'type' = 'fluss',
    'bootstrap.servers' = '192.168.1.4:9123,192.168.1.4:9124'
);
USE CATALOG fluss_catalog;
USE osb_staging;

-- Create materialized view for real-time revenue per movie with batch query support
CREATE TABLE movie_revenue_realtime (
    movie_id BIGINT,
    movie_title STRING,
    total_revenue DECIMAL(15, 2),
    ticket_count BIGINT,
    avg_ticket_price DECIMAL(10, 2),
    scheduled_tickets BIGINT,
    live_tickets BIGINT,
    finished_tickets BIGINT,
    scheduled_revenue DECIMAL(15, 2),
    live_revenue DECIMAL(15, 2),
    finished_revenue DECIMAL(15, 2),
    start_date TIMESTAMP(3),
    duration_minutes INT,
    last_ticket_purchased TIMESTAMP(3),
    PRIMARY KEY (movie_id) NOT ENFORCED
) WITH (
    'bucket.num' = '4',
    'table.datalake.enabled' = 'true',
    'table.datalake.freshness' = '10s'
);

-- Continuous query to aggregate revenue by movie with status breakdown
INSERT INTO movie_revenue_realtime
SELECT
    t.movie_id,
    m.title as movie_title,
    SUM(t.cost) as total_revenue,
    COUNT(*) as ticket_count,
    AVG(t.cost) as avg_ticket_price,
    SUM(CASE WHEN t.status = 'scheduled' THEN 1 ELSE 0 END) as scheduled_tickets,
    SUM(CASE WHEN t.status = 'live' THEN 1 ELSE 0 END) as live_tickets,
    SUM(CASE WHEN t.status = 'finished' THEN 1 ELSE 0 END) as finished_tickets,
    SUM(CASE WHEN t.status = 'scheduled' THEN t.cost ELSE 0 END) as scheduled_revenue,
    SUM(CASE WHEN t.status = 'live' THEN t.cost ELSE 0 END) as live_revenue,
    SUM(CASE WHEN t.status = 'finished' THEN t.cost ELSE 0 END) as finished_revenue,
    m.start_date,
    m.duration_minutes,
    MAX(t.purchased_at) as last_ticket_purchased
FROM tickets_staging t
JOIN movies_staging m ON t.movie_id = m.movie_id
GROUP BY t.movie_id, m.title, m.start_date, m.duration_minutes;
