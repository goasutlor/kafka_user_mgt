#!/usr/bin/env bash
# Create kafka-client.properties + kafka-client-master.properties under BASE_DIR/configs/
# if missing (same templates as web setup save). Parity: GEN_NONINTERACTIVE=1 GEN_MODE=8.
#
# Usage: scripts/ensure-kafka-client-props.sh <BASE_DIR> <bootstrap.servers>
# Example: scripts/ensure-kafka-client-props.sh /opt/kafka-usermgmt 'kafka-dev.apps.example.com:443'
#
# Truststore: copy org CA as client.truststore.jks into configs/; edit CHANGE_ME in the files.

set -euo pipefail
BASE="${1:?runtime root directory (e.g. /opt/kafka-usermgmt)}"
BOOT="${2:?bootstrap servers e.g. host:443}"

mkdir -p "$BASE/configs"
R="$(cd "$BASE" && pwd)"
TRUST="${R}/configs/client.truststore.jks"

write_one() {
  local dest="$1" title="$2"
  if [[ -f "$dest" ]]; then
    echo "  skip (exists): $dest"
    return 0
  fi
  umask 077
  cat > "${dest}.tmp" <<EOF
# ${title}
# Created by ensure-kafka-client-props.sh — existing files are never overwritten.
# EDIT: ssl.truststore.password and sasl.jaas.config (username/password).
# Truststore: copy your org CA as client.truststore.jks into configs/ (path below).
# Cannot auto-generate a truststore that trusts your corporate brokers without your CA.

bootstrap.servers=${BOOT}
security.protocol=SASL_SSL
sasl.mechanism=PLAIN
client.dns.lookup=use_all_dns_ips
ssl.truststore.location=${TRUST}
ssl.truststore.password=CHANGE_ME
ssl.truststore.type=JKS
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="CHANGE_ME" password="CHANGE_ME";
acks=all

EOF
  mv "${dest}.tmp" "$dest"
  echo "  created: $dest"
}

write_one "$BASE/configs/kafka-client.properties" "Kafka client (application user)"
write_one "$BASE/configs/kafka-client-master.properties" "Kafka admin client (operator user)"
echo "Done. Edit CHANGE_ME lines and place client.truststore.jks under $BASE/configs/"
