#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <hostname> <did> [release] [namespace]" >&2
  echo "  e.g. $0 yourdomain.com did:plc:xxxx" >&2
  echo "  Immediate, no confirmation token, irreversible. Does not tombstone the DID - see tombstone-did.sh." >&2
  exit 1
fi

HOSTNAME="$1"
DID="$2"
RELEASE="${3:-pds}"
NAMESPACE="${4:-pds}"

ADMIN_PASSWORD=$(k8s_secret admin-password "$RELEASE" "$NAMESPACE")

curl -sX POST "https://${HOSTNAME}/xrpc/com.atproto.admin.deleteAccount" \
  -H "Content-Type: application/json" \
  -H "Authorization: Basic $(echo -n "admin:${ADMIN_PASSWORD}" | base64)" \
  -d "{\"did\": \"${DID}\"}"

echo
echo "Deleted ${DID} from this PDS. The did:plc document is untouched - tombstone it with:" >&2
echo "  bash ${SCRIPT_DIR}/tombstone-did.sh ${DID}" >&2
