# Streamlit Dashboard Plan for Flink SQL Gateway

## Overview
Build a real-time Streamlit dashboard that connects to Flink SQL Gateway to visualize cinema revenue data with live updates.

## Database Schema Understanding

### Core Tables
1. **osb.tickets** - Main transaction table
   - `id`: Primary key
   - `user_id`: Reference to user
   - `status`: 'scheduled', 'live', 'finished'
   - `entry_amount`: Base ticket price
   - `status_updated_at`: When status changed
   - `created_at`, `updated_at`, `deleted_at`: Timestamps

2. **osb.showings** - Movie screening schedule
   - `id`: Primary key
   - `movie_id`: Reference to movie
   - `room_number`: Cinema room
   - `start_time`: When showing starts
   - `status`: 'scheduled', 'live', 'finished', 'cancelled'

3. **osb.selections** - Available items for purchase
   - `id`: Primary key
   - `showing_id`: Link to showing (for movie tickets)
   - `product_id`: Link to product (for concessions)
   - `base_price`: Item price
   - `status`: Availability state

4. **osb.item_assignments** - Actual purchased items
   - `id`: Primary key
   - `ticket_id`: Reference to ticket
   - `selection_id`: What was purchased
   - `final_price`: Actual price paid (after discounts)

5. **osb.products** - Concessions catalog
   - `id`: Primary key
   - `name`: Product name
   - `category`: 'concessions', 'merchandise'

6. **osb.movies** - Movie metadata
   - `id`: Primary key
   - `title`: Movie title
   - `duration_minutes`: Movie length

## Dashboard Requirements

### 1. Line Chart - Daily Revenue Trends
- **X-axis**: Date
- **Y-axis**: Revenue amount
- **Lines**:
  - Total revenue (all item_assignments)
  - Show ticket revenue (selections with showing_id)
  - Candy/concessions revenue (selections with product_id)
- **Update**: Every second with new data

### 2. Live Tables (Update per second)

#### Table 1: Revenue per Live Showing
- Columns: Movie Title, Room, Start Time, Total Revenue
- Filter: showings.status = 'live'
- Sort: By total revenue descending

#### Table 2: Revenue per Finished Showing
- Columns: Movie Title, Room, Start Time, End Time, Total Revenue
- Filter: showings.status = 'finished'
- Sort: By end time descending (most recent first)

#### Table 3: Revenue per Scheduled Showing
- Columns: Movie Title, Room, Scheduled Time, Pre-sale Revenue
- Filter: showings.status = 'scheduled'
- Sort: By scheduled time ascending (upcoming first)

## Flink SQL Queries

### Query 1: Daily Revenue Breakdown
```sql
SELECT
    DATE(t.created_at) as revenue_date,
    SUM(ia.final_price) as total_revenue,
    SUM(CASE WHEN s.showing_id IS NOT NULL THEN ia.final_price ELSE 0 END) as ticket_revenue,
    SUM(CASE WHEN s.product_id IS NOT NULL THEN ia.final_price ELSE 0 END) as concession_revenue
FROM osb.item_assignments ia
JOIN osb.selections s ON ia.selection_id = s.id
JOIN osb.tickets t ON ia.ticket_id = t.id
WHERE t.deleted_at IS NULL
GROUP BY DATE(t.created_at)
ORDER BY revenue_date DESC
```

### Query 2: Revenue per Live Showing
```sql
SELECT
    m.title as movie_title,
    sh.room_number,
    sh.start_time,
    sh.id as showing_id,
    SUM(ia.final_price) as total_revenue
FROM osb.showings sh
JOIN osb.movies m ON sh.movie_id = m.id
LEFT JOIN osb.selections s ON s.showing_id = sh.id
LEFT JOIN osb.item_assignments ia ON ia.selection_id = s.id
LEFT JOIN osb.tickets t ON ia.ticket_id = t.id
WHERE sh.status = 'live'
  AND (t.deleted_at IS NULL OR t.deleted_at IS NULL)
GROUP BY sh.id, m.title, sh.room_number, sh.start_time
ORDER BY total_revenue DESC
```

### Query 3: Revenue per Finished Showing
```sql
SELECT
    m.title as movie_title,
    sh.room_number,
    sh.start_time,
    sh.start_time + (m.duration_minutes || ' minutes')::interval as end_time,
    sh.id as showing_id,
    SUM(ia.final_price) as total_revenue
FROM osb.showings sh
JOIN osb.movies m ON sh.movie_id = m.id
LEFT JOIN osb.selections s ON s.showing_id = sh.id
LEFT JOIN osb.item_assignments ia ON ia.selection_id = s.id
LEFT JOIN osb.tickets t ON ia.ticket_id = t.id
WHERE sh.status = 'finished'
  AND (t.deleted_at IS NULL OR t.deleted_at IS NULL)
GROUP BY sh.id, m.title, sh.room_number, sh.start_time, m.duration_minutes
ORDER BY sh.start_time DESC
```

### Query 4: Revenue per Scheduled Showing
```sql
SELECT
    m.title as movie_title,
    sh.room_number,
    sh.start_time as scheduled_time,
    sh.id as showing_id,
    COALESCE(SUM(ia.final_price), 0) as presale_revenue
FROM osb.showings sh
JOIN osb.movies m ON sh.movie_id = m.id
LEFT JOIN osb.selections s ON s.showing_id = sh.id
LEFT JOIN osb.item_assignments ia ON ia.selection_id = s.id
LEFT JOIN osb.tickets t ON ia.ticket_id = t.id
WHERE sh.status = 'scheduled'
  AND (t.deleted_at IS NULL OR t.deleted_at IS NULL)
GROUP BY sh.id, m.title, sh.room_number, sh.start_time
ORDER BY sh.start_time ASC
```

## Technical Architecture

### Components
1. **Streamlit App** (`app.py`)
   - Main dashboard with tabs/sections
   - Plotly for line chart
   - Streamlit native tables for live data
   - Auto-refresh mechanism

2. **Flink Gateway Client** (`flink_client.py`)
   - Session management
   - Query execution
   - Result polling with update detection
   - Based on live_query.py patterns

3. **Data Models** (`models.py`)
   - Pydantic models for type safety
   - Revenue data structures
   - Showing information

### Key Implementation Patterns (from live_query.py)

1. **Session Management**
   ```python
   - Open session with gateway
   - Configure session (catalog, database)
   - Execute statement
   - Poll for results using nextResultUri
   - Handle NOT_READY, PAYLOAD, EOS states
   ```

2. **Update Detection**
   - For JSON row format: track changelog kinds (INSERT, UPDATE_AFTER, DELETE)
   - Maintain in-memory state with key-based upsert
   - Only re-render when data changes

3. **Polling Strategy**
   - Poll interval: 250ms when no data
   - Render interval: 800ms minimum between updates
   - Back off when NOT_READY

## Implementation Steps

1. **Phase 1: Core Infrastructure**
   - Set up project structure with uv
   - Create Flink gateway client module
   - Implement session and query management

2. **Phase 2: Data Processing**
   - Create data models for revenue and showings
   - Implement changelog processing for updates
   - Build state management for live updates

3. **Phase 3: Streamlit UI**
   - Create main dashboard layout
   - Implement line chart with Plotly
   - Add three live updating tables
   - Set up auto-refresh mechanism

4. **Phase 4: Polish**
   - Error handling and retry logic
   - Connection status indicator
   - Performance optimization
   - Configuration via environment variables

## Configuration

### Environment Variables
```
FLINK_GATEWAY_URL=http://localhost:8083
FLINK_CATALOG=default_catalog
FLINK_DATABASE=default_database
POLL_INTERVAL_MS=250
RENDER_INTERVAL_MS=800
TABLE_LIMIT=10
```

## Dependencies
- streamlit
- plotly
- pandas
- requests
- pydantic
- python-dateutil

## Testing Approach
1. Mock Flink gateway responses
2. Test changelog processing logic
3. Validate state management
4. UI component testing with different data scenarios

## Deployment Considerations
- Container deployment with Docker
- Health checks for gateway connection
- Graceful shutdown handling
- Resource limits for polling