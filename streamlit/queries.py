"""SQL queries for the dashboard."""

import config

# Catalog creation query (must be executed first)
CREATE_CATALOG_QUERY = f"""
CREATE CATALOG IF NOT EXISTS fluss_catalog WITH (
    'type' = 'fluss',
    'bootstrap.servers' = '{config.FLUSS_BOOTSTRAP_SERVER}'
)
"""

# Session configuration queries
CATALOG_CONFIG = "USE CATALOG fluss_catalog"
DATABASE_CONFIG = "USE osb_staging"

# Query 1: Revenue Breakdown by Minute (last 30 minutes)
# Note: final_price is stored in cents (BIGINT), divide by 100 for dollars
# Sorting done in frontend (ORDER BY not supported in Flink streaming)
DAILY_REVENUE_QUERY = """
SELECT
    DATE_FORMAT(t.created_at, 'yyyy-MM-dd HH:mm:00') as revenue_date,
    CAST(SUM(ia.final_price) AS DOUBLE) / 100.0 as total_revenue,
    CAST(SUM(CASE WHEN s.showing_id IS NOT NULL THEN ia.final_price ELSE 0 END) AS DOUBLE) / 100.0 as ticket_revenue,
    CAST(SUM(CASE WHEN s.product_id IS NOT NULL THEN ia.final_price ELSE 0 END) AS DOUBLE) / 100.0 as concession_revenue
FROM item_assignments_staging ia
JOIN selections_staging s ON ia.selection_id = s.id
JOIN tickets_staging t ON ia.ticket_id = t.id
WHERE t.deleted_at IS NULL
    AND t.created_at >= CURRENT_TIMESTAMP - INTERVAL '30' MINUTE
GROUP BY DATE_FORMAT(t.created_at, 'yyyy-MM-dd HH:mm:00')
"""

# Query 2: Revenue per Live Showing
# Sorting done in frontend
LIVE_SHOWINGS_QUERY = """
SELECT
    sh.id as showing_id,
    m.title as movie_title,
    sh.room_number,
    sh.start_time,
    CAST(COALESCE(SUM(ia.final_price), 0) AS DOUBLE) / 100.0 as total_revenue,
    CAST(COUNT(DISTINCT CASE WHEN s.showing_id IS NOT NULL THEN t.id END) AS BIGINT) as ticket_count,
    'live' as status
FROM showings_staging sh
JOIN movies_staging m ON sh.movie_id = m.id
LEFT JOIN selections_staging s ON s.showing_id = sh.id
LEFT JOIN item_assignments_staging ia ON ia.selection_id = s.id
LEFT JOIN tickets_staging t ON ia.ticket_id = t.id AND t.deleted_at IS NULL
WHERE sh.status = 'live'
GROUP BY sh.id, m.title, sh.room_number, sh.start_time
"""

# Query 3: Revenue per Finished Showing
# Sorting done in frontend
# end_time calculated in frontend (interval arithmetic complex in streaming)
FINISHED_SHOWINGS_QUERY = """
SELECT
    sh.id as showing_id,
    m.title as movie_title,
    sh.room_number,
    sh.start_time,
    m.duration_minutes,
    CAST(COALESCE(SUM(ia.final_price), 0) AS DOUBLE) / 100.0 as total_revenue,
    CAST(COUNT(DISTINCT CASE WHEN s.showing_id IS NOT NULL THEN t.id END) AS BIGINT) as ticket_count,
    'finished' as status
FROM showings_staging sh
JOIN movies_staging m ON sh.movie_id = m.id
LEFT JOIN selections_staging s ON s.showing_id = sh.id
LEFT JOIN item_assignments_staging ia ON ia.selection_id = s.id
LEFT JOIN tickets_staging t ON ia.ticket_id = t.id AND t.deleted_at IS NULL
WHERE sh.status = 'finished'
GROUP BY sh.id, m.title, sh.room_number, sh.start_time, m.duration_minutes
"""

# Query 4: Revenue per Scheduled Showing
# Sorting done in frontend
SCHEDULED_SHOWINGS_QUERY = """
SELECT
    sh.id as showing_id,
    m.title as movie_title,
    sh.room_number,
    sh.start_time as scheduled_time,
    CAST(COALESCE(SUM(ia.final_price), 0) AS DOUBLE) / 100.0 as presale_revenue,
    CAST(COUNT(DISTINCT CASE WHEN s.showing_id IS NOT NULL THEN t.id END) AS BIGINT) as ticket_count,
    'scheduled' as status
FROM showings_staging sh
JOIN movies_staging m ON sh.movie_id = m.id
LEFT JOIN selections_staging s ON s.showing_id = sh.id
LEFT JOIN item_assignments_staging ia ON ia.selection_id = s.id
LEFT JOIN tickets_staging t ON ia.ticket_id = t.id AND t.deleted_at IS NULL
WHERE sh.status = 'scheduled'
GROUP BY sh.id, m.title, sh.room_number, sh.start_time
"""

# Key columns for state management (used for upsert logic)
QUERY_KEY_COLUMNS = {
    "daily_revenue": ["revenue_date"],
    "live_showings": ["showing_id"],
    "finished_showings": ["showing_id"],
    "scheduled_showings": ["showing_id"],
}

# Display limits for each query
QUERY_LIMITS = {
    "daily_revenue": 30,  # Last 30 days
    "live_showings": 10,  # Top 10 by revenue
    "finished_showings": 10,  # Latest 10
    "scheduled_showings": 10,  # Next 10
}
