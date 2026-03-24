# Confluent Kafka User Management — Single image (Node UI + gen.sh + Kafka CLI tools).
# Build: docker build -t confluent-kafka-user-management:latest .
# Run: docker compose up (see docker-compose.yml) — mount kubeconfig, SSL, client properties under ./runtime
# Base: Debian (glibc) so host-mounted /usr/bin (dirname, oc) works at /host/usr/bin.

FROM node:20-bookworm-slim AS builder
WORKDIR /app
COPY webapp/package.json ./
RUN npm install --omit=dev --ignore-scripts

FROM node:20-bookworm-slim
# Semantic app version (shown in UI). Optional GIT_COMMIT for /api/version short hash.
ARG VERSION=1.0.86
ARG GIT_COMMIT=
ENV APP_VERSION=${VERSION}
ENV GIT_COMMIT=${GIT_COMMIT}
LABEL org.opencontainers.image.version="${VERSION}"
# Kafka CLI: default 3.6.1 (stable client; matches symlink name kafka_2.13-3.6.1).
# Online: downloaded from Apache at build. Offline: place kafka_${KAFKA_SCALA}-${KAFKA_VERSION}.tgz under kafka/ (see kafka/OFFLINE-BUILD.txt).
# Bump broker/client: docker build --build-arg KAFKA_VERSION=3.8.1 .
ARG KAFKA_VERSION=3.6.1
ARG KAFKA_SCALA=2.13
# Stable path for Kafka CLI symlink name (extracted kafka_${KAFKA_SCALA}-${KAFKA_VERSION})
ARG KAFKA_LINK_NAME=kafka_2.13-3.6.1
# Tarball lives OUTSIDE /opt/kafka-usermgmt so a host bind-mount on runtime does not hide CLI tools.
ENV KAFKA_TOOLS_BIN=/opt/apache-kafka/kafka_2.13-3.6.1/bin
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash jq openjdk-17-jre-headless ca-certificates-java curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY kafka/ /tmp/kafka-vendor/
RUN mkdir -p /opt/apache-kafka \
    && DIST="kafka_${KAFKA_SCALA}-${KAFKA_VERSION}" \
    && VENDOR="/tmp/kafka-vendor/${DIST}.tgz" \
    && if [ -f "$VENDOR" ] && [ -s "$VENDOR" ]; then \
         echo "kafka: using build-context $(basename "$VENDOR")" \
         && tar xzf "$VENDOR" -C /opt/apache-kafka; \
       else \
         URL_DL="https://downloads.apache.org/kafka/${KAFKA_VERSION}/${DIST}.tgz" \
         && URL_AR="https://archive.apache.org/dist/kafka/${KAFKA_VERSION}/${DIST}.tgz" \
         && (curl -fsSL "$URL_DL" || curl -fsSL "$URL_AR") | tar xz -C /opt/apache-kafka; \
       fi \
    && test -d "/opt/apache-kafka/${DIST}" \
    && ln -sfn "/opt/apache-kafka/${DIST}" "/opt/apache-kafka/${KAFKA_LINK_NAME}" \
    && rm -rf /tmp/kafka-vendor
RUN mkdir -p /opt/kafka-usermgmt
WORKDIR /app
ENV NODE_ENV=production
ENV NODE_OPTIONS="--max-old-space-size=128"
ENV STATIC_DIR=/app/static
ENV CONFIG_PATH=/app/config/master.config.json

COPY --from=builder /app/node_modules ./node_modules
COPY webapp/package.json webapp/server ./server/
COPY webapp/scripts ./scripts
COPY web-ui-mockup ./static
COPY webapp/config ./config
# Examples only — bind-mounting ./deploy/config hides /app/config; samples stay at /app/config-examples/
RUN mkdir -p /app/config-examples \
    && cp /app/config/master.config.example.json /app/config-examples/ \
    && cp /app/config/credentials.example.json /app/config-examples/
# master.config.json is created at first run via /setup.html (mount ./deploy/config for persistence).
# gen.sh / helper scripts live ONLY in the image (/app/bundled-gen), not on the host runtime mount.
# Runtime mount → /opt/kafka-usermgmt holds configs, kubeconfig, user_output, etc. — do not rely on gen.sh there.
RUN mkdir -p /app/bundled-gen
COPY gen.sh /app/bundled-gen/gen.sh
COPY scripts/verify-golive.sh /app/bundled-gen/verify-golive.sh
COPY scripts/ensure-kafka-client-props.sh /app/bundled-gen/ensure-kafka-client-props.sh
RUN chmod +x /app/bundled-gen/gen.sh /app/bundled-gen/verify-golive.sh /app/bundled-gen/ensure-kafka-client-props.sh
ENV GEN_BUNDLED_SCRIPT_PATH=/app/bundled-gen/gen.sh

EXPOSE 3443
CMD ["node", "server/index.js"]
