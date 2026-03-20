#!/bin/bash
set -euo pipefail

echo "🚀 Starting CDC Pipeline Deployment..."

# Load CHECKPOINTS_DIR from .env
if [ -f .env ]; then
    CHECKPOINTS_DIR=$(grep '^CHECKPOINTS_DIR=' .env | cut -d'=' -f2)
fi
if [ -z "${CHECKPOINTS_DIR:-}" ]; then
    echo "❌ ERROR: CHECKPOINTS_DIR not found in .env"
    exit 1
fi

# Function to run SQL file, replacing __CHECKPOINTS_DIR__ placeholder
run_sql() {
    local sql_file="$1"
    echo "▶️  Executing: $sql_file"
    local tmp_file="/tmp/flink-sql-$$-${sql_file}"
    sed "s|__CHECKPOINTS_DIR__|${CHECKPOINTS_DIR}|g" \
        "flink-cdc/sql/cdc/$sql_file" > "$tmp_file"
    docker cp "$tmp_file" flink-sql-client:"/opt/flink/sql/cdc/$sql_file"
    rm -f "$tmp_file"
    docker exec flink-sql-client \
        /opt/flink/bin/sql-client.sh -f "/opt/flink/sql/cdc/$sql_file"
    echo "✅ Completed: $sql_file"
}

echo ""
echo "📊 Stage 1: Core Table Replication (FlinkSQL)"
echo "============================================="

# Core table replication (sequential to minimize replication slot usage)
echo "🔄 Starting sequential CDC jobs..."

run_sql "users-cdc.sql"
run_sql "movies-cdc.sql"
run_sql "products-cdc.sql"
run_sql "showings-cdc.sql"
run_sql "selections-cdc.sql"
run_sql "tickets-cdc.sql"
run_sql "ticket-groups-cdc.sql"
run_sql "item-assignments-cdc.sql"

echo "✅ Core replication completed!"
echo "😴 Pausing 5 seconds for Fluss tables to be ready..."
sleep 5

echo ""
echo "📈 Stage 2: Intermediate Tables"
echo "==============================="

# Build intermediate tables (sequential - depends on core tables)
run_sql "enriched-items.sql"
run_sql "movie-items.sql"
run_sql "concession-items.sql"

echo ""
echo "📊 Stage 3: Analytics Tables"
echo "============================"

# Analytics tables (can run in parallel - depend on intermediates)
run_sql "movie-revenue-analytics.sql" &
run_sql "concession-revenue-analytics.sql" &
run_sql "overall-revenue-analytics.sql" &

echo "⏳ Waiting for analytics to complete..."
wait

echo ""
echo "🎉 CDC Pipeline Deployment Complete!"
echo "====================================="
echo ""
echo "📋 Pipeline Summary:"
echo "- Core Tables: Unified CDC pipeline (1 replication slot)"
echo "- Intermediate Tables: enriched_item_assignments, movie_items, concession_items"
echo "- Analytics Tables: movie_revenue_analytics, concession_revenue_analytics, overall_revenue_analytics"
echo ""
echo "💡 To view running Flink jobs:"
echo "   docker exec flink-jobmanager /opt/flink/bin/flink list"

