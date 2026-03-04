#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
V0_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="$V0_DIR/images"
TAR_FILE="$OUT_DIR/harness-images.tar"

IMAGES=(
  "busybox:1.36.1"
  "bitnami/kubectl:latest"
)

mkdir -p "$OUT_DIR"

for img in "${IMAGES[@]}"; do
  echo ">>> Pulling $img"
  docker pull "$img"
done

echo ">>> Saving images to $TAR_FILE"
docker save "${IMAGES[@]}" -o "$TAR_FILE"

SIZE=$(du -h "$TAR_FILE" | cut -f1)
echo ">>> Done: $SIZE  $TAR_FILE"
