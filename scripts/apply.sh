#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIR="${1:-$ROOT_DIR/build/rendered}"
KUBECONFIG="${KUBECONFIG:?set KUBECONFIG to the target cluster kubeconfig}"
NS="${NAMESPACE:-cpaas-system}"
[[ "${CONFIRM_APPLY:-}" == YES ]] || { echo "Refusing apply. Set CONFIRM_APPLY=YES after reviewing $DIR" >&2; exit 1; }
for f in "$DIR"/*.yaml; do
  kubectl --kubeconfig "$KUBECONFIG" apply --namespace "$NS" -f "$f"
done
