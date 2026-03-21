#!/bin/bash
# Quick test: verify a gen pack works and compare ACL (kotest002 allowed, kotest003 not)
# Usage:
#   ./test-gen-pack.sh <unpacked_pack_dir> [topic]
# Example:
#   ./test-gen-pack.sh /opt/kafka-usermgmt/user_output/TEST_System2_20260219_1220 my-topic
# For kotest003 you need a client.properties for that user (e.g. from another pack or create one).

BASE_DIR="${BASE_DIR:-/opt/kafka-usermgmt}"
KAFKA_BIN="${KAFKA_BIN:-$BASE_DIR/kafka_2.13-3.6.1/bin}"
PACK_DIR="${1:?Usage: $0 <unpacked_pack_dir> [topic]}"
TOPIC="${2:-}"

if [ ! -d "$PACK_DIR" ]; then
  echo "Error: not a directory: $PACK_DIR"
  exit 1
fi
CLIENT_PROP="$PACK_DIR/client.properties"
if [ ! -f "$CLIENT_PROP" ]; then
  echo "Error: $CLIENT_PROP not found"
  exit 1
fi

if [ -z "$TOPIC" ]; then
  echo "Topic not set. Listing topics (using pack credentials)..."
  "$KAFKA_BIN/kafka-topics.sh" --bootstrap-server "$(grep -E '^bootstrap\.servers=' "$CLIENT_PROP" | cut -d= -f2-)" \
    --command-config "$CLIENT_PROP" --list
  echo ""
  read -p "Enter topic name to test consume: " TOPIC
  [ -z "$TOPIC" ] && { echo "No topic. Exit."; exit 0; }
fi

echo "=============================================="
echo "  Test 1: Consume with pack user (should work)"
echo "  Config: $CLIENT_PROP"
echo "  Topic:  $TOPIC"
echo "=============================================="
"$KAFKA_BIN/kafka-console-consumer.sh" \
  --bootstrap-server "$(grep -E '^bootstrap\.servers=' "$CLIENT_PROP" | cut -d= -f2-)" \
  --topic "$TOPIC" \
  --consumer.config "$CLIENT_PROP" \
  --from-beginning --max-messages 5 --timeout-ms 10000
RC1=$?
echo ""
if [ $RC1 -eq 0 ]; then
  echo "  => Pack user: OK (consume succeeded)"
else
  echo "  => Pack user: FAIL (exit $RC1)"
fi

echo ""
echo "=============================================="
echo "  Test 2: Consume with kotest003 (should fail if no ACL)"
echo "  Need: client.properties for kotest003"
echo "=============================================="
KOTEST003_CONFIG="$PACK_DIR/../kotest003_client.properties"
if [ ! -f "$KOTEST003_CONFIG" ]; then
  echo "  Create kotest003 config first, e.g.:"
  echo "    $KOTEST003_CONFIG"
  echo "  With content: bootstrap.servers=<same>, ssl.truststore.*, sasl.jaas.config=... username=\"kotest003\" password=\"<kotest003_pass>\""
  echo "  Then run this script again."
  exit 0
fi
"$KAFKA_BIN/kafka-console-consumer.sh" \
  --bootstrap-server "$(grep -E '^bootstrap\.servers=' "$KOTEST003_CONFIG" | cut -d= -f2-)" \
  --topic "$TOPIC" \
  --consumer.config "$KOTEST003_CONFIG" \
  --from-beginning --max-messages 5 --timeout-ms 10000
RC2=$?
echo ""
if [ $RC2 -ne 0 ]; then
  echo "  => kotest003: correctly denied (exit $RC2)"
else
  echo "  => kotest003: unexpected success (check ACL)"
fi

echo ""
echo "=============================================="
echo "  Summary: pack user should work, kotest003 should be denied"
echo "=============================================="
