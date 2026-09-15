#!/usr/bin/env bash
set -Eeuo pipefail
# Deliberately documentation-only guard. A human operator must run the provider-approved
# cleanup command after handoff review; this script never deletes a cluster or host.
cat >&2 <<'EOF'
No automatic cleanup is provided.
Review docs/09-day2-and-dr.md and the official provider cleanup procedure.
Do not delete the final Cluster/BaremetalCluster or physical-machine data.
EOF
exit 2
