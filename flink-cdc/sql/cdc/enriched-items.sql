-- Layer 1: Enriched Item Assignments - Denormalized view of all purchase items
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

-- Enriched item assignments with all context
CREATE TABLE enriched_item_assignments (
    -- Item identifiers
    item_id STRING,
    ticket_id STRING,
    ticket_group_id STRING,
    selection_id STRING,

    -- Financial data
    final_price BIGINT,
    base_price BIGINT,
    discount_rate DECIMAL(5,4),
    group_type STRING,

    -- Ticket context
    user_id STRING,
    ticket_status STRING,
    ticket_entry_amount BIGINT,

    -- Item category (movie vs concession)
    item_type STRING, -- 'movie_ticket' or 'concession'

    -- Movie context (NULL for concessions)
    movie_id STRING,
    movie_title STRING,
    movie_duration_minutes INT,
    showing_id STRING,
    room_number INT,
    start_time TIMESTAMP(3),
    showing_status STRING,

    -- Product context (NULL for movie tickets)
    product_id STRING,
    product_name STRING,
    product_category STRING,

    -- Temporal data
    item_created_at TIMESTAMP(3),
    item_updated_at TIMESTAMP(3),
    ticket_created_at TIMESTAMP(3),
    ticket_updated_at TIMESTAMP(3),
    ticket_status_updated_at TIMESTAMP(3),

    WATERMARK FOR item_updated_at AS item_updated_at - INTERVAL '5' SECOND,
    PRIMARY KEY (item_id) NOT ENFORCED
) WITH (
    'bucket.num' = '8',
    'table.datalake.enabled' = 'true',
    'table.datalake.freshness' = '30s'
);

-- Populate enriched items with full context
INSERT INTO enriched_item_assignments
SELECT
    -- Item identifiers
    ia.id as item_id,
    ia.ticket_id,
    ia.ticket_group_id,
    ia.selection_id,

    -- Financial data
    ia.final_price,
    sel.base_price,
    COALESCE(tg.discount_rate, 0) as discount_rate,
    tg.group_type,

    -- Ticket context
    t.user_id,
    t.status as ticket_status,
    t.entry_amount as ticket_entry_amount,

    -- Item category
    CASE
        WHEN sel.showing_id IS NOT NULL THEN 'movie_ticket'
        WHEN sel.product_id IS NOT NULL THEN 'concession'
        ELSE 'unknown'
    END as item_type,

    -- Movie context (NULL for concessions)
    m.id as movie_id,
    m.title as movie_title,
    m.duration_minutes as movie_duration_minutes,
    s.id as showing_id,
    s.room_number,
    s.start_time,
    s.status as showing_status,

    -- Product context (NULL for movie tickets)
    p.id as product_id,
    p.name as product_name,
    p.category as product_category,

    -- Temporal data
    ia.created_at as item_created_at,
    ia.updated_at as item_updated_at,
    t.created_at as ticket_created_at,
    t.updated_at as ticket_updated_at,
    t.status_updated_at as ticket_status_updated_at

FROM item_assignments_staging ia
JOIN tickets_staging t ON ia.ticket_id = t.id
JOIN selections_staging sel ON ia.selection_id = sel.id
LEFT JOIN ticket_groups_staging tg ON ia.ticket_group_id = tg.id

-- Join movie context (for movie tickets)
LEFT JOIN showings_staging s ON sel.showing_id = s.id
LEFT JOIN movies_staging m ON s.movie_id = m.id

-- Join product context (for concessions)
LEFT JOIN products_staging p ON sel.product_id = p.id

WHERE t.deleted_at IS NULL; -- Exclude deleted tickets
