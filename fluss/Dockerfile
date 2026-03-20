# syntax=docker/dockerfile:1

ARG FLUSS_TAG=0.8.0-incubating
ARG ICEBERG_VERSION=1.9.1

# Download regular JARs
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
FROM docker.io/apache/fluss:${FLUSS_TAG}
ARG ICEBERG_VERSION

RUN mkdir -p /opt/fluss/plugins/paimon /opt/fluss/plugins/iceberg

# Paimon
COPY --from=downloader /tmp/out/paimon-s3-*.jar /opt/fluss/plugins/paimon/
COPY --from=downloader /tmp/out/postgresql-*.jar /opt/fluss/plugins/paimon/

# Iceberg (REST catalog + S3A + Hadoop dependencies)
# IMPORTANT: The shaded JAR provides REST SigV4 authentication classes in Fluss's namespace
COPY --from=iceberg_aws_fluss_shaded /work/target/iceberg-aws-${ICEBERG_VERSION}-fluss-shaded.jar /opt/fluss/plugins/iceberg/
COPY --from=downloader /tmp/out/iceberg-aws-bundle-*.jar /opt/fluss/plugins/iceberg/
COPY --from=downloader /tmp/out/hadoop-common-*.jar /opt/fluss/plugins/iceberg/
COPY --from=downloader /tmp/out/hadoop-client-api-*.jar /opt/fluss/plugins/iceberg/
COPY --from=downloader /tmp/out/hadoop-client-runtime-*.jar /opt/fluss/plugins/iceberg/
COPY --from=downloader /tmp/out/hadoop-aws-*.jar /opt/fluss/plugins/iceberg/
COPY --from=downloader /tmp/out/aws-java-sdk-bundle-*.jar /opt/fluss/plugins/iceberg/
COPY --from=downloader /tmp/out/postgresql-*.jar /opt/fluss/plugins/iceberg/

RUN ls -lah /opt/fluss/plugins/paimon/ && ls -lah /opt/fluss/plugins/iceberg/

