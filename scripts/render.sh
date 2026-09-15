#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-$ROOT_DIR/config/environments/customer.local.yaml}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/rendered}"
[[ -f "$CONFIG" ]] || { echo "ERROR: config not found: $CONFIG" >&2; exit 1; }
command -v envsubst >/dev/null || { echo "ERROR: envsubst is required" >&2; exit 1; }
: "${CLUSTER_NAME:=bm-poc}"
: "${KUBERNETES_VERSION:=v1.34.5}"
: "${BOOTSTRAP_REGISTRY:?set BOOTSTRAP_REGISTRY to the registry created by setup.sh}"
: "${BASE_IMAGE:=${BOOTSTRAP_REGISTRY}/tkestack/baremetal-base-image:v4.3.2-1-1.34.5-3}"
: "${BASE_IMAGE_ISO:=${BOOTSTRAP_REGISTRY}/tkestack/baremetal-base-image-iso:v4.3.2-1-1.34.5-3}"
: "${INSTALL_DEVICE:=/dev/elemental-install-target}"
: "${EMULATE_TPM:=true}"
: "${LB_MODE:=External}"
: "${CONTROL_PLANE_ENDPOINT_HOST:=192.0.2.20}"
: "${CONTROL_PLANE_ENDPOINT_PORT:=6443}"
: "${PODS_CIDR:=100.3.0.0/16}"
: "${SERVICES_CIDR:=100.4.0.0/16}"
: "${CONTROL_PLANE_REPLICAS:=3}"
: "${WORKER_REPLICAS:=3}"
: "${SSH_AUTHORIZED_KEY:=REPLACE_WITH_CUSTOMER_PUBLIC_KEY}"
: "${CONTROL_PLANE_INVENTORY_REFS:='      - name: bm-cp-01\n      - name: bm-cp-02\n      - name: bm-cp-03'}"
: "${WORKER_INVENTORY_REFS:='      - name: bm-worker-01\n      - name: bm-worker-02\n      - name: bm-worker-03'}"
: "${INTERNAL_LB_FIELDS:=}"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
for template in "$ROOT_DIR"/manifests/templates/*.yaml; do
  name="$(basename "$template")"
  envsubst < "$template" > "$OUT_DIR/$name"
done
printf 'Rendered templates to %s\n' "$OUT_DIR"
