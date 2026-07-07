#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <hostname> <code> [code2] [code3] ..." >&2
  echo "  e.g. $0 yourdomain.com ABCD1-EFGH2" >&2
  echo "  Override release/namespace via RELEASE/NAMESPACE env vars (default: pds/pds)." >&2
  echo "  This disables codes (com.atproto.admin.disableInviteCodes) - there is no delete" >&2
  echo "  endpoint in the protocol; disabling only sets disabled=true, it doesn't remove the row." >&2
  exit 1
fi

HOSTNAME="$1"
shift
CODES=("$@")
RELEASE="${RELEASE:-pds}"
NAMESPACE="${NAMESPACE:-pds}"

ADMIN_PASSWORD=$(k8s_secret admin-password "$RELEASE" "$NAMESPACE")

CODES_JSON=$(printf '%s\n' "${CODES[@]}" | jq -R . | jq -s .)

curl -sX POST "https://${HOSTNAME}/xrpc/com.atproto.admin.disableInviteCodes" \
  -H "Content-Type: application/json" \
  -H "Authorization: Basic $(echo -n "admin:${ADMIN_PASSWORD}" | base64)" \
  -d "{\"codes\": ${CODES_JSON}}"

echo
echo "Disabled: ${CODES[*]}"
