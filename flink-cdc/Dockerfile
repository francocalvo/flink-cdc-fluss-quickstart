# Flink CDC 3.5.0 targets Flink 1.20.x
FROM flink:1.20.3-java17

USER root

# ---- Versions ----
ENV FLINK_CDC_VERSION=3.5.0
ENV PAIMON_VERSION=1.3.1
ENV FLUSS_VERSION=0.8.0-incubating
ENV POSTGRES_JDBC_VERSION=42.7.3

# Optional: only enable if you actually hit missing Hadoop classes at runtime
ARG INCLUDE_FLINK_SHADED_HADOOP_UBER=false
ENV FLINK_SHADED_HADOOP_2_UBER_VERSION=2.8.3-10.0

# ---- OS deps (curl for HEALTHCHECK, wget/tar for downloads) ----
RUN apt-get update -y && \
    apt-get install -y --no-install-recommends ca-certificates wget tar gzip curl && \
    rm -rf /var/lib/apt/lists/*

# ---- Install Flink CDC CLI distribution (handy for YAML pipelines) ----
ENV FLINK_CDC_HOME=/opt/flink-cdc
RUN mkdir -p "${FLINK_CDC_HOME}" && \
    wget -qO- "https://archive.apache.org/dist/flink/flink-cdc-${FLINK_CDC_VERSION}/flink-cdc-${FLINK_CDC_VERSION}-bin.tar.gz" \
      | tar -xz --strip-components=1 -C "${FLINK_CDC_HOME}"

# ---- Put runtime jars where Flink and the CDC CLI can see them ----
WORKDIR /opt/flink/lib

# 1) Flink CDC pipeline connector jars (Postgres source + Paimon/Fluss sinks)
RUN wget -q "https://repo1.maven.org/maven2/org/apache/flink/flink-cdc-pipeline-connector-postgres/${FLINK_CDC_VERSION}/flink-cdc-pipeline-connector-postgres-${FLINK_CDC_VERSION}.jar" && \
    wget -q "https://repo1.maven.org/maven2/org/apache/flink/flink-cdc-pipeline-connector-paimon/${FLINK_CDC_VERSION}/flink-cdc-pipeline-connector-paimon-${FLINK_CDC_VERSION}.jar" && \
    wget -q "https://repo1.maven.org/maven2/org/apache/flink/flink-cdc-pipeline-connector-fluss/${FLINK_CDC_VERSION}/flink-cdc-pipeline-connector-fluss-${FLINK_CDC_VERSION}.jar" && \
    cp -f flink-cdc-pipeline-connector-*.jar "${FLINK_CDC_HOME}/lib/"

# 2) PostgreSQL JDBC driver (not guaranteed to be bundled when you only download connector jars)
RUN wget -q "https://repo1.maven.org/maven2/org/postgresql/postgresql/${POSTGRES_JDBC_VERSION}/postgresql-${POSTGRES_JDBC_VERSION}.jar"

# 3) Paimon jars (Flink 1.20 engine + S3 support)
RUN wget -q "https://repo1.maven.org/maven2/org/apache/paimon/paimon-flink-1.20/${PAIMON_VERSION}/paimon-flink-1.20-${PAIMON_VERSION}.jar" && \
    wget -q "https://repo1.maven.org/maven2/org/apache/paimon/paimon-s3/${PAIMON_VERSION}/paimon-s3-${PAIMON_VERSION}.jar"

# 4) Fluss Flink connector jar (often useful even if using the CDC pipeline sink)
RUN wget -q "https://repo1.maven.org/maven2/org/apache/fluss/fluss-flink-1.20/${FLUSS_VERSION}/fluss-flink-1.20-${FLUSS_VERSION}.jar"

# 5) Enable Flink S3 filesystem plugin (needed for s3a:// URIs via Hadoop)
RUN mkdir -p /opt/flink/plugins/s3-fs-hadoop && \
    cp /opt/flink/opt/flink-s3-fs-hadoop-*.jar /opt/flink/plugins/s3-fs-hadoop/

# 6) Optional: Flink shaded Hadoop uber jar (OFF by default; can cause conflicts)
RUN if [ "${INCLUDE_FLINK_SHADED_HADOOP_UBER}" = "true" ]; then \
      wget -q "https://repo1.maven.org/maven2/org/apache/flink/flink-shaded-hadoop-2-uber/${FLINK_SHADED_HADOOP_2_UBER_VERSION}/flink-shaded-hadoop-2-uber-${FLINK_SHADED_HADOOP_2_UBER_VERSION}.jar" ; \
    fi

# Permissions
RUN chown -R flink:flink /opt/flink "${FLINK_CDC_HOME}"

ENV PATH="${FLINK_CDC_HOME}/bin:${PATH}"

# Basic healthcheck (JM UI)
HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
  CMD curl -fsS http://localhost:8081/ || exit 1

USER flink

