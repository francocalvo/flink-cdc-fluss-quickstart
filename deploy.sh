#!/bin/bash
set -euo pipefail

# --- Host Configuration ---
REMOTE_SERVER="muad@192.168.1.4"
REMOTE_DIR="/home/muad/streaming"

echo "🌐 1. Connecting to $REMOTE_SERVER for Remote Environment Reset..."

ssh -t "$REMOTE_SERVER" "sudo nix-shell -p jq --run '
    cd $REMOTE_DIR
    set -euo pipefail

    echo \"-----------------------------------\"
    echo \"------- SUBSTEP: CLEANUP ----------\"
    echo \"-----------------------------------\"
    echo \"🛑 Stopping all services...\"

    docker compose -f flink-cdc/docker-compose.yaml down -v
    docker compose -f fluss/docker-compose.yaml down -v
    docker compose -f garage/docker-compose.yaml down -v
    docker compose -f postgres-catalog/docker-compose.yaml down -v
    docker compose -f postgres-source/docker-compose.yaml down -v

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
    
    echo \"-------------------------------------------\"
    echo \"------- SUBSTEP: STREAMING LAYER ----------\"
    echo \"-------------------------------------------\"

    echo \"🌊 Starting Fluss & 🐿️ Flink CDC...\"
    docker compose -f fluss/docker-compose.yaml up -d
    docker compose -f flink-cdc/docker-compose.yaml up -d
    
    echo \"⏳ Waiting for Flink JobManager to go live...\"
    until curl -s http://localhost:8081/overview > /dev/null; do sleep 2; done


    echo \"--------------------------------------------\"
    echo \"------- SUBSTEP: REPLICATION TASK ----------\"
    echo \"--------------------------------------------\"
    echo -e \"\n🚀 Running SQL Client: Postgres -> Fluss...\"
    # Inject keys into the container environment for the SQL variables
    echo \"📊 Starting CDC for users table...\"
    podman exec -it flink-sql-client \
      /opt/flink/bin/sql-client.sh -f /opt/flink/sql/users-cdc.sql

    echo \"🎬 Starting CDC for movies table...\"
    podman exec -it flink-sql-client \
      /opt/flink/bin/sql-client.sh -f /opt/flink/sql/movies-cdc.sql

    echo \"🎫 Starting CDC for tickets table...\"
    podman exec -it flink-sql-client \
      /opt/flink/bin/sql-client.sh -f /opt/flink/sql/tickets-cdc.sql


    echo \"--------------------------------------------\"
    echo \"------- SUBSTEP: Tiering service ----------\"
    echo \"--------------------------------------------\"
    echo \"📦 Starting Fluss Tiering Service...\"
        docker exec flink-jobmanager /opt/flink/bin/flink run \\
          -Dpipeline.name=\"Fluss Tiering Service\" \\
          -Dparallelism.default=2 \\
          -Dstate.checkpoints.dir=\"s3://warehouse/checkpoints/tiering\" \\
          -Ds3.multiobjectdelete.enable=false \\
          /opt/flink/lib/fluss-flink-tiering-0.8.0-incubating.jar \\
          --fluss.bootstrap.servers 192.168.1.4:9123 \\
          --datalake.format paimon \\
          --datalake.paimon.metastore jdbc \\
          --datalake.paimon.uri \"jdbc:postgresql://192.168.1.4:5433/paimon_catalog\" \\
          --datalake.paimon.jdbc.user root \\
          --datalake.paimon.jdbc.password root \\
          --datalake.paimon.catalog-key paimon_catalog \\
          --datalake.paimon.warehouse \"s3://warehouse/paimon\" \\
          --datalake.paimon.s3.endpoint \"http://192.168.1.4:3900\" \\
          --datalake.paimon.s3.access-key \"${GARAGE_ACCESS_KEY}\" \\
          --datalake.paimon.s3.secret-key \"${GARAGE_SECRET_KEY}\" \\
          --datalake.paimon.s3.path.style.access true

'"

echo -e "\n✨ ALL STEPS COMPLETE. Local repo and server are synchronized via sync.sh."
