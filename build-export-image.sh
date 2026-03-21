#!/bin/bash
# Build Docker image แล้ว export เป็นไฟล์ .tar พร้อมใช้
# ใช้บนเครื่องที่มี Docker: รัน script นี้ → ได้ confluent-kafka-user-management.tar
# นำไฟล์ .tar ไปเครื่องปลายทาง → docker load → รันได้เลย (ไม่ต้อง build บนเครื่องนั้น)

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
IMAGE_NAME="confluent-kafka-user-management"
IMAGE_TAG="latest"

# ทุกครั้งที่ build ให้ bump patch (ตัวเลขท้าย) เพื่อ confirm ว่า load image ใหม่จริง
VERSION="0.0.0"
if [ -f webapp/package.json ]; then
  VERSION=$(node -e "
    const fs = require('fs');
    const p = 'webapp/package.json';
    const pkg = JSON.parse(fs.readFileSync(p, 'utf8'));
    const v = (pkg.version || '0.0.0').split('.');
    if (v.length >= 3) v[2] = String(Number(v[2]) + 1);
    pkg.version = v.join('.');
    fs.writeFileSync(p, JSON.stringify(pkg, null, 2));
    console.log(pkg.version);
  ")
  echo "Bumped version to ${VERSION}"
fi
OUTPUT_TAR="${IMAGE_NAME}-${VERSION}.tar"

echo "Building image ${IMAGE_NAME}:${IMAGE_TAG} (version ${VERSION}) ..."
docker build --build-arg "VERSION=${VERSION}" -t "${IMAGE_NAME}:${IMAGE_TAG}" -t "${IMAGE_NAME}:${VERSION}" .

echo "Exporting image to ${OUTPUT_TAR} ..."
docker save -o "$OUTPUT_TAR" "${IMAGE_NAME}:${IMAGE_TAG}"

echo "Done. File: $(pwd)/${OUTPUT_TAR}"
echo "On target machine: podman load -i ${OUTPUT_TAR}"
echo "Then run container (see INSTALL.md section 'Image พร้อมใช้เลย')."
