#!/usr/bin/env bash
set -Eeuo pipefail
PACKAGE_DIR="${PACKAGE_DIR:-.}"
TARGET_REGISTRY="${TARGET_REGISTRY:?set TARGET_REGISTRY, e.g. registry.customer.local:11443}"
IMAGE_TAG="${IMAGE_TAG:-v4.3.2-1-1.34.5-3}"
NAMESPACE="${NAMESPACE:-default}"
ARCHIVE="${ARCHIVE:-$PACKAGE_DIR/baremetal-os-${IMAGE_TAG#v}-amd64.tar.gz}"
need() { command -v "$1" >/dev/null || { echo "ERROR: missing command: $1" >&2; exit 1; }; }
for c in sha256sum gzip nerdctl; do need "$c"; done
[[ -f "$ARCHIVE.sha256" ]] || { echo "ERROR: checksum file not found: $ARCHIVE.sha256" >&2; exit 1; }
sha256sum -c "$ARCHIVE.sha256"
gzip -dk "$ARCHIVE"
TAR_FILE="${ARCHIVE%.gz}"
nerdctl --namespace "$NAMESPACE" load -i "$TAR_FILE"
for name in baremetal-base-image-iso baremetal-base-image; do
  src="build-harbor.alauda.cn/tkestack/${name}:${IMAGE_TAG}"
  dst="${TARGET_REGISTRY}/tkestack/${name}:${IMAGE_TAG}"
  nerdctl --namespace "$NAMESPACE" tag "$src" "$dst"
  nerdctl --namespace "$NAMESPACE" push "$dst"
  nerdctl --namespace "$NAMESPACE" pull "$dst"
done
printf 'Imported and verified both Bare Metal images in %s\n' "$TARGET_REGISTRY"
