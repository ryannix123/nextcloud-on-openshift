#!/bin/bash
set -e

IMAGE="quay.io/ryan_nix/nextcloud:latest"

echo "==> Building image..."
podman build -t "$IMAGE" .

echo "==> Pushing to Quay..."
podman push "$IMAGE"

echo "==> Done: $IMAGE"