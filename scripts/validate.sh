#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIR="${1:-$ROOT_DIR/build/rendered}"
[[ -d "$DIR" ]] || { echo "ERROR: rendered directory not found: $DIR" >&2; exit 1; }
command -v grep >/dev/null
if grep -RInE 'build-harbor\.alauda\.cn|BEGIN (RSA|OPENSSH|EC) PRIVATE KEY|password:|authKey:' "$DIR"; then
  echo "ERROR: forbidden external registry or secret material in rendered manifests" >&2; exit 1
fi
if grep -RInE '^namespace:' "$DIR" 2>/dev/null | grep -Ev 'namespace: cpaas-system$'; then
  echo "ERROR: non-cpaas-system namespace found" >&2; exit 1
fi
if grep -RIn 'kind: BaremetalCluster' "$DIR" >/dev/null && ! grep -RIn 'kind: Cluster' "$DIR" >/dev/null; then
  echo "ERROR: BaremetalCluster without Cluster" >&2; exit 1
fi
printf 'Static validation passed for %s\n' "$DIR"
