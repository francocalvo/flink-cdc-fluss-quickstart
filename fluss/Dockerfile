# syntax=docker/dockerfile:1

ARG FLUSS_TAG=0.8.0-incubating

# Fully-qualify images to avoid podman interactive registry prompt
FROM docker.io/curlimages/curl:8.11.0 AS downloader
ARG PAIMON_VERSION=0.8.0
ARG PGJDBC_VERSION=42.7.8

# /tmp is writable even for non-root in most images
RUN set -eux; \
  mkdir -p /tmp/out; \
  curl -fL -o "/tmp/out/paimon-s3-${PAIMON_VERSION}.jar" \
    "https://repo1.maven.org/maven2/org/apache/paimon/paimon-s3/${PAIMON_VERSION}/paimon-s3-${PAIMON_VERSION}.jar"; \
  curl -fL -o "/tmp/out/postgresql-${PGJDBC_VERSION}.jar" \
    "https://repo1.maven.org/maven2/org/postgresql/postgresql/${PGJDBC_VERSION}/postgresql-${PGJDBC_VERSION}.jar"

FROM docker.io/apache/fluss:${FLUSS_TAG}

COPY --from=downloader /tmp/out/*.jar /opt/fluss/plugins/paimon/

# Optional visibility
RUN ls -lah /opt/fluss/plugins/paimon/

