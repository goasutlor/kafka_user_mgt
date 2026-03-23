#!/bin/bash
# Build Docker image and export as a ready-to-use .tar
# On a machine with Docker: run this script → confluent-kafka-user-management.tar
# Copy the .tar to the target host → docker load → run (no build on that host)

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
IMAGE_NAME="confluent-kafka-user-management"
IMAGE_TAG="latest"

# Bump patch (last number) on each build so you can confirm a new image was loaded
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
echo "Then run the container (see INSTALL.md section 'Pre-built image')."
