#!/usr/bin/env bash
set -Eeuo pipefail
KUBECONFIG="${KUBECONFIG:?set KUBECONFIG to the target cluster kubeconfig}"
NS="${NAMESPACE:-cpaas-system}"
kubectl --kubeconfig "$KUBECONFIG" -n "$NS" get deploy,pods,machineregistration,seedimage,machineinventory,machineinventorypool,cluster,baremetalcluster,kubeadmcontrolplane,machine,machinedeployment -o wide
kubectl --kubeconfig "$KUBECONFIG" get nodes -o wide
