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
ARG VERSION=1.0.61
ARG GIT_COMMIT=
ENV APP_VERSION=${VERSION}
ENV GIT_COMMIT=${GIT_COMMIT}
LABEL org.opencontainers.image.version="${VERSION}"
# Kafka CLI: always downloaded from Apache at build time (no copy from old bundles).
# Bump when you hit broker/client limitations: docker build --build-arg KAFKA_VERSION=3.9.1 .
ARG KAFKA_VERSION=3.8.1
ARG KAFKA_SCALA=2.13
# Stable path gen.sh / default config use (symlink → real kafka_${KAFKA_SCALA}-${KAFKA_VERSION})
ARG KAFKA_LINK_NAME=kafka_2.13-3.6.1
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash jq openjdk-17-jre-headless ca-certificates-java curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*
RUN mkdir -p /opt/kafka-usermgmt \
    && DIST="kafka_${KAFKA_SCALA}-${KAFKA_VERSION}" \
    && URL_DL="https://downloads.apache.org/kafka/${KAFKA_VERSION}/${DIST}.tgz" \
    && URL_AR="https://archive.apache.org/dist/kafka/${KAFKA_VERSION}/${DIST}.tgz" \
    && (curl -fsSL "$URL_DL" || curl -fsSL "$URL_AR") \
    | tar xz -C /opt/kafka-usermgmt \
    && test -d "/opt/kafka-usermgmt/${DIST}" \
    && ln -sfn "/opt/kafka-usermgmt/${DIST}" "/opt/kafka-usermgmt/${KAFKA_LINK_NAME}"
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
COPY gen.sh /opt/kafka-usermgmt/gen.sh
COPY scripts/verify-golive.sh /opt/kafka-usermgmt/verify-golive.sh
RUN chmod +x /opt/kafka-usermgmt/gen.sh /opt/kafka-usermgmt/verify-golive.sh

EXPOSE 3443
CMD ["node", "server/index.js"]
