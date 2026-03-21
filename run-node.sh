#!/bin/bash
# รัน Web ด้วย Node ตรงๆ (ติดแค่ Node 18+ + express)
# เบื้องต้น: วาง run-node.sh ไว้โฟลเดอร์เดียวกับ gen.sh แล้วรันจากโฟลเดอร์นั้น: ./run-node.sh

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEBAPP_DIR="${WEBAPP_DIR:-$SCRIPT_DIR/webapp}"
[ ! -d "$WEBAPP_DIR" ] && {
  echo "ERROR: webapp directory not found at $WEBAPP_DIR"
  echo "  Put run-node.sh in the same folder as gen.sh and ensure that folder also contains:"
  echo "    webapp/          (from the project)"
  echo "    web-ui-mockup/   (from the project)"
  echo "  Or set WEBAPP_DIR to the path of the webapp directory."
  exit 1
}
[ ! -f "$WEBAPP_DIR/package.json" ] && { echo "ERROR: $WEBAPP_DIR/package.json not found"; exit 1; }
cd "$WEBAPP_DIR"

# ติดตั้ง dependency เฉพาะ production (มีแค่ express)
if [ ! -d "node_modules/express" ]; then
  echo "Installing dependencies (express only)..."
  npm install --omit=dev
fi

if [ -z "${CONFIG_PATH:-}" ]; then
  if [ -f "$SCRIPT_DIR/webapp/config/master.config.json" ]; then
    export CONFIG_PATH="$SCRIPT_DIR/webapp/config/master.config.json"
  else
    export CONFIG_PATH="$SCRIPT_DIR/webapp/config/web.config.json"
  fi
else
  export CONFIG_PATH="$CONFIG_PATH"
fi
export STATIC_DIR="${STATIC_DIR:-$SCRIPT_DIR/web-ui-mockup}"
[ ! -d "$STATIC_DIR" ] && echo "WARN: Static dir not found at $STATIC_DIR — set STATIC_DIR if web-ui-mockup is elsewhere"
[ ! -f "$CONFIG_PATH" ] && echo "WARN: Config not found at $CONFIG_PATH — copy master.config.example.json or use web.config.json"

echo "Starting server (CONFIG_PATH=$CONFIG_PATH, STATIC_DIR=$STATIC_DIR)..."
echo "Open http://<this-host>:3000 (or port in config)"
exec node server/index.js
