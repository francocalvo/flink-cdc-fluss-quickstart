#!/bin/bash
set -euo pipefail

# --- Host Configuration ---
REMOTE_SERVER="calvo@192.168.1.202"
REMOTE_DIR="/mefitis/streaming"

# --- Parse command line arguments ---
DATALAKE_FORMAT="paimon"  # Default to Paimon
BUILD_FLAG=""            # Default no forced build

for arg in "$@"; do
    case $arg in
        --iceberg)
            DATALAKE_FORMAT="iceberg"
            shift
            ;;
        --build)
            BUILD_FLAG="--build"
            shift
            ;;
        *)
            echo "Unknown argument: $arg"
            echo "Usage: $0 [--iceberg] [--build]"
            exit 1
            ;;
    esac
done

echo "🚀 Starting Deployment Script..."
echo "📊 Datalake Format: $DATALAKE_FORMAT"
if [ -n "$BUILD_FLAG" ]; then
    echo "🔨 Force Build: Enabled"
fi

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

    docker compose -f flink-cdc/docker-compose.yaml down -v || true
    docker compose -f flink-cdc/docker-compose-iceberg.yaml down -v || true
    docker compose -f fluss/docker-compose.yaml down -v || true
    docker compose -f fluss/docker-compose-iceberg.yaml down -v || true
    docker compose -f garage/docker-compose.yaml down -v || true
    docker compose -f postgres-catalog/docker-compose.yaml down -v || true
    docker compose -f postgres-source/docker-compose.yaml down -v || true

    echo \"🧹 Pruning Docker volumes...\"
    docker volume prune -f

    echo \"-----------------------------------------\"
    echo \"------- SUBSTEP: DATA DELETION ----------\"
    echo \"-----------------------------------------\"

    echo \"🗑️ Deleting ALL data directories (including postgres-source)...\"
    # Delete all /data/ directories to ensure complete clean slate
    find . -name \"data\" -type d -exec rm -rf {} +

    echo \"🧹 Removing old .env file before provisioning...\"
    rm -f garage/.env

    echo \"----------------------------------------\"
    echo \"------- SUBSTEP: INFRA REBOOT ----------\"
    echo \"----------------------------------------\"
    echo \"🐘 Starting Foundation: Postgres and Garage S3...\"

    docker compose -f postgres-source/docker-compose.yaml up -d
    docker compose -f postgres-catalog/docker-compose.yaml up -d
    docker compose -f garage/docker-compose.yaml up -d
    
    echo \"⏳ Waiting 5s for Garage S3 API...\"
    sleep 5
    
    echo \"-----------------------------------------\"
    echo \"------- SUBSTEP: GARAGE CONFIG ----------\"
    echo \"-----------------------------------------\"
    echo \"🐘 Starting Foundation: Postgres and Garage S3...\"
    echo \"🔑 Provisioning Garage S3 buckets and keys...\"

    cd garage && bash ./garage.sh
'"

echo "📥 2. Fetching Credentials and Updating Local Workspace..."
# Fetch the freshly generated .env from the server back to your local machine
scp "$REMOTE_SERVER:$REMOTE_DIR/garage/.env" ./garage/.env

if [ -f "garage/.env" ]; then
    echo "-----------------------------------------"
    echo "------- SUBSTEP: UPDATING KEYS ----------"
    echo "-----------------------------------------"

    # Load keys into the local bash session for use in sed
    source garage/.env
    
    # --- SUBSTEP: LOCAL CONFIG UPDATE (macOS/Linux compatible sed) ---
    echo "📝 Injecting fresh keys into LOCAL compose files..."
    # 'sed -i ''' is the portable way to handle in-place edits on macOS and Linux
    sed -i '' "s/s3.access-key: .*/s3.access-key: ${GARAGE_ACCESS_KEY}/" flink-cdc/docker-compose.yaml
    sed -i '' "s/s3.secret-key: .*/s3.secret-key: ${GARAGE_SECRET_KEY}/" flink-cdc/docker-compose.yaml

    sed -i '' "s/s3.access-key: .*/s3.access-key: ${GARAGE_ACCESS_KEY}/" fluss/docker-compose.yaml
    sed -i '' "s/s3.secret-key: .*/s3.secret-key: ${GARAGE_SECRET_KEY}/" fluss/docker-compose.yaml
    
    echo "✅ Local files updated locally. Ready for replication."
else
    echo "❌ ERROR: garage/.env was not fetched. Aborting." && exit 1
fi

echo "📤 3. Executing Local Sync and Starting Remote Jobs..."
# Instead of scp, we now trigger your local sync script which replicates the changes
bash ./sync.sh



ssh -t "$REMOTE_SERVER" "sudo bash -c '
    cd $REMOTE_DIR

    # Set environment variables for the session
    export DATALAKE_FORMAT=\"$DATALAKE_FORMAT\"

    echo \"-------------------------------------------\"
    echo \"------- SUBSTEP: STREAMING LAYER ----------\"
    echo \"-------------------------------------------\"

    echo \"🌊 Starting Fluss & 🐿️ Flink CDC...\"
    if [ \"$DATALAKE_FORMAT\" = \"iceberg\" ]; then
        docker compose -f fluss/docker-compose-iceberg.yaml up -d $BUILD_FLAG
        docker compose -f flink-cdc/docker-compose-iceberg.yaml up -d $BUILD_FLAG
    else
        docker compose -f fluss/docker-compose.yaml up -d $BUILD_FLAG
        docker compose -f flink-cdc/docker-compose.yaml up -d $BUILD_FLAG
    fi
    
    echo \"⏳ Waiting for Flink JobManager to go live...\"
    until curl -s http://localhost:8081/overview > /dev/null; do sleep 2; done


    echo \"--------------------------------------------\"
    echo \"------- SUBSTEP: REPLICATION TASK ----------\"
    echo \"--------------------------------------------\"
    echo -e \"\n🚀 Running SQL Client: Postgres -> Fluss...\"
    # Inject keys into the container environment for the SQL variables
    echo \"📊 Starting CDC for users table...\"
    docker exec -it flink-sql-client \
      /opt/flink/bin/sql-client.sh -f /opt/flink/sql/users-cdc.sql

    echo \"🎬 Starting CDC for movies table...\"
    docker exec -it flink-sql-client \
      /opt/flink/bin/sql-client.sh -f /opt/flink/sql/movies-cdc.sql

    echo \"🎫 Starting CDC for tickets table...\"
    docker exec -it flink-sql-client \
      /opt/flink/bin/sql-client.sh -f /opt/flink/sql/tickets-cdc.sql

    echo \"📊 Starting revenue analytics job...\"
    docker exec -it flink-sql-client \
      /opt/flink/bin/sql-client.sh -f /opt/flink/sql/revenue-analytics.sql


    echo \"--------------------------------------------\"
    echo \"------- SUBSTEP: Tiering service ----------\"
    echo \"--------------------------------------------\"
    echo \"📦 Starting Fluss Tiering Service...\"

    if [ \"\$DATALAKE_FORMAT\" = \"paimon\" ]; then
        docker exec flink-jobmanager /opt/flink/bin/flink run \\
          -Dpipeline.name=\"Fluss Tiering Service\" \\
          -Dparallelism.default=4 \\
          -Dexecution.checkpointing.interval=30s \\
          -Dstate.checkpoints.dir=\"s3://warehouse/checkpoints/tiering\" \\
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
          --datalake.paimon.warehouse \"s3://warehouse/paimon\" \\
          --datalake.paimon.s3.endpoint \"http://192.168.1.202:3900\" \\
          --datalake.paimon.s3.access-key \"${GARAGE_ACCESS_KEY}\" \\
          --datalake.paimon.s3.secret-key \"${GARAGE_SECRET_KEY}\" \\
          --datalake.paimon.s3.path.style.access true
    else
        docker exec flink-jobmanager /opt/flink/bin/flink run \\
          -Dpipeline.name=\"Fluss Tiering Service\" \\
          -Dparallelism.default=4 \\
          -Dexecution.checkpointing.interval=30s \\
          -Dstate.checkpoints.dir=\"s3://warehouse/checkpoints/tiering\" \\
          -Ds3.multiobjectdelete.enable=false \\
          -Dtaskmanager.memory.network.fraction=0.2 \\
          -Dtaskmanager.memory.managed.fraction=0.6 \\
          /opt/flink/lib/fluss-flink-tiering-0.8.0-incubating.jar \\
          --fluss.bootstrap.servers 192.168.1.202:9123 \\
          --datalake.format iceberg \\
          --datalake.iceberg.type hadoop \\
          --datalake.iceberg.warehouse \"s3://warehouse/iceberg\" \\
          --datalake.iceberg.hadoop.fs.s3a.endpoint \"http://192.168.1.202:3900\" \\
          --datalake.iceberg.hadoop.fs.s3a.access.key \"${GARAGE_ACCESS_KEY}\" \\
          --datalake.iceberg.hadoop.fs.s3a.secret.key \"${GARAGE_SECRET_KEY}\" \\
          --datalake.iceberg.hadoop.fs.s3a.path.style.access true
    fi

'"

echo -e "\n✨ ALL STEPS COMPLETE. Local repo and server are synchronized via sync.sh."
