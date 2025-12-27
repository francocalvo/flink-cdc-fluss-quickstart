# Flink CDC 3.5.0 targets Flink 1.20.x
FROM flink:1.20.3-java17

USER root

# ---- Versions ----
ENV FLINK_CDC_VERSION=3.5.0
ENV PAIMON_VERSION=1.3.1
ENV FLUSS_VERSION=0.8.0-incubating
ENV POSTGRES_JDBC_VERSION=42.7.3
ENV MYSQL_JDBC_VERSION=8.3.0
ENV FLINK_SHADED_HADOOP_2_UBER_VERSION=2.8.3-10.0

# ---- OS deps ----
RUN apt-get update -y && \
    apt-get install -y --no-install-recommends ca-certificates wget curl && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /opt/flink/lib

# 1) Flink CDC pipeline connector jars (sources + sinks)
RUN wget -q "https://repo1.maven.org/maven2/org/apache/flink/flink-cdc-pipeline-connector-postgres/${FLINK_CDC_VERSION}/flink-cdc-pipeline-connector-postgres-${FLINK_CDC_VERSION}.jar" && \
    wget -q "https://repo1.maven.org/maven2/org/apache/flink/flink-cdc-pipeline-connector-mysql/${FLINK_CDC_VERSION}/flink-cdc-pipeline-connector-mysql-${FLINK_CDC_VERSION}.jar" && \
    wget -q "https://repo1.maven.org/maven2/org/apache/flink/flink-cdc-pipeline-connector-paimon/${FLINK_CDC_VERSION}/flink-cdc-pipeline-connector-paimon-${FLINK_CDC_VERSION}.jar" && \
    wget -q "https://repo1.maven.org/maven2/org/apache/flink/flink-cdc-pipeline-connector-fluss/${FLINK_CDC_VERSION}/flink-cdc-pipeline-connector-fluss-${FLINK_CDC_VERSION}.jar" && \
    wget -q "https://repo1.maven.org/maven2/org/apache/flink/flink-cdc-pipeline-connector-kafka/${FLINK_CDC_VERSION}/flink-cdc-pipeline-connector-kafka-${FLINK_CDC_VERSION}.jar" && \
    wget -q "https://repo1.maven.org/maven2/org/apache/flink/flink-cdc-pipeline-connector-starrocks/${FLINK_CDC_VERSION}/flink-cdc-pipeline-connector-starrocks-${FLINK_CDC_VERSION}.jar" && \
    wget -q "https://repo1.maven.org/maven2/org/apache/flink/flink-cdc-pipeline-connector-doris/${FLINK_CDC_VERSION}/flink-cdc-pipeline-connector-doris-${FLINK_CDC_VERSION}.jar"

# 2) JDBC drivers
RUN wget -q "https://repo1.maven.org/maven2/org/postgresql/postgresql/${POSTGRES_JDBC_VERSION}/postgresql-${POSTGRES_JDBC_VERSION}.jar" && \
    wget -q "https://repo1.maven.org/maven2/com/mysql/mysql-connector-j/${MYSQL_JDBC_VERSION}/mysql-connector-j-${MYSQL_JDBC_VERSION}.jar"

# 3) Paimon jars (Flink 1.20 engine + S3 support + action jar)
RUN wget -q "https://repo1.maven.org/maven2/org/apache/paimon/paimon-flink-1.20/${PAIMON_VERSION}/paimon-flink-1.20-${PAIMON_VERSION}.jar" && \
    wget -q "https://repo1.maven.org/maven2/org/apache/paimon/paimon-s3/${PAIMON_VERSION}/paimon-s3-${PAIMON_VERSION}.jar" && \
    wget -q "https://repo1.maven.org/maven2/org/apache/paimon/paimon-flink-action/${PAIMON_VERSION}/paimon-flink-action-${PAIMON_VERSION}.jar"

# 4) Fluss jars (Flink connector + Paimon lake integration for union reads)
RUN wget -q "https://repo1.maven.org/maven2/org/apache/fluss/fluss-flink-1.20/${FLUSS_VERSION}/fluss-flink-1.20-${FLUSS_VERSION}.jar" && \
    wget -q "https://repo1.maven.org/maven2/org/apache/fluss/fluss-lake-paimon/${FLUSS_VERSION}/fluss-lake-paimon-${FLUSS_VERSION}.jar" && \
    wget -q "https://repo1.maven.org/maven2/org/apache/fluss/fluss-flink-tiering/${FLUSS_VERSION}/fluss-flink-tiering-${FLUSS_VERSION}.jar"

# 5) Enable Flink S3 filesystem plugin (needed for s3:// URIs for checkpoints/savepoints)
RUN mkdir -p /opt/flink/plugins/s3-fs-hadoop && \
    cp /opt/flink/opt/flink-s3-fs-hadoop-*.jar /opt/flink/plugins/s3-fs-hadoop/

# 6) Flink shaded Hadoop uber jar (required for Paimon JDBC metastore)
RUN wget -q "https://repo1.maven.org/maven2/org/apache/flink/flink-shaded-hadoop-2-uber/${FLINK_SHADED_HADOOP_2_UBER_VERSION}/flink-shaded-hadoop-2-uber-${FLINK_SHADED_HADOOP_2_UBER_VERSION}.jar"

# 7) Kafka SQL connector (useful for streaming pipelines)
RUN wget -q "https://repo1.maven.org/maven2/org/apache/flink/flink-sql-connector-kafka/3.4.0-1.20/flink-sql-connector-kafka-3.4.0-1.20.jar"

# 8) Format jars (Avro, Parquet)
RUN wget -q "https://repo1.maven.org/maven2/org/apache/flink/flink-sql-avro/1.20.0/flink-sql-avro-1.20.0.jar" && \
    wget -q "https://repo1.maven.org/maven2/org/apache/flink/flink-sql-parquet/1.20.0/flink-sql-parquet-1.20.0.jar"

# Permissions
RUN chown -R flink:flink /opt/flink

# Basic healthcheck (JM UI)
HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
  CMD curl -fsS http://localhost:8081/ || exit 1

USER flink
