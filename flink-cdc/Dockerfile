# Flink CDC 3.5.0 targets Flink 1.20.x

ARG ICEBERG_VERSION=1.9.1

# Build Fluss-shaded Iceberg AWS JAR for REST SigV4 authentication
FROM docker.io/maven:3.9.9-eclipse-temurin-17 AS iceberg_aws_fluss_shaded
ARG ICEBERG_VERSION
WORKDIR /work

RUN set -eux; \
  cat > pom.xml <<EOF
<project xmlns="http://maven.apache.org/POM/4.0.0" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 http://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>

  <groupId>local.fix</groupId>
  <artifactId>iceberg-aws-fluss-shaded</artifactId>
  <version>1.0.0</version>
  <packaging>jar</packaging>

  <properties>
    <iceberg.version>${ICEBERG_VERSION}</iceberg.version>
    <maven.compiler.release>11</maven.compiler.release>
  </properties>

  <dependencies>
    <dependency>
      <groupId>org.apache.iceberg</groupId>
      <artifactId>iceberg-aws</artifactId>
      <version>\${iceberg.version}</version>
    </dependency>
  </dependencies>

  <build>
    <plugins>
      <plugin>
        <groupId>org.apache.maven.plugins</groupId>
        <artifactId>maven-shade-plugin</artifactId>
        <version>3.6.1</version>
        <executions>
          <execution>
            <phase>package</phase>
            <goals><goal>shade</goal></goals>
            <configuration>
              <createDependencyReducedPom>false</createDependencyReducedPom>
              <finalName>iceberg-aws-\${iceberg.version}-fluss-shaded</finalName>
              <filters>
                <filter>
                  <artifact>*:*</artifact>
                  <excludes>
                    <exclude>META-INF/versions/22/**</exclude>
                  </excludes>
                </filter>
              </filters>
              <relocations>
                <relocation>
                  <pattern>org.apache.iceberg</pattern>
                  <shadedPattern>org.apache.fluss.lake.iceberg.shaded.org.apache.iceberg</shadedPattern>
                </relocation>
              </relocations>
            </configuration>
          </execution>
        </executions>
      </plugin>
    </plugins>
  </build>
</project>
EOF

RUN mvn -q -DskipTests package

# Final image
FROM flink:1.20.3-java17
ARG ICEBERG_VERSION

USER root

# ---- Versions ----
ENV FLINK_CDC_VERSION=3.5.0
ENV PAIMON_VERSION=1.3.1
ENV FLUSS_VERSION=0.8.0-incubating
ENV POSTGRES_JDBC_VERSION=42.7.3
ENV MYSQL_JDBC_VERSION=8.3.0
# Use Hadoop 3.x as required by Fluss Iceberg integration
ENV HADOOP_VERSION=3.3.5-2

# ---- OS deps ----
RUN apt-get update -y && \
    apt-get install -y --no-install-recommends ca-certificates wget curl && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /opt/flink/lib

# 1) Flink CDC binary distribution (includes flink-cdc.sh script + core runtime)
#    Copy the lib JARs to Flink's lib directory for runtime availability
RUN cd /opt && \
    wget -q "https://github.com/apache/flink-cdc/releases/download/release-${FLINK_CDC_VERSION}/flink-cdc-${FLINK_CDC_VERSION}-bin.tar.gz" && \
    tar -xzf flink-cdc-${FLINK_CDC_VERSION}-bin.tar.gz && \
    cp /opt/flink-cdc-${FLINK_CDC_VERSION}/lib/*.jar /opt/flink/lib/ && \
    rm flink-cdc-${FLINK_CDC_VERSION}-bin.tar.gz && \
    chown -R flink:flink /opt/flink-cdc-${FLINK_CDC_VERSION}

# 2) Flink CDC pipeline connector jars (sources + sinks)
RUN wget -q "https://repo1.maven.org/maven2/org/apache/flink/flink-cdc-pipeline-connector-postgres/${FLINK_CDC_VERSION}/flink-cdc-pipeline-connector-postgres-${FLINK_CDC_VERSION}.jar" && \
    wget -q "https://repo1.maven.org/maven2/org/apache/flink/flink-cdc-pipeline-connector-mysql/${FLINK_CDC_VERSION}/flink-cdc-pipeline-connector-mysql-${FLINK_CDC_VERSION}.jar" && \
    wget -q "https://repo1.maven.org/maven2/org/apache/flink/flink-cdc-pipeline-connector-paimon/${FLINK_CDC_VERSION}/flink-cdc-pipeline-connector-paimon-${FLINK_CDC_VERSION}.jar" && \
    wget -q "https://repo1.maven.org/maven2/org/apache/flink/flink-cdc-pipeline-connector-fluss/${FLINK_CDC_VERSION}/flink-cdc-pipeline-connector-fluss-${FLINK_CDC_VERSION}.jar" && \
    wget -q "https://repo1.maven.org/maven2/org/apache/flink/flink-cdc-pipeline-connector-kafka/${FLINK_CDC_VERSION}/flink-cdc-pipeline-connector-kafka-${FLINK_CDC_VERSION}.jar" && \
    wget -q "https://repo1.maven.org/maven2/org/apache/flink/flink-cdc-pipeline-connector-starrocks/${FLINK_CDC_VERSION}/flink-cdc-pipeline-connector-starrocks-${FLINK_CDC_VERSION}.jar" && \
    wget -q "https://repo1.maven.org/maven2/org/apache/flink/flink-cdc-pipeline-connector-doris/${FLINK_CDC_VERSION}/flink-cdc-pipeline-connector-doris-${FLINK_CDC_VERSION}.jar"

# 3) JDBC drivers
RUN wget -q "https://repo1.maven.org/maven2/org/postgresql/postgresql/${POSTGRES_JDBC_VERSION}/postgresql-${POSTGRES_JDBC_VERSION}.jar" && \
    wget -q "https://repo1.maven.org/maven2/com/mysql/mysql-connector-j/${MYSQL_JDBC_VERSION}/mysql-connector-j-${MYSQL_JDBC_VERSION}.jar"

# 4) Paimon jars (Flink 1.20 engine + S3 support + action jar)
RUN wget -q "https://repo1.maven.org/maven2/org/apache/paimon/paimon-flink-1.20/${PAIMON_VERSION}/paimon-flink-1.20-${PAIMON_VERSION}.jar" && \
    wget -q "https://repo1.maven.org/maven2/org/apache/paimon/paimon-s3/${PAIMON_VERSION}/paimon-s3-${PAIMON_VERSION}.jar" && \
    wget -q "https://repo1.maven.org/maven2/org/apache/paimon/paimon-flink-action/${PAIMON_VERSION}/paimon-flink-action-${PAIMON_VERSION}.jar"

# 5) Iceberg jars (Flink 1.20 runtime + AWS bundle + FileIO dependencies)
#    Per Fluss docs: https://fluss.apache.org/docs/streaming-lakehouse/integrate-data-lakes/iceberg/
RUN wget -q "https://repo1.maven.org/maven2/org/apache/iceberg/iceberg-flink-runtime-1.20/${ICEBERG_VERSION}/iceberg-flink-runtime-1.20-${ICEBERG_VERSION}.jar" && \
    wget -q "https://repo1.maven.org/maven2/org/apache/iceberg/iceberg-aws/${ICEBERG_VERSION}/iceberg-aws-${ICEBERG_VERSION}.jar" && \
    wget -q "https://repo1.maven.org/maven2/org/apache/iceberg/iceberg-aws-bundle/${ICEBERG_VERSION}/iceberg-aws-bundle-${ICEBERG_VERSION}.jar" && \
    wget -q "https://repo1.maven.org/maven2/dev/failsafe/failsafe/3.3.2/failsafe-3.3.2.jar"

# 5b) Fluss-shaded Iceberg AWS JAR for REST SigV4 authentication
#     IMPORTANT: Provides REST SigV4 authentication classes in Fluss's namespace
COPY --from=iceberg_aws_fluss_shaded /work/target/iceberg-aws-${ICEBERG_VERSION}-fluss-shaded.jar /opt/flink/lib/

# 6) Fluss jars (Flink connector + lake integrations + S3 filesystem)
#    Per Fluss docs, fluss-fs-s3 goes in lib for remote storage support
RUN wget -q "https://repo1.maven.org/maven2/org/apache/fluss/fluss-flink-1.20/${FLUSS_VERSION}/fluss-flink-1.20-${FLUSS_VERSION}.jar" && \
    wget -q "https://repo1.maven.org/maven2/org/apache/fluss/fluss-lake-paimon/${FLUSS_VERSION}/fluss-lake-paimon-${FLUSS_VERSION}.jar" && \
    wget -q "https://repo1.maven.org/maven2/org/apache/fluss/fluss-lake-iceberg/${FLUSS_VERSION}/fluss-lake-iceberg-${FLUSS_VERSION}.jar" && \
    wget -q "https://repo1.maven.org/maven2/org/apache/fluss/fluss-flink-tiering/${FLUSS_VERSION}/fluss-flink-tiering-${FLUSS_VERSION}.jar" && \
    wget -q "https://repo1.maven.org/maven2/org/apache/fluss/fluss-fs-s3/${FLUSS_VERSION}/fluss-fs-s3-${FLUSS_VERSION}.jar" && \
    wget -q "https://repo1.maven.org/maven2/org/apache/fluss/fluss-fs-hdfs/${FLUSS_VERSION}/fluss-fs-hdfs-${FLUSS_VERSION}.jar"

# 7) Enable Flink S3 filesystem plugin (needed for s3:// URIs for checkpoints/savepoints)
RUN mkdir -p /opt/flink/plugins/s3-fs-hadoop && \
    cp /opt/flink/opt/flink-s3-fs-hadoop-*.jar /opt/flink/plugins/s3-fs-hadoop/

# 8) Hadoop 3.x dependencies (REQUIRED for Fluss Iceberg integration)
#    - hadoop-apache: Core Hadoop classes (replaces flink-shaded-hadoop-2-uber)
#    - hadoop-aws: S3AFileSystem for s3a:// paths used by Iceberg HadoopCatalog
#    - aws-java-sdk-bundle: AWS SDK required by hadoop-aws
#    See: https://fluss.apache.org/docs/streaming-lakehouse/integrate-data-lakes/iceberg/
RUN wget -q "https://repo1.maven.org/maven2/io/trino/hadoop/hadoop-apache/${HADOOP_VERSION}/hadoop-apache-${HADOOP_VERSION}.jar" && \
    wget -q "https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-aws/3.3.5/hadoop-aws-3.3.5.jar" && \
    wget -q "https://repo1.maven.org/maven2/com/amazonaws/aws-java-sdk-bundle/1.12.367/aws-java-sdk-bundle-1.12.367.jar"

# 9) Kafka SQL connector (useful for streaming pipelines)
RUN wget -q "https://repo1.maven.org/maven2/org/apache/flink/flink-sql-connector-kafka/3.4.0-1.20/flink-sql-connector-kafka-3.4.0-1.20.jar"

# 10) Format jars (Avro, Parquet)
RUN wget -q "https://repo1.maven.org/maven2/org/apache/flink/flink-sql-avro/1.20.0/flink-sql-avro-1.20.0.jar" && \
    wget -q "https://repo1.maven.org/maven2/org/apache/flink/flink-sql-parquet/1.20.0/flink-sql-parquet-1.20.0.jar"

# Set up environment
ENV FLINK_HOME=/opt/flink
ENV PATH=$PATH:/opt/flink-cdc-${FLINK_CDC_VERSION}/bin

# Permissions
RUN chown -R flink:flink /opt/flink

# Basic healthcheck (JM UI)
HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
  CMD curl -fsS http://localhost:8081/ || exit 1

USER flink
