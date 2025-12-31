# syntax=docker/dockerfile:1

ARG FLUSS_TAG=0.8.0-incubating

FROM docker.io/curlimages/curl:8.11.0 AS downloader
ARG PAIMON_VERSION=0.8.0
ARG ICEBERG_VERSION=1.9.1
ARG PGJDBC_VERSION=42.7.8
ARG HADOOP_VERSION=3.3.5
ARG AWS_SDK_BUNDLE_VERSION=1.12.316

RUN set -eux; mkdir -p /tmp/out; \
  curl -fL -o "/tmp/out/paimon-s3-${PAIMON_VERSION}.jar" \
    "https://repo1.maven.org/maven2/org/apache/paimon/paimon-s3/${PAIMON_VERSION}/paimon-s3-${PAIMON_VERSION}.jar"; \
  curl -fL -o "/tmp/out/iceberg-aws-bundle-${ICEBERG_VERSION}.jar" \
    "https://repo1.maven.org/maven2/org/apache/iceberg/iceberg-aws-bundle/${ICEBERG_VERSION}/iceberg-aws-bundle-${ICEBERG_VERSION}.jar"; \
  curl -fL -o "/tmp/out/hadoop-common-${HADOOP_VERSION}.jar" \
    "https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-common/${HADOOP_VERSION}/hadoop-common-${HADOOP_VERSION}.jar"; \
  curl -fL -o "/tmp/out/hadoop-client-api-${HADOOP_VERSION}.jar" \
    "https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-client-api/${HADOOP_VERSION}/hadoop-client-api-${HADOOP_VERSION}.jar"; \
  curl -fL -o "/tmp/out/hadoop-client-runtime-${HADOOP_VERSION}.jar" \
    "https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-client-runtime/${HADOOP_VERSION}/hadoop-client-runtime-${HADOOP_VERSION}.jar"; \
  curl -fL -o "/tmp/out/hadoop-aws-${HADOOP_VERSION}.jar" \
    "https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-aws/${HADOOP_VERSION}/hadoop-aws-${HADOOP_VERSION}.jar"; \
  curl -fL -o "/tmp/out/aws-java-sdk-bundle-${AWS_SDK_BUNDLE_VERSION}.jar" \
    "https://repo1.maven.org/maven2/com/amazonaws/aws-java-sdk-bundle/${AWS_SDK_BUNDLE_VERSION}/aws-java-sdk-bundle-${AWS_SDK_BUNDLE_VERSION}.jar"; \
  curl -fL -o "/tmp/out/postgresql-${PGJDBC_VERSION}.jar" \
    "https://repo1.maven.org/maven2/org/postgresql/postgresql/${PGJDBC_VERSION}/postgresql-${PGJDBC_VERSION}.jar"

FROM docker.io/apache/fluss:${FLUSS_TAG}

RUN mkdir -p /opt/fluss/plugins/paimon /opt/fluss/plugins/iceberg

# Paimon
COPY --from=downloader /tmp/out/paimon-s3-*.jar /opt/fluss/plugins/paimon/
COPY --from=downloader /tmp/out/postgresql-*.jar /opt/fluss/plugins/paimon/

# Iceberg (Hadoop + S3A)
COPY --from=downloader /tmp/out/iceberg-aws-bundle-*.jar /opt/fluss/plugins/iceberg/
COPY --from=downloader /tmp/out/hadoop-common-*.jar /opt/fluss/plugins/iceberg/
COPY --from=downloader /tmp/out/hadoop-client-api-*.jar /opt/fluss/plugins/iceberg/
COPY --from=downloader /tmp/out/hadoop-client-runtime-*.jar /opt/fluss/plugins/iceberg/
COPY --from=downloader /tmp/out/hadoop-aws-*.jar /opt/fluss/plugins/iceberg/
COPY --from=downloader /tmp/out/aws-java-sdk-bundle-*.jar /opt/fluss/plugins/iceberg/
COPY --from=downloader /tmp/out/postgresql-*.jar /opt/fluss/plugins/iceberg/

RUN ls -lah /opt/fluss/plugins/paimon/ && ls -lah /opt/fluss/plugins/iceberg/

