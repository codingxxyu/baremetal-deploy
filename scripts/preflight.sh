#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-$ROOT_DIR/config/environments/customer.local.yaml}"
[[ -f "$CONFIG" ]] || { echo "ERROR: copy config/environments/customer.template.yaml to customer.local.yaml" >&2; exit 1; }
need() { command -v "$1" >/dev/null || { echo "ERROR: missing command: $1" >&2; exit 1; }; }
for c in awk grep sed; do need "$c"; done
architecture="$(awk '$1=="architecture:" {print $2}' "$CONFIG" | head -1)"
[[ "$architecture" == amd64 ]] || { echo "ERROR: only amd64 is supported; ARM64/Kunpeng is blocked" >&2; exit 1; }
platform="$(awk '$1=="target_platform:" {print $2}' "$CONFIG" | head -1)"
[[ -z "$platform" || "$platform" == linux/amd64 ]] || { echo "ERROR: target_platform must be linux/amd64" >&2; exit 1; }
cluster="$(awk '$1=="cluster_name:" {print $2}' "$CONFIG" | head -1)"
[[ -n "$cluster" && "$cluster" != global ]] || { echo "ERROR: cluster_name must be set and cannot be global" >&2; exit 1; }
if grep -Eiq 'password:|private_key|BEGIN (RSA|OPENSSH|EC) PRIVATE KEY|build-harbor\.alauda\.cn' "$CONFIG"; then
  echo "ERROR: config contains forbidden secret/private-key/external build registry material" >&2; exit 1
fi
echo "Preflight passed: architecture=$architecture cluster=$cluster config=$CONFIG"
