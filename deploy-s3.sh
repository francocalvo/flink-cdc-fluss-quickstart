#!/bin/bash
set -euo pipefail

# --- Host Configuration ---
REMOTE_SERVER="calvo@192.168.1.202"
REMOTE_DIR="/mefitis/streaming"

echo "🚀 Starting S3 Deployment Script..."

# --- Load S3 Configuration from .env ---
if [ ! -f ".env" ]; then
    echo "❌ ERROR: .env file not found in root directory. Please create it with:"
    echo "S3_DIR=my-bucket/data"
    echo "S3_ACCESS_KEY=your-access-key"
    echo "S3_SECRET_KEY=your-secret-key"
    echo "S3_ENDPOINT=https://s3.amazonaws.com  # optional"
    exit 1
fi

echo "📋 Loading S3 configuration from .env..."
source .env

# Validate required variables
if [ -z "${S3_DIR:-}" ] || [ -z "${S3_ACCESS_KEY:-}" ] || [ -z "${S3_SECRET_KEY:-}" ]; then
    echo "❌ ERROR: Missing required S3 configuration in .env file"
    echo "Required: S3_DIR, S3_ACCESS_KEY, S3_SECRET_KEY"
    exit 1
fi

# Set default S3 endpoint if not provided
S3_ENDPOINT="${S3_ENDPOINT:-https://s3.amazonaws.com}"

# Parse S3_DIR into components
if [[ "$S3_DIR" == *"/"* ]]; then
    S3_BUCKET=$(echo "$S3_DIR" | cut -d'/' -f1)
    S3_PREFIX=$(echo "$S3_DIR" | cut -d'/' -f2-)
    S3_BASE="s3://${S3_BUCKET}/${S3_PREFIX}"
else
    S3_BUCKET="$S3_DIR"
    S3_PREFIX=""
    S3_BASE="s3://${S3_BUCKET}"
fi

echo "🪣 S3 Configuration:"
echo "   Bucket: $S3_BUCKET"
echo "   Prefix: $S3_PREFIX"
echo "   Base Path: $S3_BASE"
echo "   Endpoint: $S3_ENDPOINT"

# Export for use in tiering service
export S3_ACCESS_KEY S3_SECRET_KEY S3_ENDPOINT S3_BASE

echo "📤 0. Syncing Local Changes to Remote Server..."
bash sync.sh

echo "🌐 1. Connecting to $REMOTE_SERVER for Remote Environment Reset..."

ssh -t "$REMOTE_SERVER" "sudo nix-shell -p jq --run '
    cd $REMOTE_DIR
    set -euo pipefail

    echo \"-----------------------------------\"
    echo \"------- SUBSTEP: CLEANUP ----------\"
    echo \"-----------------------------------\"
    echo \"🛑 Stopping all services...\"

    docker compose -f flink-cdc/docker-compose-s3.yaml down -v || true
    docker compose -f fluss/docker-compose-s3.yaml down -v || true
    docker compose -f postgres-catalog/docker-compose.yaml down -v || true
    docker compose -f postgres-source/docker-compose.yaml down -v || true

    echo \"🧹 Pruning Docker volumes...\"
    docker volume prune -f

    echo \"-----------------------------------------\"
    echo \"------- SUBSTEP: DATA DELETION ----------\"
    echo \"-----------------------------------------\"

    echo \"🗑️ Deleting ALL data directories...\"
    # Delete all /data/ directories to ensure complete clean slate
    find . -name \"data\" -type d -exec rm -rf {} +

    echo \"----------------------------------------\"
    echo \"------- SUBSTEP: INFRA REBOOT ----------\"
    echo \"----------------------------------------\"
    echo \"🐘 Starting Foundation: Postgres (Skipping Garage for S3)...\"

    docker compose -f postgres-source/docker-compose.yaml up -d
    docker compose -f postgres-catalog/docker-compose.yaml up -d

    echo \"⏳ Waiting 3s for PostgreSQL services...\"
    sleep 3
'"

echo "📝 2. Updating Docker Compose Files with S3 Configuration..."

# Update S3-specific docker-compose files will be created separately
# For now, we'll use environment variables in the deployment

echo "📤 3. Executing Local Sync and Starting Remote Jobs..."
bash ./sync.sh

ssh -t "$REMOTE_SERVER" "sudo bash -c '
    cd $REMOTE_DIR

    # Set S3 environment variables for the session
    export S3_ACCESS_KEY=\"$S3_ACCESS_KEY\"
    export S3_SECRET_KEY=\"$S3_SECRET_KEY\"
    export S3_ENDPOINT=\"$S3_ENDPOINT\"
    export S3_BASE=\"$S3_BASE\"

    echo \"-------------------------------------------\"
    echo \"------- SUBSTEP: STREAMING LAYER ----------\"
    echo \"-------------------------------------------\"

    echo \"🌊 Starting Fluss & 🐿️ Flink CDC with S3 configuration...\"
    docker compose -f fluss/docker-compose-s3.yaml up -d
    docker compose -f flink-cdc/docker-compose-s3.yaml up -d

    echo \"⏳ Waiting for Flink JobManager to go live...\"
    until curl -s http://localhost:8081/overview > /dev/null; do sleep 2; done

    echo \"--------------------------------------------\"
    echo \"------- SUBSTEP: REPLICATION TASKS ----------\"
    echo \"--------------------------------------------\"
    echo -e \"\n🚀 Running SQL Client: Postgres -> Fluss...\"

    echo \"📊 Starting CDC for users table...\"
    docker exec -it flink-sql-client \\
      /opt/flink/bin/sql-client.sh -f /opt/flink/sql/users-cdc.sql

    echo \"🎬 Starting CDC for movies table...\"
    docker exec -it flink-sql-client \\
      /opt/flink/bin/sql-client.sh -f /opt/flink/sql/movies-cdc.sql

    echo \"🎫 Starting CDC for tickets table...\"
    docker exec -it flink-sql-client \\
      /opt/flink/bin/sql-client.sh -f /opt/flink/sql/tickets-cdc.sql

    echo \"📊 Starting revenue analytics job...\"
    docker exec -it flink-sql-client \\
      /opt/flink/bin/sql-client.sh -f /opt/flink/sql/revenue-analytics.sql

    echo \"--------------------------------------------\"
    echo \"------- SUBSTEP: Tiering service ----------\"
    echo \"--------------------------------------------\"
    echo \"📦 Starting Fluss Tiering Service with S3...\"
        docker exec flink-jobmanager /opt/flink/bin/flink run \\
          -Dpipeline.name=\"Fluss Tiering Service\" \\
          -Dparallelism.default=4 \\
          -Dexecution.checkpointing.interval=30s \\
          -Dstate.checkpoints.dir=\"${S3_BASE}/checkpoints/tiering\" \\
          -Ds3.multiobjectdelete.enable=false \\
          -Dtaskmanager.memory.network.fraction=0.2 \\
          -Dtaskmanager.memory.managed.fraction=0.6 \\
          /opt/flink/lib/fluss-flink-tiering-0.8.0-incubating.jar \\
          --fluss.bootstrap.servers 192.168.1.202:9123 \\
          --datalake.format paimon \\
          --datalake.paimon.metastore jdbc \\
          --datalake.paimon.uri \"jdbc:postgresql://192.168.1.202:5433/paimon_catalog\" \\
          --datalake.paimon.jdbc.user root \\
          --datalake.paimon.jdbc.password root \\
          --datalake.paimon.catalog-key paimon_catalog \\
          --datalake.paimon.warehouse \"${S3_BASE}/paimon\" \\
          --datalake.paimon.s3.endpoint \"$S3_ENDPOINT\" \\
          --datalake.paimon.s3.access-key \"$S3_ACCESS_KEY\" \\
          --datalake.paimon.s3.secret-key \"$S3_SECRET_KEY\" \\
          --datalake.paimon.s3.path.style.access true

'"

echo -e "\n✨ ALL STEPS COMPLETE. S3-based deployment ready!"
echo "🪣 Data will be stored in: $S3_BASE"