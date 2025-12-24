[#](#) Local Data Lakehouse Stack

Local development environment with Flink 2.1 CDC, Paimon, Fluss, and
S3-compatible storage.

## Components

| Service              | Port                    | Purpose                                |
| -------------------- | ----------------------- | -------------------------------------- |
| PostgreSQL (catalog) | 5433                    | Paimon JDBC catalog metastore          |
| PostgreSQL (source)  | 5432                    | CDC source database                    |
| LocalStack           | 4566                    | Kinesis local                          |
| Garage               | 3900 (S3), 3903 (Admin) | S3-compatible storage for Paimon/Fluss |
| Flink 2.1 JobManager | 8081                    | Flink Web UI                           |
| Flink SQL Client     | -                       | Interactive SQL                        |
| Fluss Coordinator    | 9123                    | Streaming storage                      |
| ZooKeeper            | 2181                    | Fluss coordination                     |

## Versions

| Component      | Version          |
| -------------- | ---------------- |
| Apache Flink   | 2.1.0            |
| Apache Paimon  | 1.1.0            |
| Flink CDC      | 3.3.0            |
| JDBC Connector | 4.0.0-2.0        |
| AWS Connectors | 5.0.0-1.20       |
| Apache Fluss   | 0.8.0-incubating |
| PostgreSQL     | 14               |

## Quick Start

```bash
docker compose up -d  postgres-source postgres-catalog garage localstack

chmod +x scripts/init-garage.sh
./scripts/init-garage.sh

docker compose up -d jobmanager taskmanager sql-client

docker compose up -d zookeeper
docker compose up -d fluss-coordinator fluss-tablet

# 6. Start remaining services
docker compose up -d

# 7. Access Flink SQL Client
docker compose exec sql-client /opt/flink/bin/sql-client.sh

```

## Using the SQL Client

```sql
ADD JAR 'file:///opt/flink/lib/paimon-flink.jar';
ADD JAR 'file:///opt/flink/lib/paimon-s3.jar';
SHOW JARS;

-- Check available catalogs
SHOW CATALOGS;

-- Use Paimon
USE CATALOG paimon_catalog;
USE lakehouse;

-- Start CDC job
INSERT INTO tickets SELECT * FROM cdc_tickets;

-- Query the lakehouse table
SELECT * FROM tickets;
SELECT status, COUNT(*), SUM(entry_amount) FROM tickets GROUP BY status;
```

## PyFlink Usage

```python
from pyflink.table import EnvironmentSettings, TableEnvironment

env_settings = EnvironmentSettings.in_streaming_mode()
t_env = TableEnvironment.create(env_settings)

# Register Paimon catalog
t_env.execute_sql("""
    CREATE CATALOG paimon WITH (
        'type' = 'paimon',
        'metastore' = 'jdbc',
        'uri' = 'jdbc:postgresql://postgres-catalog:5432/paimon_catalog',
        'jdbc.user' = 'root',
        'jdbc.password' = 'root',
        'warehouse' = 's3://warehouse/paimon',
        's3.endpoint' = 'http://garage:3900',
        's3.path-style-access' = 'true'
    )
""")
```

## Useful Commands

```bash
# View Flink logs
docker compose logs -f jobmanager taskmanager

# Scale task managers
docker compose up -d --scale taskmanager=4

# Create Kinesis stream
aws --endpoint-url=http://localhost:4566 kinesis create-stream \
    --stream-name events --shard-count 2

# Test S3 access
aws --endpoint-url=http://localhost:3900 s3 ls s3://warehouse/

# Restart Flink cluster
docker compose restart jobmanager taskmanager
```

## Troubleshooting

**Garage not initializing:** Run the init script manually and check logs with
`docker compose logs garage`.

**CDC slot already exists:** Drop on postgres-source:

```sql
SELECT pg_drop_replication_slot('tickets_slot');
```

**Flink can't reach S3:** Verify Garage credentials in `.env` and that the
warehouse bucket exists.

**Fluss connection refused:** Ensure ZooKeeper is healthy before starting Fluss
services.
