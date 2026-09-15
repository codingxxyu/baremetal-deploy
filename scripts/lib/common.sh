#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIG="${CONFIG:-${ROOT_DIR}/config/environments/customer.local.yaml}"
BUILD_DIR="${BUILD_DIR:-${ROOT_DIR}/build/rendered}"
NAMESPACE="${NAMESPACE:-cpaas-system}"

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
need_config() { [[ -f "$CONFIG" ]] || die "config not found: $CONFIG (copy customer.template.yaml)"; }
require_env() { [[ -n "${!1:-}" ]] || die "required environment variable is unset: $1"; }
redact() { printf '%s' "$1" | sed -E 's#(password|token|secret|key)([^: =]*)[=:][^ ]+#\1=REDACTED#Ig'; }
