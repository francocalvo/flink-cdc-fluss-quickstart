# Local Data Lakehouse Stack

Local development environment with Flink 2.1 CDC, Paimon, Fluss, and
S3-compatible storage.

## Components

| Service              | Port                    | Purpose                                |
| -------------------- | ----------------------- | -------------------------------------- |
| PostgreSQL (catalog) | 5433                    | Paimon JDBC catalog metastore          |
| PostgreSQL (source)  | 5432                    | CDC source database                    |
| Garage               | 3900 (S3), 3903 (Admin) | S3-compatible storage for Paimon/Fluss |
| Flink SQL Client     | -                       | Interactive SQL                        |
| Fluss Coordinator    | 9123                    | Streaming storage                      |
| ZooKeeper            | 2181                    | Fluss coordination                     |

## Quick Start

You can do the deployment automatically using the `deploy.sh` script. You will
need to update all IPs to the local IP of your server.

The script does something like this:

1. Bring up containers for both PostgreSQL.
2. Bring up Garage compose and use the `garage.sh` script.
3. Copy the access keys to the docker-compose files for both Fluss and Flink.
4. Bring up the Fluss compose.
5. Bring up the Flink compose.

Then you can execute the CDC job as:

```sh
podman exec -it flink-sql-client \
  /opt/flink/bin/sql-client.sh -f /opt/flink/sql/tickets-cdc.sql
```

And the tiering service like this:

```
docker exec flink-jobmanager /opt/flink/bin/flink run \
  -Dpipeline.name="Fluss Tiering Service" \
  -Dparallelism.default=2 \
  /opt/flink/lib/fluss-flink-tiering-0.8.0-incubating.jar \
  --fluss.bootstrap.servers 192.168.1.202:9123 \
  --datalake.format paimon \
  --datalake.paimon.metastore jdbc \
  --datalake.paimon.uri "jdbc:postgresql://192.168.1.202:5433/paimon_catalog" \
  --datalake.paimon.jdbc.user root \
  --datalake.paimon.jdbc.password root \
  --datalake.paimon.catalog-key paimon_catalog \
  --datalake.paimon.warehouse "s3://warehouse/paimon" \
  --datalake.paimon.s3.endpoint "http://192.168.1.202:3900" \
  --datalake.paimon.s3.access-key "GK5fefefc0acb90cffed812ba8" \
  --datalake.paimon.s3.secret-key "3ae8ec7da6166d78eb23c995aa7fa786f6fe6f9a2866839e9afde081c9632dee " \
  --datalake.paimon.s3.path.style.access true
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

In SQL Client:

```
CREATE CATALOG paimon_catalog WITH (
     'type' = 'paimon',
     'metastore' = 'jdbc',
     'uri' = 'jdbc:postgresql://192.168.1.202:5433/paimon_catalog',
     'jdbc.user' = 'root',
     'jdbc.password' = 'root',
     'catalog-key' = 'paimon_catalog',
     'warehouse' = 's3://warehouse/paimon',
     's3.endpoint' = 'http://192.168.1.202:3900',
     's3.access-key' = 'GK76bd98aae261d4fade11c4fb',
     's3.secret-key' = '85c9488de84ab82ea412d5e1dfd2e8a12101fe6537e129a1e5547e5bebab6f20',
     's3.path-style-access' = 'true'
 );

```

## Links

https://fluss.apache.org/blog/hands-on-fluss-lakehouse/

## Comment:

**Lakehouse Format Dependencies**

When using Fluss with different lakehouse formats, the Hadoop dependency
requirements differ significantly.

**Paimon**

Paimon works with the older `flink-shaded-hadoop-2-uber-2.8.3-10.0.jar`. This
uber jar bundles Hadoop 2.8.3 classes and is sufficient for Paimon's JDBC
metastore and S3 operations.

**Iceberg**

Iceberg requires Hadoop 3.x. The Fluss Iceberg integration
(`fluss-lake-iceberg`, `fluss-fs-s3`) is compiled against Hadoop 3.x APIs that
don't exist in Hadoop 2.8.3. Using the old Hadoop 2 uber jar will cause runtime
errors like:

```
NoSuchMethodError: 'long org.apache.hadoop.conf.Configuration.getTimeDuration(...)'
```

The fix is to replace `flink-shaded-hadoop-2-uber` with the Trino pre-bundled
Hadoop 3.x jar:

```
hadoop-apache-3.3.5-2.jar
```

Additionally, Iceberg S3 FileIO requires these jars:

```
iceberg-aws-1.9.1.jar
iceberg-aws-bundle-1.9.1.jar
failsafe-3.3.2.jar
```

**Mixed Usage**

If you need both Paimon and Iceberg in the same Flink deployment, use the Hadoop
3.x jar. Paimon is forward-compatible with Hadoop 3.x, but Iceberg is not
backward-compatible with Hadoop 2.x.
