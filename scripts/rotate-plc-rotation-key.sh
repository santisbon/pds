#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CHART="${CHART:-oci://ghcr.io/santisbon/charts/pds}"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <chart-version> [key-file] [release] [namespace]" >&2
  echo "  e.g. $0 0.1.0" >&2
  echo "  Step 3 (final, irreversible) of rotating credentials.plcRotationKey." >&2
  echo "  Only run this once EVERY existing account has confirmed the new key via" >&2
  echo "  scripts/authorize-plc-rotation-key.sh. Re-verify first with:" >&2
  echo "    curl -s https://plc.directory/<did>/data | jq .rotationKeys" >&2
  echo "  <key-file> is the output of scripts/generate-plc-rotation-key.sh (default: ~/new-plc-key.json)" >&2
  echo "  Set CHART=<oci-ref-or-local-path> to override the chart location (default: ${CHART})" >&2
  echo "  If CHART is a local directory, <chart-version> is still required but ignored" >&2
  echo "  (Helm has no concept of a chart version to select for a local path)." >&2
  exit 1
fi

VERSION="$1"
KEY_FILE="${2:-$HOME/new-plc-key.json}"
RELEASE="${3:-pds}"
NAMESPACE="${4:-pds}"

if [[ ! -f "$KEY_FILE" ]]; then
  echo "${KEY_FILE} not found - run scripts/generate-plc-rotation-key.sh first." >&2
  exit 1
fi

NEW_DID_KEY=$(jq -r .didKey "$KEY_FILE")
NEW_HEX=$(jq -r .privHex "$KEY_FILE")

echo "Sanity check: confirming ${KEY_FILE}'s private key derives to ${NEW_DID_KEY}..." >&2
echo "$NEW_HEX" | bash "$SCRIPT_DIR/check-rotation-key.sh" "$NEW_DID_KEY"

if [[ -d "$CHART" ]]; then
  # Local chart path: Helm has no version lookup to constrain, so --version is meaningless here.
  helm upgrade "$RELEASE" "$CHART" --namespace "$NAMESPACE" \
    --reuse-values --set credentials.plcRotationKey="$NEW_HEX"
else
  helm upgrade "$RELEASE" "$CHART" --version "$VERSION" --namespace "$NAMESPACE" \
    --reuse-values --set credentials.plcRotationKey="$NEW_HEX"
fi
kubectl rollout restart "deployment/${RELEASE}" -n "$NAMESPACE"
kubectl rollout status "deployment/${RELEASE}" -n "$NAMESPACE"

rm "$KEY_FILE"
echo "Rotated ${RELEASE}/${NAMESPACE} to the new plcRotationKey. ${KEY_FILE} removed." >&2
echo "Update my-secrets.yaml's credentials.plcRotationKey with the new value too." >&2
